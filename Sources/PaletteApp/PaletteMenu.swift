import AppKit
import PaletteCore
import PalettePlatform
import SwiftUI

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
@MainActor
final class PaletteMenuModel: ObservableObject {
    @Published var selection = PaletteMenuSelection(items: [])
}

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
            maxHeight: 400,
            select: { [weak self] item in self?.activate(item) }
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
        if isOpen { hide() }
        guard !items.isEmpty else { return }

        self.theme = theme
        self.placement = placement
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        model.selection = PaletteMenuSelection(
            items: items,
            preferred: items.first(where: { $0.checked && $0.isSelectable })?.id
        )
        let visible = visibleFrame(for: placement)
        hostingView.rootView = PaletteMenuView(
            model: model,
            theme: theme,
            maxHeight: max(1, visible.height - 12),
            select: { [weak self] item in self?.activate(item) }
        )
        updateAppearance()
        installClickMonitors()
        layout(in: visible)

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
        // SwiftUI's focus system.
        window.makeFirstResponder(nil)
    }

    func hide() {
        guard let window, window.isVisible else { return }
        removeClickMonitors()
        model.selection.dismiss()
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

        hostingView.frame = NSRect(x: 0, y: 0, width: PaletteMenuLayout.width, height: 1)
        hostingView.layoutSubtreeIfNeeded()
        let height = max(1, min(hostingView.fittingSize.height, visible.height - 12))

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
        hostingView.layoutSubtreeIfNeeded()
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
            hide()
            return true
        case 36, 76: // Return, keypad Enter
            if let item = model.selection.activation {
                activate(item)
            }
            return true
        case 125: // Down
            model.selection.move(1)
            return true
        case 126: // Up
            model.selection.move(-1)
            return true
        default:
            return false
        }
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

private struct PaletteMenuView: View {
    @ObservedObject var model: PaletteMenuModel
    let theme: Theme
    let maxHeight: CGFloat
    let select: (PaletteMenuItem) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.selection.items) { item in
                        switch item.role {
                        case .separator:
                            Rectangle()
                                .fill(theme.color(theme.palette.separator))
                                .frame(height: 1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .accessibilityHidden(true)
                        case .heading:
                            Text(item.title.uppercased())
                                .font(.system(size: 9.5, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(theme.color(theme.palette.fgMuted))
                                .padding(.horizontal, 10)
                                .padding(.top, 5)
                                .padding(.bottom, 2)
                                .accessibilityHidden(true)
                        case .action:
                            row(item)
                                .id(item.id)
                        }
                    }
                }
                .padding(.vertical, 5)
                .frame(width: PaletteMenuLayout.width, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .frame(width: PaletteMenuLayout.width)
            .frame(maxHeight: maxHeight)
            .onChange(of: model.selection.highlightedID) { _, id in
                guard let id else { return }
                withAnimation(nil) { proxy.scrollTo(id, anchor: .center) }
            }
            .task {
                if let id = model.selection.highlightedID {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Palette menu"))
    }

    private func row(_ item: PaletteMenuItem) -> some View {
        let highlighted = model.selection.highlightedID == item.id && item.enabled
        return Button {
            select(item)
        } label: {
            HStack(spacing: 8) {
                Text(item.title)
                    .font(theme.font(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(
                        item.enabled
                            ? theme.color(theme.palette.fg)
                            : theme.color(theme.states.disabled.fg ?? theme.palette.fgMuted)
                    )
                Spacer(minLength: 12)
                if item.checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(theme.color(theme.palette.accent))
                }
                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color(theme.palette.fgMuted))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(theme.color(theme.palette.selectionBg).opacity(0.75))
                        .padding(.horizontal, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
        .focusable(false)
        .onHover { inside in
            if inside, item.enabled {
                model.selection.highlight(item.id)
            }
        }
        .accessibilityLabel(Text(item.title))
        .accessibilityValue(Text(item.checked ? "Selected" : ""))
        .accessibilityHint(Text(item.shortcut ?? ""))
        .accessibilityAddTraits(.isButton)
    }
}

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
