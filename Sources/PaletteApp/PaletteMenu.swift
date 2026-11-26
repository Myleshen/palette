import AppKit
import Observation
import PaletteCore
import PalettePlatform
import SwiftUI

/// One row's highlight flag. Rows observe their own box, so moving the
/// keyboard highlight repaints two rows instead of re-evaluating all 942.
@Observable
final class PaletteMenuRowHighlight {
    var isOn = false
}

@MainActor
final class PaletteMenuHighlights {
    private var boxes: [String: PaletteMenuRowHighlight] = [:]
    private var current: String?

    /// Created on demand, so only rows the list has actually built get a box.
    func box(_ id: String) -> PaletteMenuRowHighlight {
        if let box = boxes[id] { return box }
        let box = PaletteMenuRowHighlight()
        boxes[id] = box
        return box
    }

    func apply(_ id: String?) {
        guard id != current else { return }
        if let current { boxes[current]?.isOn = false }
        if let id { box(id).isOn = true }
        current = id
    }

    func reset(_ id: String?) {
        boxes.removeAll()
        current = nil
        apply(id)
    }
}

@MainActor
final class PaletteMenuModel: ObservableObject {
    /// Rows the view draws. Filtering replaces this; highlighting never does.
    @Published private(set) var items: [PaletteMenuItem] = []
    private(set) var allItems: [PaletteMenuItem] = []
    private(set) var selection = PaletteMenuSelection(items: [])
    private(set) var query = ""
    /// Long lists render from here down, with a same-height spacer above, so
    /// the anchor can be reached without building the rows above it.
    @Published private(set) var windowStart = 0
    let highlights = PaletteMenuHighlights()

    var searchable: Bool { PaletteMenuSearch.isSearchable(allItems) }
    var activation: PaletteMenuItem? { selection.activation }
    var highlightedID: String? { selection.highlightedID }

    func present(items: [PaletteMenuItem], preferred: String?) {
        allItems = items
        query = ""
        self.items = items
        selection = PaletteMenuSelection(items: items, preferred: preferred)
        windowStart = max(0, (items.firstIndex(where: { $0.id == selection.highlightedID }) ?? 0) - 30)
        highlights.reset(selection.highlightedID)
    }

    /// Rows above the window are blank, so pull the window up before the blank
    /// spacer can enter the viewport. Heights are fixed, so this is arithmetic.
    func ensureRowsAbove(offset: CGFloat) {
        guard windowStart > 0 else { return }
        var start = windowStart
        while start > 0, offset < PaletteMenuMetrics.offsetBefore(start, in: items) + 40 {
            start = max(0, start - 40)
        }
        if start != windowStart { windowStart = start }
    }

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        let filtered = PaletteMenuSearch.filtered(allItems, query: text)
        // Keep the highlight on the same row when it survived the filter;
        // otherwise the first match takes it.
        selection = PaletteMenuSelection(items: filtered, preferred: selection.highlightedID)
        // Reset the window before swapping the rows: a render can never see a
        // window start past the end of the filtered list.
        windowStart = 0
        items = filtered
        highlights.reset(selection.highlightedID)
    }

    func move(_ delta: Int) {
        selection.move(delta)
        highlights.apply(selection.highlightedID)
    }

    func highlight(_ id: String) {
        let before = selection.highlightedID
        selection.highlight(id)
        guard selection.highlightedID != before else { return }
        highlights.apply(selection.highlightedID)
    }

    func dismiss() {
        selection.dismiss()
        highlights.apply(nil)
    }
}

/// Replaces SwiftUI's `Menu` / `.contextMenu` with a borderless floating panel.
///
/// A native `NSMenu` enters a tracking loop: while it is open, Palette's global
/// hotkeys (screenshot, launcher) do not fire. This panel has no tracking loop,
/// never activates the app and never becomes main, so a hotkey callback keeps
/// running while it is on screen.
///
/// Native `NSMenu`s stay only where macOS owns the menu: the app menu bar and
/// Services (`AppDelegate.buildMainMenu`). The system draws and drives those,
/// and they are not opened from Palette's own UI.
///
/// Long lists are windowed and lazily laid out: opening a 942-theme picker
/// builds a page's worth of rows, not the whole list.
@MainActor
final class PaletteMenuController: NSWindowController {
    static let shared = PaletteMenuController()

    private let model = PaletteMenuModel()
    private let backdrop = NSVisualEffectView()
    private let solid = NSView()
    private var hostingView: NSHostingView<PaletteMenuView>!
    private var clickMonitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var onSelect: ((String) -> Void)?
    private var onDismiss: (() -> Void)?
    private var previousKeyWindow: NSWindow?
    private var theme = Theme()
    private var placement: Placement = .at(.zero)
    /// Script mode reports how many rows a menu built; also keeps the open
    /// timing honest by counting the first visible page.
    private var rowBuilds = 0
    private var builtRowIDs = Set<String>()

    private enum Placement {
        case anchored(NSRect)
        case at(NSPoint)
    }

    private static let cornerRadius: CGFloat = 8

    var isOpen: Bool { window?.isVisible == true }

    private init() {
        let panel = PaletteMenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: PaletteMenuLayout.width, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        super.init(window: panel)

        let view = PaletteMenuView(
            model: model,
            theme: theme,
            select: { [weak self] item in self?.activate(item) },
            onCommand: { [weak self] command in self?.perform(command) ?? false },
            onQuery: { [weak self] text in self?.applyQuery(text) }
        )
        hostingView = NSHostingView(rootView: view)

        backdrop.material = .menu
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Self.cornerRadius
        backdrop.layer?.masksToBounds = true

        solid.wantsLayer = true
        solid.layer?.cornerRadius = Self.cornerRadius
        solid.layer?.masksToBounds = true

        panel.contentView = backdrop
        backdrop.addSubview(solid)
        backdrop.addSubview(hostingView)
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    // MARK: - Presentation

    /// Opens under a control (Settings) or with its top-left at the pointer
    /// (right-click in the launcher).
    func show(
        items: [PaletteMenuItem],
        anchoredTo rect: NSRect,
        theme: Theme,
        onSelect: @escaping (String) -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        present(items: items, placement: .anchored(rect), theme: theme,
                onSelect: onSelect, onDismiss: onDismiss)
    }

    func show(
        items: [PaletteMenuItem],
        at point: NSPoint,
        theme: Theme,
        onSelect: @escaping (String) -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        present(items: items, placement: .at(point), theme: theme,
                onSelect: onSelect, onDismiss: onDismiss)
    }

    private func present(
        items: [PaletteMenuItem],
        placement: Placement,
        theme: Theme,
        onSelect: @escaping (String) -> Void,
        onDismiss: (() -> Void)?
    ) {
        let started = CFAbsoluteTimeGetCurrent()
        if isOpen { hide() }
        guard !items.isEmpty else { return }

        self.theme = theme
        self.placement = placement
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        rowBuilds = 0
        builtRowIDs.removeAll()
        let visible = visibleFrame(for: placement)
        model.present(
            items: items,
            preferred: items.first(where: { $0.checked && $0.isSelectable })?.id
        )
        hostingView.rootView = PaletteMenuView(
            model: model,
            theme: theme,
            select: { [weak self] item in self?.activate(item) },
            onCommand: { [weak self] command in self?.perform(command) ?? false },
            onQuery: { [weak self] text in self?.applyQuery(text) },
            onRowBuilt: { [weak self] id in
                self?.rowBuilds += 1
                self?.builtRowIDs.insert(id)
            }
        )
        updateAppearance()
        installClickMonitors()
        layout(in: visible)
        // One visible-page layout lets the scroll view exist; then the anchor
        // is a plain offset over the windowed list, not a scroll-to-far-row
        // walk that builds every row above it.
        hostingView.layoutSubtreeIfNeeded()
        scrollToHighlighted()

        guard let window else { return }
        previousKeyWindow = NSApp.keyWindow
        if WindowPresentation.isScripted {
            window.orderFront(nil)
            Log.shared.info(
                "Script mode: palette menu shown without activation "
                    + "(appActive=\(NSApp.isActive))",
                source: "app"
            )
        } else {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        // Leave the panel as first responder so keyDown reaches it instead of
        // SwiftUI's focus system. The filter field claims it when present.
        window.makeFirstResponder(nil)
        if model.searchable,
           let field = hostingView.firstDescendant(of: PaletteSearchTextField.self) {
            window.makeFirstResponder(field)
        }

        if WindowPresentation.isScripted {
            // One visible-page layout, so the number covers what the user sees
            // rather than only the frame arithmetic.
            hostingView.layoutSubtreeIfNeeded()
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            Log.shared.info(
                "Palette menu open: \(items.count) items, \(rowBuilds) rows built "
                    + "(\(builtRowIDs.count) unique), "
                    + String(format: "%.2f ms", ms)
                    + ", appActive=\(NSApp.isActive)",
                source: "app"
            )
        }
    }

    func hide() {
        guard let window, window.isVisible else { return }
        removeClickMonitors()
        model.dismiss()
        window.orderOut(nil)
        if let previousKeyWindow,
           previousKeyWindow !== window,
           previousKeyWindow.isVisible {
            previousKeyWindow.makeKey()
        }
        previousKeyWindow = nil
        let dismiss = onDismiss
        onDismiss = nil
        onSelect = nil
        dismiss?()
    }

    // MARK: - Layout

    private func visibleFrame(for placement: Placement) -> NSRect {
        let screen: NSScreen?
        switch placement {
        case .anchored(let rect):
            screen = NSScreen.screens.first {
                $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY))
            }
        case .at(let point):
            screen = NSScreen.screens.first { $0.frame.contains(point) }
        }
        return (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: PaletteMenuLayout.width, height: 600)
    }

    private func layout(in visible: NSRect) {
        guard let window else { return }

        // Arithmetic, not `fittingSize`: a 942-row menu must not measure every
        // row before it can open. Fixed row heights make this exact.
        let content = PaletteMenuMetrics.contentHeight(
            of: model.items,
            searchable: model.searchable
        )
        let height = max(1, min(content, visible.height - 12))

        var x: CGFloat
        var y: CGFloat
        switch placement {
        case .anchored(let anchor):
            x = anchor.minX
            y = anchor.minY - height - 4
            if y < visible.minY { y = anchor.maxY + 4 }
        case .at(let point):
            x = point.x + 2
            y = point.y - height
            if y < visible.minY { y = point.y }
        }
        x = min(max(x, visible.minX + 4), visible.maxX - PaletteMenuLayout.width - 4)
        y = min(max(y, visible.minY + 4), visible.maxY - height - 4)

        let frame = NSRect(x: x, y: y, width: PaletteMenuLayout.width, height: height)
        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
        let bounds = NSRect(origin: .zero, size: frame.size)
        backdrop.frame = bounds
        solid.frame = bounds
        hostingView.frame = bounds
    }

    private func updateAppearance() {
        window?.appearance = theme.nsAppearance
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        backdrop.isHidden = reduceTransparency
        solid.isHidden = !reduceTransparency
        solid.layer?.backgroundColor = theme.nsColor(theme.palette.bg).cgColor
        for layer in [backdrop.layer, solid.layer] {
            layer?.borderWidth = 1
            layer?.borderColor = theme.nsColor(theme.palette.border).cgColor
        }
    }

    // MARK: - Dismissal

    private func installClickMonitors() {
        removeClickMonitors()
        // A click in this app outside the panel dismisses and is consumed, so
        // it cannot immediately reopen the anchored button underneath.
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let window = self.window, window.isVisible else { return event }
            if event.window === window { return event }
            self.hide()
            return nil
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

    // MARK: - Actions and keys

    private func activate(_ item: PaletteMenuItem) {
        guard item.isSelectable else { return }
        let select = onSelect
        hide()
        select?(item.id)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Esc
            return perform(.cancel)
        case 36, 76: // Return, keypad Enter
            return perform(.confirm)
        case 125: // Down
            return perform(.down)
        case 126: // Up
            return perform(.up)
        default:
            return false
        }
    }

    /// Shared by the panel and the search field, so arrows, Return and Esc mean
    /// the same thing whether or not the user is typing.
    @discardableResult
    func perform(_ command: PaletteMenuCommand) -> Bool {
        switch command {
        case .cancel:
            hide()
        case .confirm:
            if let item = model.activation { activate(item) }
        case .up:
            model.move(-1)
            scrollToHighlighted()
        case .down:
            model.move(1)
            scrollToHighlighted()
        }
        return true
    }

    /// Filtering goes through the controller so the list can resize and reset
    /// to the top of the matches.
    func applyQuery(_ text: String) {
        model.setQuery(text)
        layout(in: visibleFrame(for: placement))
        if let scroll = hostScrollView {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private var hostScrollView: NSScrollView? {
        hostingView.firstDescendant(of: NSScrollView.self)
    }

    /// Centres the highlighted row by its known height. Deliberately AppKit,
    /// not `ScrollViewReader`: scrolling to a far row id builds every row
    /// above it, which is exactly the open delay this menu had.
    private func scrollToHighlighted() {
        guard let anchor = model.highlightedID,
              let offset = PaletteMenuMetrics.anchorOffset(of: model.items, anchor: anchor),
              let scroll = hostScrollView else { return }
        let viewport = scroll.contentView.bounds.height
        let content = scroll.documentView?.bounds.height ?? 0
        let topInset = PaletteMenuMetrics.verticalPadding / 2
        let y = min(
            max(0, offset + topInset - viewport / 2),
            max(0, content - viewport)
        )
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Script-only: jump one page and log what that cost, including any rows
    /// the lazy stack had to build.
    func scriptScrollPage(up: Bool = false) async {
        guard let window, window.isVisible, let scroll = hostScrollView else {
            Log.shared.warn("Palette menu page scroll: no scroll view", source: "app")
            return
        }
        let before = rowBuilds
        let started = CFAbsoluteTimeGetCurrent()
        let page = scroll.contentView.bounds.height
        let content = scroll.documentView?.bounds.height ?? page
        var origin = scroll.contentView.bounds.origin
        let delta = up ? -page : page
        origin.y = min(max(0, origin.y + delta), max(0, content - page))
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        // Let the lazy stack realise the rows the page exposed before counting.
        try? await Task.sleep(nanoseconds: 100_000_000)
        Log.shared.info(
            "Palette menu page scroll\(up ? " up" : ""): "
                + String(format: "%.2f ms", ms)
                + ", \(rowBuilds - before) rows built, \(rowBuilds) total "
                + "(\(builtRowIDs.count) unique), windowStart=\(model.windowStart)",
            source: "app"
        )
    }

    /// Script-only: drive the same command path the keys use.
    func scriptKey(_ name: String) {
        let command: PaletteMenuCommand?
        switch name.lowercased() {
        case "down": command = .down
        case "up": command = .up
        case "enter": command = .confirm
        case "esc": command = .cancel
        default: command = nil
        }
        guard let command else {
            Log.shared.warn("Palette menu key: unknown '\(name)'", source: "app")
            return
        }
        _ = perform(command)
        Log.shared.info(
            "Palette menu key '\(name)': highlighted=\(model.highlightedID ?? "-"), "
                + "\(rowBuilds) rows built (\(builtRowIDs.count) unique), "
                + "appActive=\(NSApp.isActive)",
            source: "app"
        )
    }

    /// Script-only: type into the filter without a real keyboard and report
    /// that the app stayed inactive.
    func scriptFilter(_ text: String) {
        applyQuery(text)
        Log.shared.info(
            "Palette menu filter '\(text)': \(model.items.count) rows, "
                + "appActive=\(NSApp.isActive)",
            source: "app"
        )
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let match = subview.firstDescendant(of: type) { return match }
        }
        return nil
    }
}

/// The panel must take key events for arrows, Return and Esc without activating
/// the app, and must never be the main window.
private final class PaletteMenuPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// A key the panel understands, from either the panel itself or the search
/// field's field editor.
enum PaletteMenuCommand {
    case up, down, confirm, cancel
}

/// Watches the panel's own NSScrollView so the window can grow upward before
/// its blank spacer would be visible.
private struct PaletteMenuScrollObserver: NSViewRepresentable {
    let onScroll: (NSScrollView) -> Void

    func makeNSView(context: Context) -> ScrollWatcher {
        let view = ScrollWatcher()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: ScrollWatcher, context: Context) {
        view.onScroll = onScroll
        view.attach()
    }
}

private final class ScrollWatcher: NSView {
    var onScroll: ((NSScrollView) -> Void)?
    private weak var scrollView: NSScrollView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
    }

    func attach() {
        guard let scroll = enclosingScrollView, scroll !== scrollView else { return }
        if let scrollView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }
        scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        // Not during a SwiftUI update: the handler can grow the row window.
        DispatchQueue.main.async { [weak self, weak scroll] in
            guard let self, let scroll else { return }
            self.onScroll?(scroll)
        }
    }

    @objc private func boundsChanged() {
        guard let scrollView else { return }
        onScroll?(scrollView)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The colours and font a row needs, resolved once per render instead of
/// parsing theme hex strings in every row of a 942-row list.
private struct PaletteMenuStyle {
    let fg: Color
    let muted: Color
    let disabledFg: Color
    let accent: Color
    let selection: Color
    let separator: Color
    let font: Font

    init(theme: Theme) {
        fg = theme.color(theme.palette.fg)
        muted = theme.color(theme.palette.fgMuted)
        disabledFg = theme.color(theme.states.disabled.fg ?? theme.palette.fgMuted)
        accent = theme.color(theme.palette.accent)
        selection = theme.color(theme.palette.selectionBg)
        separator = theme.color(theme.palette.separator)
        font = theme.font(size: 13)
    }
}

struct PaletteMenuView: View {
    @ObservedObject var model: PaletteMenuModel
    let theme: Theme
    let select: (PaletteMenuItem) -> Void
    let onCommand: (PaletteMenuCommand) -> Bool
    let onQuery: (String) -> Void
    /// Script mode uses this to report how many rows a menu really builds.
    var onRowBuilt: ((String) -> Void)? = nil

    var body: some View {
        let style = PaletteMenuStyle(theme: theme)
        let start = min(model.windowStart, model.items.count)
        VStack(spacing: 0) {
            if model.searchable {
                PaletteMenuSearchBar(
                    text: model.query,
                    theme: theme,
                    onChange: onQuery,
                    onCommand: onCommand
                )
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    PaletteMenuScrollObserver { scroll in
                        model.ensureRowsAbove(offset: scroll.contentView.bounds.minY)
                    }
                    .frame(height: 0)
                    if start > 0 {
                        // Same height as the rows it replaces: scroll offsets,
                        // scrollbar and centring stay exact.
                        Color.clear
                            .frame(height: PaletteMenuMetrics.offsetBefore(
                                start,
                                in: model.items
                            ))
                    }
                    ForEach(model.items[start...]) { item in
                        row(item, style: style)
                    }
                }
                .padding(.vertical, 5)
                .frame(width: PaletteMenuLayout.width, alignment: .leading)
            }
        }
        .frame(width: PaletteMenuLayout.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Palette menu"))
    }

    @ViewBuilder
    private func row(_ item: PaletteMenuItem, style: PaletteMenuStyle) -> some View {
        let _ = onRowBuilt?(item.id)
        switch item.role {
        case .separator:
            Rectangle()
                .fill(style.separator)
                .frame(height: 1)
                .padding(.horizontal, 10)
                .frame(height: PaletteMenuMetrics.separatorHeight)
                .accessibilityHidden(true)
        case .heading:
            Text(item.title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(style.muted)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: PaletteMenuMetrics.headingHeight)
                .accessibilityHidden(true)
        case .action:
            PaletteMenuRow(
                item: item,
                style: style,
                highlight: model.highlights.box(item.id),
                select: select,
                hover: model.highlight
            )
        }
    }
}

private struct PaletteMenuRow: View {
    let item: PaletteMenuItem
    let style: PaletteMenuStyle
    let highlight: PaletteMenuRowHighlight
    let select: (PaletteMenuItem) -> Void
    let hover: (String) -> Void

    var body: some View {
        // Reading one row's own box is what keeps a highlight change local.
        let highlighted = highlight.isOn && item.enabled
        return HStack(spacing: 8) {
            Text(item.title)
                .font(style.font)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(item.enabled ? style.fg : style.disabledFg)
            Spacer(minLength: 12)
            if item.checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(style.accent)
            }
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(style.muted)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PaletteMenuMetrics.rowHeight)
        .contentShape(Rectangle())
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(style.selection.opacity(0.75))
                    .padding(.horizontal, 4)
            }
        }
        .onTapGesture {
            if item.enabled { select(item) }
        }
        .onHover { inside in
            if inside, item.enabled {
                hover(item.id)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.title))
        .accessibilityValue(Text(item.checked ? "Selected" : ""))
        .accessibilityHint(Text(item.shortcut ?? ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if item.enabled { select(item) }
        }
    }
}

/// Filter field for long menus. It lives in the panel, so it never activates
/// the app: the panel is a nonactivating key window and the field editor takes
/// first responder there.
private struct PaletteMenuSearchBar: View {
    let text: String
    let theme: Theme
    let onChange: (String) -> Void
    let onCommand: (PaletteMenuCommand) -> Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.color(theme.palette.fgMuted))
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text("Search…")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.color(theme.palette.fgMuted))
                        .allowsHitTesting(false)
                }
                PaletteMenuSearchField(
                    text: text,
                    theme: theme,
                    onChange: onChange,
                    onCommand: onCommand
                )
            }
            if !text.isEmpty {
                Button {
                    onChange("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color(theme.palette.fgMuted))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PaletteMenuMetrics.searchBarHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.color(theme.palette.separator))
                .frame(height: 1)
        }
    }
}

private struct PaletteMenuSearchField: NSViewRepresentable {
    let text: String
    let theme: Theme
    let onChange: (String) -> Void
    let onCommand: (PaletteMenuCommand) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onCommand: onCommand)
    }

    func makeNSView(context: Context) -> PaletteSearchTextField {
        let field = PaletteSearchTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = theme.nsColor(theme.palette.fg)
        field.placeholderString = nil
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: PaletteSearchTextField, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onCommand = onCommand
        field.textColor = theme.nsColor(theme.palette.fg)
        if field.stringValue != text {
            field.stringValue = text
            field.window?.makeFirstResponder(field)
        }
    }

    static func dismantleNSView(_ field: PaletteSearchTextField, coordinator: Coordinator) {
        field.delegate = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onChange: (String) -> Void
        var onCommand: (PaletteMenuCommand) -> Bool

        init(
            onChange: @escaping (String) -> Void,
            onCommand: @escaping (PaletteMenuCommand) -> Bool
        ) {
            self.onChange = onChange
            self.onCommand = onCommand
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            onChange(field.stringValue)
        }

        /// Arrows and Return arrive as commands because the field editor, not
        /// the panel, owns the keyboard while the user is typing.
        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): return onCommand(.up)
            case #selector(NSResponder.moveDown(_:)): return onCommand(.down)
            case #selector(NSResponder.insertNewline(_:)): return onCommand(.confirm)
            case #selector(NSResponder.cancelOperation(_:)): return onCommand(.cancel)
            default: return false
            }
        }
    }
}

/// Marker type so the panel can find the filter field and focus it after the
/// window is key; the field editor then owns arrows, Return and Esc.
final class PaletteSearchTextField: NSTextField {}

/// A compact dropdown button that opens `PaletteMenuController`. Its anchor is
/// the real NSView frame, so the panel hangs under the control.
struct PaletteMenuButton: View {
    let title: String
    let items: [PaletteMenuItem]
    let theme: Theme
    let onSelect: (String) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var anchor = PaletteMenuAnchor()

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.color(theme.palette.fgMuted))
            }
            .font(theme.font(size: 12))
            .foregroundStyle(theme.color(theme.palette.fg))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.color(theme.palette.elevated).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(theme.color(theme.palette.border), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .overlay(
            PaletteMenuAnchorView(anchor: anchor)
                .allowsHitTesting(false)
        )
    }

    private func open() {
        guard let rect = anchor.screenRect else { return }
        PaletteMenuController.shared.show(
            items: items,
            anchoredTo: rect,
            theme: theme,
            onSelect: onSelect
        )
    }
}

/// One choice in a `PaletteMenuPicker`. A heading starts a group; the picker
/// draws it once even when every following choice repeats it.
struct PaletteMenuChoice<Value: Equatable> {
    var value: Value
    var label: String
    var heading: String? = nil
}

/// A `Picker` replacement: the button shows the selected label and the panel
/// lists every choice with a checkmark. Long lists (fonts, themes, models)
/// scroll and follow the keyboard highlight.
struct PaletteMenuPicker<Value: Equatable>: View {
    @Binding var selection: Value
    let choices: [PaletteMenuChoice<Value>]
    let theme: Theme

    var body: some View {
        PaletteMenuButton(title: selectedLabel, items: items, theme: theme) { id in
            guard let index = choiceIndex(id), choices.indices.contains(index) else { return }
            selection = choices[index].value
        }
    }

    private var selectedLabel: String {
        choices.first { $0.value == selection }?.label ?? ""
    }

    private func choiceIndex(_ id: String) -> Int? {
        guard id.hasPrefix("choice:") else { return nil }
        return Int(id.dropFirst("choice:".count))
    }

    private var items: [PaletteMenuItem] {
        var result: [PaletteMenuItem] = []
        var lastHeading: String?
        for (index, choice) in choices.enumerated() {
            if let heading = choice.heading, heading != lastHeading {
                result.append(.heading("heading:\(index)", heading))
                lastHeading = heading
            }
            result.append(PaletteMenuItem(
                id: "choice:\(index)",
                title: choice.label,
                checked: choice.value == selection
            ))
        }
        return result
    }
}

/// Holds the button's backing view so its frame can be read in screen
/// coordinates when the panel opens.
final class PaletteMenuAnchor {
    weak var view: NSView?

    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct PaletteMenuAnchorView: NSViewRepresentable {
    let anchor: PaletteMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NonBlockingView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

private final class NonBlockingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Right-click catcher for launcher rows. It claims only `rightMouseDown`, so
/// tap, hover and selection still reach the SwiftUI row underneath.
struct RightClickMenuArea: NSViewRepresentable {
    let onRightClick: (NSPoint) -> Void

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: RightClickView, context: Context) {
        nsView.onRightClick = onRightClick
    }
}

final class RightClickView: NSView {
    var onRightClick: ((NSPoint) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type == .rightMouseDown else { return nil }
        return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(NSEvent.mouseLocation)
    }
}
