import AppKit
import Combine
import PaletteCore
import PalettePlatform
import SwiftUI

/// What the panel draws. The controller owns this and replaces `sections` on
/// every refresh, so the rows always match the live capture and sleep state.
@MainActor
final class StatusPanelModel: ObservableObject {
    @Published var sections: [StatusPanelSection] = []
    @Published var highlighted: StatusPanelCommand?
}

/// A borderless floating panel under the status item. It replaces the old
/// `NSMenu`: no tracking loop, so global hotkeys keep working while it is open.
@MainActor
final class StatusPanelController: NSWindowController {
    private let model = StatusPanelModel()
    private let themeManager: ThemeManager
    private let snapshotProvider: () -> StatusPanelSnapshot
    private let actionHandler: (StatusPanelCommand) -> Void
    /// The status button in screen coordinates, so the panel hangs under it.
    private let anchorProvider: () -> CGRect?
    /// True for a click on the status button itself, which toggles the panel
    /// instead of counting as a click outside it.
    private let isAnchorEvent: (NSEvent) -> Bool

    private var hostingView: NSHostingView<StatusPanelView>!
    private let scrollView = NSScrollView()
    private let backdrop = NSVisualEffectView()
    private let solid = NSView()
    private var refreshTimer: Timer?
    private var clickMonitors: [Any] = []
    private var appearanceObserver: NSObjectProtocol?
    private var themeCancellable: AnyCancellable?

    private static let cornerRadius: CGFloat = 10

    init(
        themeManager: ThemeManager,
        snapshot: @escaping () -> StatusPanelSnapshot,
        perform: @escaping (StatusPanelCommand) -> Void,
        anchor: @escaping () -> CGRect?,
        isAnchorEvent: @escaping (NSEvent) -> Bool
    ) {
        self.themeManager = themeManager
        self.snapshotProvider = snapshot
        self.actionHandler = perform
        self.anchorProvider = anchor
        self.isAnchorEvent = isAnchorEvent

        let panel = StatusPanelWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: StatusPanelLayout.width,
                height: 400
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

        let view = StatusPanelView(
            model: model,
            themeManager: themeManager,
            activate: { [weak self] command in self?.activate(command) }
        )
        let hosting = NSHostingView(rootView: view)
        hostingView = hosting

        backdrop.material = .menu
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Self.cornerRadius
        backdrop.layer?.masksToBounds = true

        solid.wantsLayer = true
        solid.layer?.cornerRadius = Self.cornerRadius
        solid.layer?.masksToBounds = true

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = hosting

        panel.contentView = backdrop
        backdrop.addSubview(solid)
        backdrop.addSubview(scrollView)
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

    /// Script-only observables: the dump proves the panel rendered rows and
    /// that the arrows moved the highlight.
    var scriptRowCount: Int { model.sections.flatMap(\.rows).count }
    var scriptHighlightedTitle: String {
        guard let command = model.highlighted,
              let row = model.sections.flatMap(\.rows).first(where: { $0.command == command })
        else { return "" }
        return row.title
    }

    func scriptKey(_ event: NSEvent) -> Bool { handleKey(event) }

    func show() {
        guard let window else { return }
        refresh()
        Log.shared.info(
            "Status panel showing \(model.sections.count) sections, "
                + "\(model.sections.flatMap(\.rows).count) rows",
            source: "app"
        )
        installClickMonitors()
        updateAppearance()
        startRefreshTimer()
        if WindowPresentation.isScripted {
            // A scripted run must leave focus alone; the panel still renders.
            window.orderFront(nil)
            Log.shared.info(
                "Script mode: status panel shown without activation "
                    + "(appActive=\(NSApp.isActive))",
                source: "app"
            )
        } else {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        // Leave the window as first responder so keyDown reaches the panel
        // instead of SwiftUI's focus system.
        window.makeFirstResponder(nil)
    }

    func hide() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        removeClickMonitors()
        window?.orderOut(nil)
    }

    func toggle() {
        if isOpen { hide() } else { show() }
    }

    /// Re-render now instead of waiting for the next tick, e.g. after a capture
    /// stops or keep-awake changes.
    func refreshSoon() {
        guard isOpen else { return }
        refresh()
    }

    // MARK: - State

    private func refresh() {
        let sections = StatusPanelMenu.sections(snapshotProvider())
        if model.sections != sections {
            model.sections = sections
        }
        let enabled = sections.flatMap(\.rows).filter(\.enabled).map(\.command)
        if let highlighted = model.highlighted, enabled.contains(highlighted) {
            // Keep the keyboard selection across a refresh.
        } else {
            model.highlighted = enabled.first
        }
        layoutPanel()
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - Layout

    private func anchorRect() -> CGRect? {
        anchorProvider()
    }

    private func currentScreen() -> NSScreen? {
        if let anchor = anchorRect(),
           let screen = NSScreen.screens.first(where: {
               $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY))
           }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func layoutPanel() {
        guard let window, let screen = currentScreen() else { return }
        let width = StatusPanelLayout.width
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        hostingView.layoutSubtreeIfNeeded()
        let contentHeight = max(1, hostingView.fittingSize.height)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)

        let height = StatusPanelLayout.panelHeight(
            content: contentHeight,
            screen: screen.visibleFrame
        )
        let anchor = anchorRect() ?? CGRect(
            x: screen.visibleFrame.maxX - 24,
            y: screen.visibleFrame.maxY - 24,
            width: 24,
            height: 24
        )
        let frame = StatusPanelLayout.frame(
            anchor: anchor,
            size: CGSize(width: width, height: height),
            screen: screen.visibleFrame
        )
        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
        let bounds = NSRect(origin: .zero, size: frame.size)
        backdrop.frame = bounds
        solid.frame = bounds
        scrollView.frame = bounds
        scrollView.hasVerticalScroller = contentHeight > height + 0.5
        if scrollView.hasVerticalScroller {
            // Rows start at the top, whether the hosting view is flipped or not.
            let top = hostingView.isFlipped ? 0 : contentHeight - height
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        hostingView.layoutSubtreeIfNeeded()
    }

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
    }

    // MARK: - Dismissal

    private func installClickMonitors() {
        removeClickMonitors()
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if self.isAnchorEvent(event) { return event }
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

    // MARK: - Actions and keys

    private func activate(_ command: StatusPanelCommand?) {
        guard let command,
              model.sections.flatMap(\.rows).contains(where: { $0.command == command && $0.enabled })
        else { return }
        hide()
        actionHandler(command)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "r":
                activate(.reloadConfig)
                return true
            case "q":
                activate(.quit)
                return true
            default:
                break
            }
        }
        switch event.keyCode {
        case 53: // Esc
            hide()
            return true
        case 36, 76: // Return, keypad Enter
            activate(model.highlighted)
            return true
        case 125, 124: // Down, Right
            moveHighlight(1)
            return true
        case 126, 123: // Up, Left
            moveHighlight(-1)
            return true
        default:
            return false
        }
    }

    private func moveHighlight(_ delta: Int) {
        let commands = model.sections.flatMap(\.rows).filter(\.enabled).map(\.command)
        guard !commands.isEmpty else { return }
        guard let current = model.highlighted,
              let index = commands.firstIndex(of: current) else {
            model.highlighted = commands.first
            return
        }
        let next = (index + delta + commands.count) % commands.count
        model.highlighted = commands[next]
    }
}

/// The panel must take key events for arrows and Return without activating the
/// app, and must never be the main window.
private final class StatusPanelWindow: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

private struct StatusPanelView: View {
    @ObservedObject var model: StatusPanelModel
    @ObservedObject var themeManager: ThemeManager
    var activate: (StatusPanelCommand) -> Void

    private var theme: Theme { themeManager.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    Rectangle()
                        .fill(theme.color(theme.palette.separator))
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                sectionView(section, first: index == 0)
            }
        }
        .padding(.vertical, 6)
        .frame(width: StatusPanelLayout.width, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Palette menu"))
    }

    private func sectionView(_ section: StatusPanelSection, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = section.title {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(theme.color(theme.palette.fgMuted))
                    .padding(.horizontal, 12)
                    .padding(.top, first ? 0 : 2)
                    .padding(.bottom, 3)
            }
            if let detail = section.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color(theme.palette.fg))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 3)
            }
            ForEach(section.rows) { row in
                rowView(row)
            }
        }
    }

    private func rowView(_ row: StatusPanelRow) -> some View {
        let highlighted = model.highlighted == row.command && row.enabled
        return Button {
            activate(row.command)
        } label: {
            HStack(spacing: 8) {
                Text(row.title)
                    .font(theme.font(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(
                        row.enabled
                            ? theme.color(theme.palette.fg)
                            : theme.color(theme.states.disabled.fg ?? theme.palette.fgMuted)
                    )
                Spacer(minLength: 0)
                if row.checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(theme.color(theme.palette.accent))
                }
                if let hint = row.keyHint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color(theme.palette.fgMuted))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(theme.color(theme.palette.selectionBg).opacity(0.7))
                        .padding(.horizontal, 5)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!row.enabled)
        .focusable(false)
        .onHover { inside in
            if inside, row.enabled {
                model.highlighted = row.command
            }
        }
        .accessibilityLabel(Text(row.title))
        .accessibilityValue(Text(row.checked ? "Selected" : ""))
        .accessibilityAddTraits(.isButton)
    }
}
