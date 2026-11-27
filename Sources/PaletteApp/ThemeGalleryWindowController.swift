import AppKit
import Combine
import PaletteCore
import PalettePlatform
import SwiftUI

/// One place for the gallery's frame numbers: the panel and the SwiftUI view
/// must agree or the cards letterbox.
enum ThemeGalleryLayout {
    static let panelWidth: CGFloat = 900
    static let panelHeight: CGFloat = 460
    static let mainCardWidth: CGFloat = 380
    static let mainCardHeight: CGFloat = 352
    static let sideCardWidth: CGFloat = 168
    static let sideCardHeight: CGFloat = 296
    static let sideGap: CGFloat = 16
}

/// The gallery shows both halves of an apply: what happened, and whether it
/// failed, so an error is red instead of looking like success.
struct ThemeGalleryApplyOutcome: Sendable {
    var message: String
    var failed: Bool
}

/// The gallery draws from this. Palettes arrive one card at a time from a
/// background parse, so a flip only reads a dictionary.
@MainActor
final class ThemeGalleryModel: ObservableObject {
    @Published var deck: ThemeCardDeck
    @Published var palettes: [String: ThemeCardPalette] = [:]
    @Published var wallpaperImage: NSImage?
    @Published var wallpaperUnavailable = false
    @Published var status: String?
    @Published var statusFailed = false
    @Published var applying = false

    init(deck: ThemeCardDeck = ThemeCardDeck()) {
        self.deck = deck
    }

    func palette(for card: ThemeCard) -> ThemeCardPalette? {
        palettes[card.cacheKey]
    }
}

/// The pywal-style theme gallery: one large card with its neighbours peeking,
/// driven entirely from the keyboard. It is a non-tracking panel like the
/// status menu, so the app never activates and global hotkeys keep working.
@MainActor
final class ThemeGalleryWindowController: NSWindowController {
    private let model: ThemeGalleryModel
    private let themeManager: ThemeManager
    private let themesDirectory: URL
    private let applyTarget: (ThemeCardTarget) async -> ThemeGalleryApplyOutcome
    private let loadWallpaper: () async -> (NSImage?, ThemeCardPalette?)

    private var hostingView: NSHostingView<ThemeGalleryView>!
    private let backdrop = NSVisualEffectView()
    private let solid = NSView()
    private var clickMonitors: [Any] = []
    private var appearanceObserver: NSObjectProtocol?
    private var themeCancellable: AnyCancellable?
    private var catalog: ThemeBrowserCatalog?
    private var catalogTask: Task<Void, Never>?
    private var loadingPalettes: Set<String> = []
    private var wallpaperLoading = false
    private var wallpaperLoaded = false

    init(
        themeManager: ThemeManager,
        themesDirectory: URL,
        apply: @escaping (ThemeCardTarget) async -> ThemeGalleryApplyOutcome,
        wallpaper: @escaping () async -> (NSImage?, ThemeCardPalette?)
    ) {
        self.model = ThemeGalleryModel()
        self.themeManager = themeManager
        self.themesDirectory = themesDirectory
        self.applyTarget = apply
        self.loadWallpaper = wallpaper

        let panel = ThemeGalleryWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: ThemeGalleryLayout.panelWidth,
                height: ThemeGalleryLayout.panelHeight
            ),
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

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateAppearance() }
        }
        themeCancellable = themeManager.$theme.sink { [weak self] _ in
            Task { @MainActor in self?.updateAppearance() }
        }
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    var isOpen: Bool { window?.isVisible == true }

    // MARK: - Catalogue

    /// 942 headers, read once at launch so the first hotkey press is instant.
    /// No TOML body is parsed here; palettes load for the visible card only.
    func preload() {
        guard catalog == nil, catalogTask == nil else { return }
        let directory = themesDirectory
        catalogTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                let clock = ContinuousClock()
                var catalog: ThemeBrowserCatalog?
                let elapsed = clock.measure {
                    catalog = ThemeBrowserCatalog(themes: ThemeLoader.catalog(themesDirectory: directory))
                }
                return (catalog, elapsed)
            }.value
            guard let self, let catalog = built.0 else { return }
            self.catalog = catalog
            self.catalogTask = nil
            self.model.deck = ThemeCardDeck(catalog: catalog, currentTheme: self.themeManager.currentThemeID)
            Log.shared.info(
                "Theme cards catalogue: \(catalog.count) cards in \(Self.milliseconds(built.1)) ms",
                source: "theme"
            )
            if self.isOpen {
                self.loadVisiblePalettes()
            }
        }
    }

    // MARK: - Presentation

    func show() {
        preload()
        if let catalog {
            model.deck = ThemeCardDeck(catalog: catalog, currentTheme: themeManager.currentThemeID)
        }
        model.status = nil
        model.statusFailed = false
        model.applying = false
        model.wallpaperUnavailable = false
        loadVisiblePalettes()
        updateAppearance()
        installClickMonitors()
        guard let window else { return }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = NSRect(
                x: screen.visibleFrame.midX - ThemeGalleryLayout.panelWidth / 2,
                y: screen.visibleFrame.midY - ThemeGalleryLayout.panelHeight / 2,
                width: ThemeGalleryLayout.panelWidth,
                height: ThemeGalleryLayout.panelHeight
            )
            window.setFrame(frame, display: true)
        }
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
        // Leave the window as first responder so arrow keys reach the panel
        // instead of SwiftUI's focus system.
        window.makeFirstResponder(nil)
        Log.shared.info(
            "Theme cards showing \(model.deck.count) cards at \(model.deck.current.displayName)",
            source: "app"
        )
    }

    func hide() {
        removeClickMonitors()
        window?.orderOut(nil)
    }

    func toggle() {
        if isOpen { hide() } else { show() }
    }

    // MARK: - Movement

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
        loadVisiblePalettes()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let cached = model.palette(for: model.deck.current) != nil
        Log.shared.info(
            "Theme cards flip → \(model.deck.current.displayName) "
                + "(\(elapsed / 1_000) µs, palette \(cached ? "cached" : "loading"))",
            source: "theme"
        )
    }

    // MARK: - Palettes

    private func visibleCards() -> [ThemeCard] {
        guard model.deck.count > 0 else { return [] }
        return [model.deck.previous, model.deck.current, model.deck.next]
    }

    /// The visible card and its two neighbours: a flip lands on a card that is
    /// already parsed, so the card body never waits on disk.
    private func loadVisiblePalettes() {
        for card in visibleCards() {
            loadPalette(for: card)
        }
    }

    private func loadPalette(for card: ThemeCard) {
        switch card.kind {
        case .wallpaper:
            loadWallpaperIfNeeded()
        case .theme(let info):
            guard model.palette(for: card) == nil,
                  !loadingPalettes.contains(card.cacheKey) else { return }
            loadingPalettes.insert(card.cacheKey)
            let directory = themesDirectory
            Task { @MainActor [weak self] in
                let palette = await Task.detached(priority: .userInitiated) {
                    ThemeCardPalette(theme: ThemeLoader.load(name: info.name, themesDirectory: directory).theme)
                }.value
                guard let self else { return }
                self.loadingPalettes.remove(card.cacheKey)
                self.model.palettes[card.cacheKey] = palette
            }
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

    // MARK: - Apply

    private func applyCurrent() {
        let card = model.deck.current
        apply(card)
    }

    private func applyWallpaper() {
        model.deck.jumpToFirst()
        loadVisiblePalettes()
        apply(.wallpaper)
    }

    private func apply(_ card: ThemeCard) {
        guard !model.applying else { return }
        let target = card.target
        model.applying = true
        model.statusFailed = false
        model.status = "Applying…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.applyTarget(target)
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

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased()

        if flags.contains(.command) {
            switch event.keyCode {
            case 123: // ⌘←
                moveToFirst()
                return true
            case 124: // ⌘→
                moveToLast()
                return true
            default:
                break
            }
        }

        if !flags.contains(.command), !flags.contains(.control) {
            if characters == "h" {
                move(-1)
                return true
            }
            if characters == "l" {
                move(1)
                return true
            }
            if characters == "w" {
                applyWallpaper()
                return true
            }
        }

        switch event.keyCode {
        case 53: // Esc
            hide()
            return true
        case 36, 76: // Return, keypad Enter
            applyCurrent()
            return true
        case 123: // Left
            move(-1)
            return true
        case 124: // Right
            move(1)
            return true
        default:
            return false
        }
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let parts = duration.components
        let value = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        return String(format: "%.1f", value)
    }
}

/// A nonactivating panel that can still take arrow keys, like the status menu.
private final class ThemeGalleryWindow: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

// MARK: - View

private struct ThemeGalleryView: View {
    @ObservedObject var model: ThemeGalleryModel
    @ObservedObject var themeManager: ThemeManager
    var applyCurrent: () -> Void
    var close: () -> Void

    private var theme: Theme { themeManager.theme }
    private var muted: Color { theme.color(theme.palette.fgMuted) }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: ThemeGalleryLayout.sideGap) {
                sideCard(model.deck.previous, label: "Previous")
                mainCard
                sideCard(model.deck.next, label: "Next")
            }
            footer
        }
        .padding(18)
        .frame(
            width: ThemeGalleryLayout.panelWidth,
            height: ThemeGalleryLayout.panelHeight,
            alignment: .center
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme cards")
    }

    private var mainCard: some View {
        let card = model.deck.current
        let palette = model.palette(for: card)
        let background = color(palette?.background, fallback: theme.palette.surface)
        let foreground = color(palette?.foreground, fallback: theme.palette.fg)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card.displayName)
                    .font(theme.font(size: 19, weight: .semibold))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
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
            }

            if case .wallpaper = card.kind, let image = model.wallpaperImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 92)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(foreground.opacity(0.16), lineWidth: 1)
                    )
                    .accessibilityLabel("Current desktop picture")
            }

            HStack(spacing: 8) {
                swatchBlock("BG", palette?.background, foreground: foreground)
                swatchBlock("FG", palette?.foreground, foreground: foreground)
                swatchBlock("ACCENT", palette?.accent, foreground: foreground)
                swatchBlock("SELECT", palette?.selection, foreground: foreground)
            }

            HStack(spacing: 5) {
                ForEach(Array((palette?.brightestANSI ?? []).enumerated()), id: \.offset) { _, hex in
                    Circle()
                        .fill(color(hex, fallback: theme.palette.fgMuted))
                        .frame(width: 13, height: 13)
                        .overlay(Circle().strokeBorder(foreground.opacity(0.18), lineWidth: 0.5))
                }
                Spacer(minLength: 4)
                Text(displayAppearance(card, palette: palette))
                    .font(.system(size: 10))
                    .foregroundStyle(foreground.opacity(0.7))
            }

            HStack(spacing: 8) {
                Text("Aa")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(foreground)
                Text("The quick brown fox")
                    .font(.system(size: 11))
                    .foregroundStyle(foreground.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("#!/bin/sh")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(accentColor(palette, foreground: foreground))
            }
            .accessibilityHidden(true)

            Spacer(minLength: 0)
            Text(paletteSummary(card, palette: palette))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(foreground.opacity(0.65))
                .lineLimit(1)
        }
        .padding(15)
        .frame(
            width: ThemeGalleryLayout.mainCardWidth,
            height: ThemeGalleryLayout.mainCardHeight,
            alignment: .topLeading
        )
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accentColor(palette, foreground: foreground).opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardLabel(card, role: "Theme card"))
        .accessibilityValue(accessibilityValue(card, palette: palette))
    }

    private func sideCard(_ card: ThemeCard, label: String) -> some View {
        let palette = model.palette(for: card)
        let background = color(palette?.background, fallback: theme.palette.surface)
        let foreground = color(palette?.foreground, fallback: theme.palette.fg)
        return VStack(alignment: .leading, spacing: 8) {
            Text(card.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foreground.opacity(0.9))
                .lineLimit(2)
            HStack(spacing: 4) {
                miniSwatch(palette?.background, fallback: theme.palette.bg)
                miniSwatch(palette?.foreground, fallback: theme.palette.fg)
                miniSwatch(palette?.accent, fallback: theme.palette.accent)
                miniSwatch(palette?.selection, fallback: theme.palette.elevated)
            }
            Spacer(minLength: 0)
            Text(card.sectionTitle)
                .font(.system(size: 9))
                .foregroundStyle(foreground.opacity(0.6))
        }
        .padding(11)
        .frame(
            width: ThemeGalleryLayout.sideCardWidth,
            height: ThemeGalleryLayout.sideCardHeight,
            alignment: .topLeading
        )
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(foreground.opacity(0.12), lineWidth: 1)
        )
        .opacity(0.62)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardLabel(card, role: label))
        .accessibilityValue(accessibilityValue(card, palette: palette))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Apply", action: applyCurrent)
                .buttonStyle(.borderedProminent)
                .tint(theme.color(theme.palette.accent))
                .accessibilityLabel("Apply the shown theme")
            Button("Close", action: close)
                .accessibilityLabel("Close theme cards")

            if model.applying {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Applying theme")
            } else if let status = model.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(model.statusFailed
                        ? theme.color(theme.palette.danger)
                        : theme.color(theme.palette.success))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(status)
            }

            Spacer(minLength: 8)

            Text("\(model.deck.count) cards")
                .font(.system(size: 10))
                .foregroundStyle(muted)
                .monospacedDigit()

            Text("← → flip · ⌘← ⌘→ first / last · ↩ apply · W wallpaper · Esc close")
                .font(.system(size: 10))
                .foregroundStyle(muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Card pieces

    private func swatchBlock(
        _ title: String,
        _ hex: String?,
        foreground: Color
    ) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color(hex, fallback: theme.palette.elevated))
                .frame(height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(foreground.opacity(0.14), lineWidth: 1)
                )
            Text(title)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(foreground.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func miniSwatch(_ hex: String?, fallback: String) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color(hex, fallback: fallback))
            .frame(height: 14)
            .frame(maxWidth: .infinity)
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

    private func cardLabel(_ card: ThemeCard, role: String) -> String {
        "\(role) theme card: \(card.displayName), \(card.sectionTitle)"
    }

    private func accessibilityValue(_ card: ThemeCard, palette: ThemeCardPalette?) -> String {
        let appearance = displayAppearance(card, palette: palette)
        guard let palette else {
            return "\(appearance.isEmpty ? "" : "\(appearance). ")Palette loading"
        }
        return "\(appearance). Background \(palette.background), foreground \(palette.foreground), "
            + "accent \(palette.accent), selection \(palette.selection)"
    }
}
