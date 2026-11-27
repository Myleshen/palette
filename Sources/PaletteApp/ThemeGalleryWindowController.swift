import AppKit
import Combine
import PaletteCore
import PalettePlatform
import SwiftUI

/// The gallery shows both halves of an apply: what happened, and whether it
/// failed, so an error is red instead of looking like success.
struct ThemeGalleryApplyOutcome: Sendable {
    var message: String
    var failed: Bool
}

/// The gallery draws from this. Palettes and thumbnails arrive one card at a
/// time from a background parse, so a flip only reads a dictionary.
@MainActor
final class ThemeGalleryModel: ObservableObject {
    @Published var deck: ThemeCardDeck
    @Published var palettes: [String: ThemeCardPalette] = [:]
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var wallpaperImage: NSImage?
    @Published var wallpaperUnavailable = false
    /// The focused full-screen preview. The fan keeps its selection, so
    /// collapsing returns to the card that was in front.
    @Published var previewing = false
    /// Full themes from the same off-main parse as the palettes, so the
    /// launcher mock inside the preview uses the card's real typography.
    @Published var previewThemes: [String: Theme] = [:]
    @Published var status: String?
    @Published var statusFailed = false
    @Published var applying = false
    /// Bumped on every show so the view can re-deal the hand.
    @Published var dealID = 0
    /// Bumped on every apply so the chosen card can rise before the status.
    @Published var celebration = 0
    /// The layout of the screen the deck opened on: frame, card size, arc and
    /// reach. Rebuilt on every show and every display change.
    @Published var layout = ThemeGalleryLayout.metrics(
        in: NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
    )
    /// Script hook: freeze the deal at a progress so a snapshot can catch the
    /// hand mid-open.
    @Published var dealOverride: Double?
    /// Dismiss animates the hand back out before the panel orders off.
    @Published var closing = false

    init(deck: ThemeCardDeck = ThemeCardDeck()) {
        self.deck = deck
    }

    func palette(for card: ThemeCard) -> ThemeCardPalette? {
        palettes[card.cacheKey]
    }

    func thumbnail(for card: ThemeCard) -> NSImage? {
        guard let path = card.wallpaperPath else { return wallpaperImage }
        return thumbnails[path]
    }

    func previewTheme(for card: ThemeCard, fallback: Theme) -> Theme {
        previewThemes[card.cacheKey] ?? fallback
    }

    func showAll() {
        deck.query = ""
        deck.favouritesOnly = false
    }
}

/// The fanned hand of theme and wallpaper cards: one large card at the front,
/// its neighbours angled behind it, driven entirely from the keyboard. It is a
/// non-tracking panel like the status menu, so the app never activates and
/// global hotkeys keep working.
@MainActor
final class ThemeGalleryWindowController: NSWindowController {
    private let model: ThemeGalleryModel
    private let themeManager: ThemeManager
    private let themesDirectory: URL
    private var wallpaperDirectory: URL?
    private let favourites: ThemeCardFavourites
    private let applyTarget: (ThemeCardTarget) async -> ThemeGalleryApplyOutcome
    private let loadWallpaper: () async -> (NSImage?, ThemeCardPalette?)
    /// Read at apply time so the guard sees the source the user last saved.
    private let paletteSource: @MainActor () -> ThemingSource

    private var hostingView: NSHostingView<ThemeGalleryView>!
    private let backdrop = NSVisualEffectView()
    private let solid = NSView()
    private var clickMonitors: [Any] = []
    private var appearanceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var themeCancellable: AnyCancellable?
    private var catalog: ThemeBrowserCatalog?
    private var catalogTask: Task<Void, Never>?
    private var wallpapers: [WallpaperFile] = []
    private var loadingPalettes: Set<String> = []
    private var loadingThumbnails: Set<String> = []
    private var loadingWallpaperPalettes: Set<String> = []
    private var wallpaperLoading = false
    private var wallpaperLoaded = false
    private var lastScrollTime: TimeInterval = 0

    init(
        themeManager: ThemeManager,
        themesDirectory: URL,
        wallpaperDirectory: URL?,
        favourites: ThemeCardFavourites = ThemeCardFavourites(),
        apply: @escaping (ThemeCardTarget) async -> ThemeGalleryApplyOutcome,
        wallpaper: @escaping () async -> (NSImage?, ThemeCardPalette?),
        paletteSource: @escaping @MainActor () -> ThemingSource
    ) {
        self.model = ThemeGalleryModel()
        self.themeManager = themeManager
        self.themesDirectory = themesDirectory
        self.wallpaperDirectory = wallpaperDirectory
        self.favourites = favourites
        self.applyTarget = apply
        self.loadWallpaper = wallpaper
        self.paletteSource = paletteSource

        let panel = ThemeGalleryWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)

        let view = ThemeGalleryView(
            model: model,
            themeManager: themeManager,
            applyCurrent: { [weak self] in self?.applyCurrent() },
            selectRelative: { [weak self] in self?.select(relative: $0) },
            toggleFavouritesView: { [weak self] in self?.toggleFavouritesView() },
            toggleFavourite: { [weak self] in self?.toggleFavourite() },
            showAll: { [weak self] in self?.showAll() },
            close: { [weak self] in self?.hide() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hostingView = hosting

        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 16
        backdrop.layer?.masksToBounds = true

        solid.wantsLayer = true
        solid.layer?.cornerRadius = 16
        solid.layer?.masksToBounds = true

        panel.contentView = backdrop
        backdrop.addSubview(solid)
        backdrop.addSubview(hosting)
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        panel.onScroll = { [weak self] delta in self?.scroll(delta) }

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateAppearance() }
        }
        // Replugging a monitor or changing a display's resolution must not
        // leave a hand sized for the old frame.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isOpen else { return }
                self.relayout()
                self.loadVisibleCards()
            }
        }
        themeCancellable = themeManager.$theme.sink { [weak self] _ in
            Task { @MainActor in self?.updateAppearance() }
        }
        model.deck.favourites = favourites.keys
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for observer in [appearanceObserver, screenObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isOpen: Bool { window?.isVisible == true }

    // MARK: - Catalogue

    /// 942 headers and the wallpaper folder, read once at launch so the first
    /// hotkey press is instant. No TOML body is parsed here; palettes and
    /// thumbnails load for the cards the fan shows.
    func preload() {
        guard catalog == nil, catalogTask == nil else { return }
        let directory = themesDirectory
        let wallpaperPath = wallpaperDirectory
        catalogTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                let clock = ContinuousClock()
                var catalog: ThemeBrowserCatalog?
                var wallpapers: [WallpaperFile] = []
                let elapsed = clock.measure {
                    catalog = ThemeBrowserCatalog(themes: ThemeLoader.catalog(themesDirectory: directory))
                    wallpapers = WallpaperLibrary.files(in: wallpaperPath)
                }
                return (catalog, wallpapers, elapsed)
            }.value
            guard let self, let catalog = built.0 else { return }
            self.catalog = catalog
            self.wallpapers = built.1
            self.catalogTask = nil
            self.rebuildDeck(keepSelection: false)
            Log.shared.info(
                "Theme cards catalogue: \(catalog.count) cards + \(built.1.count) wallpapers "
                    + "in \(Self.milliseconds(built.2)) ms",
                source: "theme"
            )
            if self.isOpen {
                self.loadVisibleCards()
            }
        }
    }

    /// A config reload can point the cards at a different folder. Rescan now
    /// instead of waiting for the next launch.
    func updateWallpaperDirectory(_ url: URL?) {
        guard url != wallpaperDirectory else { return }
        wallpaperDirectory = url
        wallpapers = []
        guard catalog != nil else { return }
        // Drop the old folder's cards now; an empty new folder has nothing to
        // compare against, so waiting for the rescan would keep them.
        rebuildDeck(keepSelection: false)
        refreshWallpapers()
    }

    /// A folder can gain files between opens; rescan and only rebuild when the
    /// list actually changed, so an open hand does not jump for nothing.
    private func refreshWallpapers() {
        guard catalog != nil else { return }
        let directory = wallpaperDirectory
        Task { [weak self] in
            let files = await Task.detached(priority: .utility) {
                WallpaperLibrary.files(in: directory)
            }.value
            guard let self, files != self.wallpapers else { return }
            self.wallpapers = files
            self.rebuildDeck(keepSelection: true)
            if self.isOpen { self.loadVisibleCards() }
        }
    }

    private var currentDesktopURL: URL? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    private func rebuildDeck(keepSelection: Bool) {
        guard let catalog else { return }
        let desktop = currentDesktopURL
        let selectedKey = keepSelection ? model.deck.current.cacheKey : nil
        var deck = ThemeCardDeck(
            catalog: catalog,
            currentTheme: themeManager.currentThemeID,
            wallpapers: wallpapers.map(\.url),
            currentDesktop: desktop,
            mode: model.deck.mode
        )
        deck.favourites = favourites.keys
        deck.currentDesktopPath = desktop?.standardizedFileURL.path
        if let selectedKey, let index = deck.visible.firstIndex(where: { $0.cacheKey == selectedKey }) {
            deck.selected = index
        }
        model.deck = deck
    }

    // MARK: - Presentation

    /// Script-only visible-frame override, so the wide deck can be rendered
    /// for a display size the harness machine does not have.
    private var scriptedVisibleFrame: NSRect?

    /// The pointer's screen, resolved now — never a remembered one.
    private func deckMetrics() -> ThemeDeckMetrics? {
        if let scriptedVisibleFrame { return ThemeGalleryLayout.metrics(in: scriptedVisibleFrame) }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let fallback = screens.firstIndex(where: { $0 == NSScreen.main }) ?? 0
        let index = ThemeGalleryLayout.screenIndex(
            for: NSEvent.mouseLocation,
            screens: screens.map(\.frame),
            fallback: fallback
        )
        let chosen = index ?? fallback
        guard screens.indices.contains(chosen) else { return nil }
        return ThemeGalleryLayout.metrics(in: screens[chosen].visibleFrame)
    }

    /// Sizes the open panel to the display under the pointer and hands the same
    /// numbers to the view. Called on show and on every display change.
    private func relayout() {
        guard let window, let metrics = deckMetrics() else { return }
        model.layout = metrics
        window.setFrame(metrics.frame, display: true)
        layoutContent()
    }

    func show(mode: ThemeCardMode? = nil) {
        preload()
        if let mode { model.deck.mode = mode }
        model.showAll()
        model.previewing = false
        refreshWallpapers()
        if catalog != nil {
            rebuildDeck(keepSelection: false)
        }
        model.dealID += 1
        model.status = nil
        model.statusFailed = false
        model.applying = false
        model.wallpaperUnavailable = false
        updateAppearance()
        installClickMonitors()
        guard let window else { return }
        model.dealOverride = nil
        model.closing = false
        relayout()
        loadVisibleCards()
        showSourceHintIfNeeded()
        if WindowPresentation.isScripted {
            // A scripted run must leave focus alone; the panel still renders.
            window.orderFront(nil)
            Log.shared.info(
                "Script mode: theme cards shown without activation (appActive=\(NSApp.isActive))",
                source: "app"
            )
        } else {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        // Leave the window as first responder so arrow keys and typing reach
        // the panel instead of SwiftUI's focus system.
        window.makeFirstResponder(nil)
        Log.shared.info(
            "Theme cards showing \(model.deck.count) \(model.deck.mode.title.lowercased()) "
                + "at \(model.deck.current.displayName) (\(wallpapers.count) wallpapers)",
            source: "app"
        )
    }

    func hide() {
        model.previewing = false
        removeClickMonitors()
        guard let window else { return }
        guard !model.closing else { return }
        // Close by reversing the deal, then order the panel off; a scripted
        // snapshot run has no user watching the animation.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !WindowPresentation.isScripted else {
            window.orderOut(nil)
            return
        }
        model.closing = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, self.model.closing else { return }
            self.model.closing = false
            self.window?.orderOut(nil)
        }
    }

    /// The deck is in wallpaper mode's guard territory: Colors can be looked
    /// at, but the footer says why applying a theme card will not work until
    /// the source flips back.
    private func showSourceHintIfNeeded() {
        guard model.deck.mode == .colors,
              model.deck.count > 0,
              paletteSource() == .wallpaper else { return }
        model.status = ThemeCardSourceGuard.wallpaperHint
        model.statusFailed = false
    }

    func toggle() {
        if isOpen { hide() } else { show() }
    }

    // MARK: - Movement

    private func select(relative: Int) {
        guard relative != 0 else {
            applyCurrent()
            return
        }
        move(relative)
    }

    private func move(_ delta: Int) {
        let start = DispatchTime.now()
        model.deck.move(by: delta)
        finishMove(start)
    }

    private func moveToFirst() {
        let start = DispatchTime.now()
        model.deck.jumpToFirst()
        finishMove(start)
    }

    private func moveToLast() {
        let start = DispatchTime.now()
        model.deck.jumpToLast()
        finishMove(start)
    }

    /// Deck movement and the palette lookup are synchronous; only a cache miss
    /// schedules a background parse. This is the number to keep small.
    private func finishMove(_ start: DispatchTime) {
        loadVisibleCards()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let cached = model.palette(for: model.deck.current) != nil
            || model.thumbnail(for: model.deck.current) != nil
        let stage = model.previewing ? "preview flip" : "flip"
        Log.shared.info(
            "Theme cards \(stage) → \(model.deck.current.displayName) "
                + "(\(elapsed / 1_000) µs, \(cached ? "cached" : "loading")), "
                + "\(model.deck.count) visible",
            source: "theme"
        )
    }

    // MARK: - Filter and favourites

    private func setQuery(_ text: String) {
        let start = DispatchTime.now()
        model.deck.query = text
        finishMove(start)
    }

    private func appendFilter(_ text: String) {
        setQuery(model.deck.query + text)
    }

    private func deleteFilterCharacter() {
        guard !model.deck.query.isEmpty else { return }
        setQuery(String(model.deck.query.dropLast()))
    }

    private func toggleFavouritesView() {
        let start = DispatchTime.now()
        model.deck.favouritesOnly.toggle()
        finishMove(start)
    }

    private func showAll() {
        let start = DispatchTime.now()
        model.deck.query = ""
        model.deck.favouritesOnly = false
        finishMove(start)
    }

    private func toggleFavourite() {
        guard model.deck.count > 0 else { return }
        let key = model.deck.current.cacheKey
        model.deck.favourites = favourites.toggle(key)
        let on = model.deck.favourites.contains(key)
        Log.shared.info(
            "Theme cards \(on ? "favourited" : "unfavourited") \(model.deck.current.displayName)",
            source: "theme"
        )
        if model.deck.favouritesOnly && !on {
            // The card just left the favourites view; keep the deck coherent.
            model.deck.selected = min(model.deck.selected, max(0, model.deck.count - 1))
            loadVisibleCards()
        }
    }

    // MARK: - Palettes and thumbnails

    /// Only the fanned window is decoded: the selected card and at most
    /// `reach` neighbours on each side.
    private func visibleCards() -> [ThemeCard] {
        model.deck.fanWindow(reach: reach).map(\.card)
    }

    private var reach: Int { model.layout.reach }

    private func loadVisibleCards() {
        for card in visibleCards() {
            switch card.kind {
            case .wallpaper:
                loadWallpaperIfNeeded()
            case .wallpaperFile(let url):
                loadThumbnail(for: url)
                loadWallpaperPalette(for: url)
            case .theme:
                loadPalette(for: card)
            }
        }
    }

    private func loadPalette(for card: ThemeCard) {
        guard case .theme(let info) = card.kind,
              model.palette(for: card) == nil,
              !loadingPalettes.contains(card.cacheKey) else { return }
        loadingPalettes.insert(card.cacheKey)
        let directory = themesDirectory
        Task { @MainActor [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                let theme = ThemeLoader.load(name: info.name, themesDirectory: directory).theme
                return (ThemeCardPalette(theme: theme), theme)
            }.value
            guard let self else { return }
            self.loadingPalettes.remove(card.cacheKey)
            self.model.palettes[card.cacheKey] = loaded.0
            self.model.previewThemes[card.cacheKey] = loaded.1
        }
    }

    private func loadThumbnail(for url: URL) {
        let path = url.standardizedFileURL.path
        guard model.thumbnails[path] == nil, !loadingThumbnails.contains(path) else { return }
        loadingThumbnails.insert(path)
        Task { @MainActor [weak self] in
            let thumbnail = await CardImageLoader.shared.thumbnail(for: url)
            guard let self else { return }
            self.loadingThumbnails.remove(path)
            guard let thumbnail else { return }
            self.model.thumbnails[path] = thumbnail.image
        }
    }

    /// The card's own dots. The picture is decoded small off-main, then only
    /// the 64×64 sample and k-means cross to the background.
    private func loadWallpaperPalette(for url: URL) {
        let key = ThemeCard.wallpaperFile(url).cacheKey
        guard model.palettes[key] == nil, !loadingWallpaperPalettes.contains(key) else { return }
        loadingWallpaperPalettes.insert(key)
        let appearance = themeManager.theme.appearance
        Task { @MainActor [weak self] in
            let small = await CardImageLoader.shared.thumbnail(for: url, maxPixel: 96)
            guard let self else { return }
            self.loadingWallpaperPalettes.remove(key)
            guard let image = small?.image,
                  let pixels = WallpaperPalette.pixels(from: image) else { return }
            let palette = await Task.detached(priority: .utility) {
                WallpaperPalette.extract(pixels: pixels, appearance: appearance)
            }.value
            guard let palette else { return }
            self.model.palettes[key] = ThemeCardPalette(palette: palette)
        }
    }

    private func loadWallpaperIfNeeded() {
        guard !wallpaperLoaded, !wallpaperLoading, !model.wallpaperUnavailable else { return }
        wallpaperLoading = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (image, palette) = await self.loadWallpaper()
            self.wallpaperLoading = false
            self.wallpaperLoaded = image != nil || palette != nil
            self.model.wallpaperImage = image
            if let palette {
                self.model.palettes[ThemeCard.wallpaper.cacheKey] = palette
            } else if image == nil {
                // The configured desktop picture can point at a deleted file;
                // say so instead of showing "Loading palette…" forever.
                self.model.wallpaperUnavailable = true
            }
        }
    }

    // MARK: - Preview

    /// The preview renders the card already in front, so opening costs one
    /// state change plus the palette lookup the fan has already made.
    private func openPreview() {
        guard !model.previewing, model.deck.count > 0 else { return }
        let start = DispatchTime.now()
        model.previewing = true
        loadVisibleCards()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let cached = model.palette(for: model.deck.current) != nil
            || model.thumbnail(for: model.deck.current) != nil
        Log.shared.info(
            "Theme cards preview open → \(model.deck.current.displayName) "
                + "(\(elapsed / 1_000) µs, \(cached ? "cached" : "loading"))",
            source: "theme"
        )
        announcePreview()
    }

    private func closePreview() {
        guard model.previewing else { return }
        model.previewing = false
        Log.shared.info(
            "Theme cards preview closed → \(model.deck.current.displayName)",
            source: "theme"
        )
    }

    private func togglePreview() {
        if model.previewing { closePreview() } else { openPreview() }
    }

    /// VoiceOver gets the card name; the view carries the same label so focus
    /// lands on a control with a readable name.
    private func announcePreview() {
        guard let element = window?.contentView else { return }
        let name = model.deck.current.displayName
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Preview: \(name)",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    // MARK: - Apply

    private func applyCurrent() {
        guard model.deck.count > 0 else {
            model.status = "Nothing matches “\(model.deck.query)”"
            model.statusFailed = false
            return
        }
        apply(model.deck.current)
    }

    private func apply(_ card: ThemeCard) {
        guard !model.applying else { return }
        if let reason = ThemeCardSourceGuard.blockedReason(
            source: paletteSource(),
            target: card.target
        ) {
            model.status = reason
            model.statusFailed = false
            return
        }
        let target = card.target
        model.applying = true
        model.celebration += 1
        model.statusFailed = false
        model.status = "Applying…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.applyTarget(target)
            if !outcome.failed, case .wallpaperFile(let path) = target {
                self.model.deck.currentDesktopPath = path
            }
            self.model.applying = false
            self.model.status = outcome.message.isEmpty ? "Applied" : outcome.message
            self.model.statusFailed = outcome.failed
        }
    }

    // MARK: - Dismissal

    private func installClickMonitors() {
        removeClickMonitors()
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.window {
                self.hide()
            }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        if let local { clickMonitors.append(local) }
        if let global { clickMonitors.append(global) }
    }

    private func removeClickMonitors() {
        for monitor in clickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        clickMonitors.removeAll()
    }

    // MARK: - Appearance

    private func updateAppearance() {
        let theme = themeManager.theme
        window?.appearance = theme.nsAppearance
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        backdrop.isHidden = reduceTransparency
        solid.isHidden = !reduceTransparency
        solid.layer?.backgroundColor = theme.nsColor(theme.palette.bg).cgColor
        for layer in [backdrop.layer, solid.layer] {
            layer?.borderWidth = 1
            layer?.borderColor = theme.nsColor(theme.palette.border).cgColor
        }
        layoutContent()
    }

    private func layoutContent() {
        guard let window else { return }
        let bounds = NSRect(origin: .zero, size: window.frame.size)
        backdrop.frame = bounds
        solid.frame = bounds
        hostingView.frame = bounds
    }

    // MARK: - Keys

    func scriptKey(_ event: NSEvent) -> Bool { handleKey(event) }

    func scriptMove(_ delta: Int) { move(delta) }
    func scriptJumpToFirst() { moveToFirst() }
    func scriptJumpToLast() { moveToLast() }
    func scriptFilter(_ text: String) { setQuery(text) }
    func scriptToggleFavouritesView() { toggleFavouritesView() }
    func scriptToggleFavourite() { toggleFavourite() }
    func scriptApply() { applyCurrent() }
    func scriptPreview() { openPreview() }
    func scriptPreviewClose() { closePreview() }

    /// Script hook: `themecards_deal=0.5` freezes the open animation halfway so
    /// a snapshot can show the hand mid-deal.
    func scriptDeal(_ progress: Double) {
        model.dealOverride = min(max(progress, 0), 1)
        model.dealID += 1
    }

    /// Script hook: `themecards_size=1710x1073` lays the deck out for a display
    /// of that usable size and resizes the open panel to match.
    func scriptSize(_ spec: String) {
        let parts = spec.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return }
        scriptedVisibleFrame = NSRect(x: 0, y: 0, width: parts[0], height: parts[1])
        relayout()
        loadVisibleCards()
    }

    /// Script hook: `themecards_mode=colors|wallpapers`. Switching while open
    /// keeps the panel up; a closed deck is opened in that mode.
    func scriptMode(_ mode: ThemeCardMode) {
        setMode(mode)
        if !isOpen { show(mode: mode) }
    }

    private func setMode(_ mode: ThemeCardMode) {
        guard mode != model.deck.mode else { return }
        model.deck.mode = mode
        model.deck.query = ""
        model.deck.favouritesOnly = false
        rebuildDeck(keepSelection: false)
        loadVisibleCards()
        showSourceHintIfNeeded()
        Log.shared.info("Theme cards mode → \(mode.title)", source: "theme")
    }

    /// Wheel and trackpad flip one card per gesture direction. Momentum keeps
    /// sending events after the fingers stop, so ignore the burst.
    private func scroll(_ delta: CGFloat) {
        guard abs(delta) > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastScrollTime > 0.12 else { return }
        lastScrollTime = now
        move(delta > 0 ? -1 : 1)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            switch event.keyCode {
            case 123: // ⌘←
                moveToFirst()
                return true
            case 124: // ⌘→
                moveToLast()
                return true
            default:
                return false
            }
        }

        if flags.contains(.control) {
            if event.charactersIgnoringModifiers?.lowercased() == "f" {
                toggleFavourite()
            }
            return false
        }

        if flags.contains(.option) { return false }

        let text = event.charactersIgnoringModifiers
        let printable = text.map { value in
            !value.isEmpty
                && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0xF700 }
        } ?? false

        guard let command = ThemeCardKeyRoute.command(
            keyCode: event.keyCode,
            characters: printable ? text : nil,
            filterEmpty: model.deck.query.isEmpty,
            previewing: model.previewing
        ) else { return false }
        perform(command)
        return true
    }

    private func perform(_ command: ThemeCardCommand) {
        switch command {
        case .closeDeck: hide()
        case .closePreview: closePreview()
        case .openPreview: openPreview()
        case .apply: applyCurrent()
        case .flip(let delta): move(delta)
        case .toggleFavouritesView: toggleFavouritesView()
        case .toggleFavourite: toggleFavourite()
        case .jumpFirst: moveToFirst()
        case .jumpLast: moveToLast()
        case .deleteFilterCharacter: deleteFilterCharacter()
        case .appendFilter(let text): appendFilter(text)
        }
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let parts = duration.components
        let value = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        return String(format: "%.1f", value)
    }
}

/// A nonactivating panel that can still take arrow keys, typing and the wheel,
/// like the status menu.
final class ThemeGalleryWindow: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onScroll: ((CGFloat) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The deck is exactly the usable width of its display. AppKit's default
    /// constraining would leave a margin on a shared edge, so it is disabled.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let onScroll else {
            super.scrollWheel(with: event)
            return
        }
        onScroll(event.scrollingDeltaY)
    }
}

// MARK: - View

private struct ThemeGalleryView: View {
    @ObservedObject var model: ThemeGalleryModel
    @ObservedObject var themeManager: ThemeManager
    var applyCurrent: () -> Void
    var selectRelative: (Int) -> Void
    var toggleFavouritesView: () -> Void
    var toggleFavourite: () -> Void
    var showAll: () -> Void
    var close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deal: Double = 0
    @State private var pulse = false
    /// Cards do not take clicks while the hand is still moving.
    @State private var transitioning = false
    @State private var hoveredKey: String?
    /// The focused preview's grow-from-the-card progress, and whether the layer
    /// is mounted for the collapse animation.
    @State private var previewProgress: Double = 0
    @State private var previewMounted = false

    private var theme: Theme { themeManager.theme }
    private var muted: Color { theme.color(theme.palette.fgMuted) }
    private var metrics: ThemeDeckMetrics { model.layout }
    private var arc: ThemeCardFanGeometry { metrics.arc }
    private var reach: Int { metrics.reach }
    private var motion: ThemeDeckMotion { .standard }

    var body: some View {
        ZStack {
            // Only the hand and its header take the side padding: the preview
            // is a full-deck layer underneath.
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                fan
                    .padding(.bottom, metrics.bottomInset)
                footer
            }
            .padding(.horizontal, metrics.sideInset)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityHidden(model.previewing)

            previewLayer
        }
        // Pin the root to the deck's exact frame: no child's ideal width may
        // push the fan off-centre, and the panel is always the full width.
        .frame(width: metrics.frame.width, height: metrics.frame.height, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme cards")
        .onAppear { dealIn() }
        .onChange(of: model.dealID) { _, _ in dealIn() }
        .onChange(of: model.closing) { _, closing in
            guard closing else { return }
            if reduceMotion {
                deal = 0
            } else {
                withAnimation(.easeIn(duration: 0.18)) { deal = 0 }
            }
        }
        .onChange(of: model.deck.selected) { _, _ in markTransitioning() }
        .onChange(of: model.celebration) { _, _ in pulseApply() }
        .onChange(of: model.previewing) { _, open in
            if open {
                previewMounted = true
                previewProgress = reduceMotion ? 1 : 0
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    previewProgress = 1
                }
            } else {
                guard !reduceMotion else {
                    previewProgress = 0
                    previewMounted = false
                    return
                }
                withAnimation(.easeIn(duration: 0.16)) { previewProgress = 0 }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    if !model.previewing { previewMounted = false }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("THEME CARDS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(muted)
                .accessibilityHidden(true)

            Text(model.deck.mode.title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(theme.color(theme.palette.bg))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.color(theme.palette.accent)))
                .accessibilityLabel("Mode \(model.deck.mode.title)")

            filterField

            chip(
                model.deck.query.isEmpty && !model.deck.favouritesOnly ? "All" : "All themes",
                lit: model.deck.query.isEmpty && !model.deck.favouritesOnly,
                hint: "Show every card",
                action: showAll
            )
            chip(
                "♥ Favourites \(model.deck.favourites.count)",
                lit: model.deck.favouritesOnly,
                hint: "Show favourite cards only",
                action: toggleFavouritesView
            )

            Spacer(minLength: 8)

            Text(positionLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(muted)
                .monospacedDigit()
                .accessibilityLabel("Card \(positionLabel)")
        }
    }

    private var positionLabel: String {
        let count = model.deck.count
        guard count > 0 else { return "0 / 0" }
        return "\(min(model.deck.selected + 1, count)) / \(count)"
    }

    /// Typing is handled by the panel, so this is a field the keyboard drives
    /// rather than a focusable NSTextField that would steal the arrow keys.
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(muted)
            Text(model.deck.query.isEmpty ? "Type to filter" : model.deck.query)
                .font(.system(size: 11))
                .foregroundStyle(model.deck.query.isEmpty ? muted.opacity(0.75) : theme.color(theme.palette.fg))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .frame(minWidth: 180, maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.color(theme.palette.elevated).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(theme.color(theme.palette.border).opacity(0.8), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Filter themes")
        .accessibilityValue(model.deck.query.isEmpty ? "Empty" : model.deck.query)
    }

    private func chip(
        _ label: String,
        lit: Bool,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(lit ? theme.color(theme.palette.bg) : theme.color(theme.palette.fg))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    Capsule().fill(
                        lit
                            ? theme.color(theme.palette.accent)
                            : theme.color(theme.palette.elevated).opacity(0.6)
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        theme.color(theme.palette.border).opacity(lit ? 0 : 0.8),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .help(hint)
        .accessibilityLabel(label)
    }

    // MARK: - Fan

    private var fan: some View {
        let slots = model.deck.fanWindow(reach: reach)
        return ZStack(alignment: .bottom) {
            if slots.isEmpty {
                Text(model.deck.favouritesOnly && model.deck.query.isEmpty
                    ? "No favourites yet · Tab shows all · ⌃F marks the card in front"
                    : "Nothing matches “\(model.deck.query)”")
                    .font(.system(size: 12))
                    .foregroundStyle(muted)
                    .accessibilityLabel("No matching cards")
            }
            ForEach(slots, id: \.card.id) { slot in
                cardView(slot)
            }
        }
        .frame(maxWidth: .infinity)
        // The hand rises out of the deck's bottom edge; on a screen too short
        // for it the header wins and the card tops are cropped.
        .frame(height: metrics.handHeight, alignment: .bottom)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fanned hand of cards")
    }

    private func cardView(_ slot: FanSlot) -> some View {
        let card = slot.card
        let selected = slot.relative == 0
        let placement = arc.placement(
            relative: slot.relative,
            progress: motion.progress(for: slot.relative, deal: deal)
        )
        let hovered = hoveredKey == card.cacheKey && !model.previewing
        let cardScale = metrics.scale * placement.scale * (selected && pulse ? 1.06 : 1)
            * (hovered ? motion.hoverScale : 1)
        let pivotLift = -placement.y - (hovered ? motion.hoverLift : 0)
        // Reduce Motion never slides the hand: the cards keep their positions
        // and the change of front card reads as a short crossfade instead.
        let selectionAnimation: Animation? = reduceMotion
            ? nil
            : .spring(response: motion.response, dampingFraction: motion.damping)
                .delay(Double(abs(slot.relative)) * 0.004)
        let fanOpacity = deal * (selected ? 1 : 0.9)
        let palette = model.palette(for: card)
        let background = color(palette?.background, fallback: theme.palette.surface)
        let foreground = color(palette?.foreground, fallback: theme.palette.fg)

        return cardBody(card, palette: palette, foreground: foreground, selected: selected)
            .frame(width: metrics.cardWidth, height: metrics.cardHeight)
            .opacity(fanOpacity)
            // Scoped before the transforms, so Reduce Motion fades the dim
            // without animating the position.
            .animation(
                reduceMotion ? .easeInOut(duration: motion.crossfade) : nil,
                value: model.deck.selected
            )
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        selected
                            ? accentColor(palette, foreground: foreground).opacity(0.85)
                            : foreground.opacity(0.14),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
            .overlay(
                // Side cards are shaded; the selected card stays at full light.
                Color.black.opacity(placement.dim)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .allowsHitTesting(false)
            )
            .overlay(alignment: .topLeading) {
                if isDesktopCard(card) { currentDot }
            }
            .overlay(alignment: .topTrailing) {
                if model.deck.favourites.contains(card.cacheKey) { favouriteBadge }
            }
            .overlay(alignment: .bottomTrailing) {
                if isVideoCard(card) { videoBadge }
            }
            .shadow(
                color: .black.opacity(selected ? 0.4 : 0.2),
                radius: selected ? 22 : 8,
                y: selected ? 12 : 5
            )
            .scaleEffect(cardScale, anchor: .bottom)
            .rotationEffect(.degrees(placement.rotation), anchor: .bottom)
            // The pivot rides the arc: `placement.y` is its height above the
            // canvas bottom.
            .offset(x: placement.x, y: pivotLift)
            .animation(
                reduceMotion ? nil : .easeOut(duration: motion.crossfade),
                value: hoveredKey
            )
            .animation(selectionAnimation, value: model.deck.selected)
            .zIndex(placement.zIndex)
            // Hit testing follows the rotated, offset frame: the content shape
            // is declared after the transform.
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .allowsHitTesting(!transitioning && !model.previewing)
            .onHover { inside in
                let key = card.cacheKey
                if inside {
                    hoveredKey = key
                } else if hoveredKey == key {
                    hoveredKey = nil
                }
            }
            .onTapGesture { selectRelative(slot.relative) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cardLabel(card, selected: selected))
            .accessibilityValue(accessibilityValue(card, palette: palette))
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityAction(named: "Apply") {
                if selected { applyCurrent() }
            }
    }

    @ViewBuilder
    private func cardBody(
        _ card: ThemeCard,
        palette: ThemeCardPalette?,
        foreground: Color,
        selected: Bool
    ) -> some View {
        switch card.kind {
        case .wallpaper, .wallpaperFile:
            wallpaperBody(card, palette: palette, foreground: foreground, selected: selected)
        case .theme:
            themeBody(card, palette: palette, foreground: foreground, selected: selected)
        }
    }

    private func themeBody(
        _ card: ThemeCard,
        palette: ThemeCardPalette?,
        foreground: Color,
        selected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: selected ? 10 : 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card.displayName)
                    .font(.system(size: selected ? 18 : 12, weight: .semibold))
                    .foregroundStyle(foreground)
                    .lineLimit(selected ? 1 : 2)
                if selected {
                    Spacer(minLength: 6)
                    Text(card.sectionTitle.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(accentColor(palette, foreground: foreground))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(
                            Capsule().strokeBorder(
                                accentColor(palette, foreground: foreground).opacity(0.7),
                                lineWidth: 1
                            )
                        )
                        // Leave the heart badge its corner.
                        .padding(.trailing, model.deck.favourites.contains(card.cacheKey) ? 18 : 0)
                }
            }

            HStack(spacing: selected ? 8 : 5) {
                swatchBlock("BG", palette?.background, foreground: foreground, tall: selected)
                swatchBlock("FG", palette?.foreground, foreground: foreground, tall: selected)
                swatchBlock("ACCENT", palette?.accent, foreground: foreground, tall: selected)
                if selected {
                    swatchBlock("SELECT", palette?.selection, foreground: foreground, tall: true)
                }
            }

            HStack(spacing: selected ? 5 : 3) {
                ForEach(Array((palette?.brightestANSI ?? []).prefix(selected ? 8 : 6).enumerated()), id: \.offset) { _, hex in
                    Circle()
                        .fill(color(hex, fallback: theme.palette.fgMuted))
                        .frame(width: selected ? 12 : 6, height: selected ? 12 : 6)
                        .overlay(Circle().strokeBorder(foreground.opacity(0.18), lineWidth: 0.5))
                }
                Spacer(minLength: 4)
                if selected {
                    Text(displayAppearance(card, palette: palette))
                        .font(.system(size: 10))
                        .foregroundStyle(foreground.opacity(0.7))
                }
            }

            if selected {
                paletteBanner(palette, foreground: foreground)
                    .frame(maxHeight: .infinity)
            } else {
                paletteBanner(palette, foreground: foreground, compact: true)
                    .frame(maxHeight: .infinity)
            }

            Spacer(minLength: 0)

            if selected {
                Text(paletteSummary(card, palette: palette))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(foreground.opacity(0.65))
                    .lineLimit(1)
            } else {
                Text(card.sectionTitle)
                    .font(.system(size: 9))
                    .foregroundStyle(foreground.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .padding(selected ? 15 : 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A strip of the palette's own colours, so the card shows more than four
    /// blocks and the empty middle earns its space.
    private func paletteBanner(
        _ palette: ThemeCardPalette?,
        foreground: Color,
        compact: Bool = false
    ) -> some View {
        let colors = (palette?.brightestANSI ?? []).compactMap { RGBA(hex: $0)?.color }
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                LinearGradient(
                    colors: colors.isEmpty
                        ? [foreground.opacity(0.06), foreground.opacity(0.14)]
                        : colors,
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .overlay(alignment: .bottomLeading) {
                if !compact {
                    Text("The quick brown fox   #!/bin/sh")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(foreground.opacity(0.9))
                        .lineLimit(1)
                        .padding(8)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(foreground.opacity(0.12), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    private func wallpaperBody(
        _ card: ThemeCard,
        palette: ThemeCardPalette?,
        foreground: Color,
        selected: Bool
    ) -> some View {
        let image = model.thumbnail(for: card)
        let video = isVideoCard(card)
        // Full bleed: the picture is the card, corner to corner. The name sits
        // on a scrim over it, with no inner frame or inset thumbnail.
        return ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [
                            theme.color(theme.palette.elevated),
                            theme.color(theme.palette.surface),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    Image(systemName: video ? "film" : "photo")
                        .font(.system(size: selected ? 44 : 28, weight: .light))
                        .foregroundStyle(foreground.opacity(0.35))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.8)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: selected ? 7 : 4) {
                Spacer(minLength: 0)
                Text(card.displayName)
                    .font(.system(size: selected ? 16 : 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(selected ? 1 : 2)
                if selected {
                    HStack(spacing: 5) {
                        Text(card.sectionTitle.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Color.white.opacity(0.75))
                        if video {
                            Text("VIDEO")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(Color.white.opacity(0.75))
                        }
                        Spacer(minLength: 4)
                        ForEach(Array((palette?.brightestANSI ?? []).prefix(8).enumerated()), id: \.offset) { _, hex in
                            Circle()
                                .fill(color(hex, fallback: theme.palette.fgMuted))
                                .frame(width: 9, height: 9)
                        }
                    }
                }
            }
            .padding(selected ? 15 : 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Focused preview

    private var previewLayer: some View {
        let card = model.deck.current
        let motion = ThemeCardPreviewMotion.visual(
            progress: previewProgress,
            reduceMotion: reduceMotion
        )
        return ZStack {
            if previewMounted {
                previewCard(card)
                    .id(card.id)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: card.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(motion.scale, anchor: UnitPoint(x: 0.5, y: 0.72))
        .opacity(motion.opacity)
        .allowsHitTesting(model.previewing)
        .accessibilityHidden(!model.previewing)
    }

    private func previewCard(_ card: ThemeCard) -> some View {
        let palette = model.palette(for: card)
        let background = color(palette?.background, fallback: theme.palette.surface)
        let foreground = color(palette?.foreground, fallback: theme.palette.fg)
        let accent = accentColor(palette, foreground: foreground)
        return VStack(alignment: .leading, spacing: 12) {
            previewHeader(card, palette: palette, foreground: foreground, accent: accent)
            if ThemeCardPreviewContent(card: card) == .picture {
                wallpaperPreview(card, palette: palette)
            } else {
                themePreview(card, palette: palette, foreground: foreground)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(accent.opacity(0.8), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 28, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview: \(card.displayName)")
    }

    private func previewHeader(
        _ card: ThemeCard,
        palette: ThemeCardPalette?,
        foreground: Color,
        accent: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("PREVIEW")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(foreground.opacity(0.6))
                .accessibilityHidden(true)
            Text(card.displayName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(foreground)
                .lineLimit(1)
            previewChip(card.sectionTitle.uppercased(), foreground: accent)
            if !displayAppearance(card, palette: palette).isEmpty {
                previewChip(displayAppearance(card, palette: palette).uppercased(), foreground: foreground)
            }
            if model.deck.favourites.contains(card.cacheKey) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.49))
                    .accessibilityLabel("Favourite")
            }
            Spacer(minLength: 8)
            Text(positionLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foreground.opacity(0.6))
                .monospacedDigit()
                .accessibilityLabel("Card \(positionLabel)")
            Text("← → flip · ↩ apply · Space/P/esc back")
                .font(.system(size: 10))
                .foregroundStyle(foreground.opacity(0.55))
                .lineLimit(1)
                .accessibilityHidden(true)
        }
    }

    private func previewChip(_ label: String, foreground: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(
                Capsule().strokeBorder(foreground.opacity(0.6), lineWidth: 1)
            )
    }

    private func themePreview(
        _ card: ThemeCard,
        palette: ThemeCardPalette?,
        foreground: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                previewSwatch("BG", palette?.background, foreground: foreground)
                previewSwatch("FG", palette?.foreground, foreground: foreground)
                previewSwatch("ACCENT", palette?.accent, foreground: foreground)
                previewSwatch("SELECT", palette?.selection, foreground: foreground)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("ANSI 0–15")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(foreground.opacity(0.55))
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<8, id: \.self) { column in
                            ansiSwatch(
                                index: row * 8 + column,
                                hex: ansiHex(palette, row * 8 + column),
                                foreground: foreground
                            )
                        }
                    }
                }
            }
            HStack {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text("LIVE LAUNCHER")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(foreground.opacity(0.55))
                    LauncherThemeSample(theme: model.previewTheme(for: card, fallback: theme))
                        .frame(width: 600)
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Live launcher preview in \(card.displayName)")
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            Text(paletteSummary(card, palette: palette))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(foreground.opacity(0.65))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func previewSwatch(
        _ title: String,
        _ hex: String?,
        foreground: Color
    ) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color(hex, fallback: theme.palette.elevated))
                .frame(height: 84)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(foreground.opacity(0.14), lineWidth: 1)
                )
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(foreground.opacity(0.65))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(hex ?? "loading")")
    }

    private func ansiSwatch(index: Int, hex: String?, foreground: Color) -> some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color(hex, fallback: theme.palette.elevated))
                .frame(height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(foreground.opacity(0.14), lineWidth: 1)
                )
            Text("\(index)")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(foreground.opacity(0.7))
            Text(hex ?? "—")
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(foreground.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ANSI \(index), \(hex ?? "loading")")
    }

    private func wallpaperPreview(
        _ card: ThemeCard,
        palette: ThemeCardPalette?
    ) -> some View {
        let image = model.thumbnail(for: card)
        let video = isVideoCard(card)
        return GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: [theme.color(theme.palette.elevated), theme.color(theme.palette.surface)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    Image(systemName: video ? "film" : "photo")
                        .font(.system(size: 76, weight: .ultraLight))
                        .foregroundStyle(theme.color(theme.palette.fgMuted).opacity(0.5))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                LinearGradient(
                    colors: [.clear, .black.opacity(0.82)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text(card.displayName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(card.sectionTitle.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.white.opacity(0.75))
                        if video {
                            Text("VIDEO")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        Spacer(minLength: 8)
                        ForEach(Array((palette?.ansi ?? []).enumerated()), id: \.offset) { _, hex in
                            Circle()
                                .fill(color(hex, fallback: theme.palette.fgMuted))
                                .frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        }
                        Spacer(minLength: 8)
                        Text(positionLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .monospacedDigit()
                    }
                }
                .padding(16)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(card.displayName), \(card.sectionTitle), "
                        + "\(palette?.ansi.count ?? 0) palette dots"
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
        }
    }

    // MARK: - Card pieces

    private var currentDot: some View {
        Circle()
            .fill(theme.color(theme.palette.accent))
            .frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(.black.opacity(0.45), lineWidth: 1))
            .padding(14)
            .accessibilityHidden(true)
    }

    private var favouriteBadge: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.49))
            .padding(6)
            .background(Circle().fill(.black.opacity(0.55)))
            .padding(12)
            .accessibilityHidden(true)
    }

    private var videoBadge: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(7)
            .background(Circle().fill(.black.opacity(0.55)))
            .padding(12)
            .accessibilityHidden(true)
    }

    private func swatchBlock(
        _ title: String,
        _ hex: String?,
        foreground: Color,
        tall: Bool
    ) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color(hex, fallback: theme.palette.elevated))
                .frame(height: tall ? 56 : 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(foreground.opacity(0.14), lineWidth: 1)
                )
            if tall {
                Text(title)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Apply", action: applyCurrent)
                .buttonStyle(.borderedProminent)
                .tint(theme.color(theme.palette.accent))
                .accessibilityLabel("Apply the card in front")

            if model.applying {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Applying")
            } else if let status = model.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(model.statusFailed
                        ? theme.color(theme.palette.danger)
                        : theme.color(theme.palette.success))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(status)
                    .accessibilityLabel(model.statusFailed ? "Apply failed: \(status)" : status)
            }

            Spacer(minLength: 8)

            Text(model.deck.favouritesOnly
                ? "Favourites view · Tab shows all"
                : "← → choose · ↩ apply · Space/P preview · type filter · Tab favourites · ⌃F ♥ · esc close")
                .font(.system(size: 10))
                .foregroundStyle(muted)
                .lineLimit(1)
                .accessibilityHidden(true)

            Button("Close", action: close)
                .accessibilityLabel("Close theme cards")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Animation

    private func dealIn() {
        markTransitioning()
        if let override = model.dealOverride {
            deal = override
            return
        }
        deal = 0
        guard !reduceMotion else {
            deal = 1
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 16_000_000)
            withAnimation(.spring(response: motion.response, dampingFraction: motion.damping)) {
                deal = 1
            }
        }
    }

    /// Clicks and hovers are off until the hand has settled.
    private func markTransitioning() {
        transitioning = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)
            transitioning = false
        }
    }

    private func pulseApply() {
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) {
            pulse = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(.easeOut(duration: 0.24)) {
                pulse = false
            }
        }
    }

    // MARK: - Helpers

    private func isDesktopCard(_ card: ThemeCard) -> Bool {
        guard let path = card.wallpaperPath else {
            if case .wallpaper = card.kind { return true }
            return false
        }
        return path == model.deck.currentDesktopPath
    }

    private func isVideoCard(_ card: ThemeCard) -> Bool {
        guard let path = card.wallpaperPath else { return false }
        return WallpaperLibrary.videoExtensions.contains(
            URL(fileURLWithPath: path).pathExtension.lowercased()
        )
    }

    private func color(_ hex: String?, fallback: String) -> Color {
        if let hex, let value = RGBA(hex: hex) {
            return value.color
        }
        if let value = RGBA(hex: fallback) {
            return value.color
        }
        return theme.color(theme.palette.fgMuted)
    }

    private func ansiHex(_ palette: ThemeCardPalette?, _ index: Int) -> String? {
        guard let palette, palette.ansi.indices.contains(index) else { return nil }
        return palette.ansi[index]
    }

    private func accentColor(_ palette: ThemeCardPalette?, foreground: Color) -> Color {
        guard let accent = palette?.accent else { return foreground.opacity(0.8) }
        return color(accent, fallback: theme.palette.accent)
    }

    private func displayAppearance(_ card: ThemeCard, palette: ThemeCardPalette?) -> String {
        let appearance = palette?.appearance ?? card.appearance
        return appearance.isEmpty ? "" : appearance.capitalized
    }

    private func paletteSummary(_ card: ThemeCard, palette: ThemeCardPalette?) -> String {
        guard let palette else {
            if case .wallpaper = card.kind, model.wallpaperUnavailable {
                return "Desktop picture unavailable"
            }
            return "Loading palette…"
        }
        return "\(palette.background) · \(palette.foreground) · \(palette.accent)"
    }

    private func cardLabel(_ card: ThemeCard, selected: Bool) -> String {
        let kind = card.isWallpaper ? "Wallpaper card" : "Theme card"
        let suffix = selected ? ", in front" : ""
        return "\(kind): \(card.displayName), \(card.sectionTitle)\(suffix)"
    }

    private func accessibilityValue(_ card: ThemeCard, palette: ThemeCardPalette?) -> String {
        var parts: [String] = []
        if isDesktopCard(card) { parts.append("On the desktop") }
        if model.deck.favourites.contains(card.cacheKey) { parts.append("Favourite") }
        if isVideoCard(card) { parts.append("Video") }
        if let palette {
            parts.append("Background \(palette.background), foreground \(palette.foreground), "
                + "accent \(palette.accent), selection \(palette.selection)")
        } else if card.wallpaperPath != nil {
            parts.append("Preview loading")
        } else {
            parts.append("Palette loading")
        }
        return parts.joined(separator: ". ")
    }
}
