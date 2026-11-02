import AppKit
import PaletteCore
import SwiftUI

/// A borderless, non-activating panel that can still become key so the search
/// field receives keystrokes without stealing the app's menu bar.
public final class PalettePanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

@MainActor
public final class PanelController: NSWindowController, NSWindowDelegate {
    public let panel: PalettePanel
    public let effectView = NSVisualEffectView()
    public let contentContainer = NSView()

    /// Return true to consume the event.
    public var onKeyDown: ((NSEvent) -> Bool)?
    public var onShow: (() -> Void)?
    public var onHide: (() -> Void)?

    /// Set while an in-panel prompt is open, so resigning key does not hide it.
    public var suppressAutoHide = false
    public var activatePreviousOnHide = true

    public private(set) var previousApplication: NSRunningApplication?
    /// Wider panel for preview layouts (clipboard window). Nil uses the theme.
    public var widthOverride: CGFloat? {
        didSet { if isShowing { position() } }
    }

    /// Config `search_position` wins over the theme's window anchor.
    public var anchorOverride: String? {
        didSet { if isShowing { position() } }
    }
    private var keyMonitor: Any?
    private var contentHeight: CGFloat = 200
    private var theme: Theme
    private var isShowing = false

    public init(theme: Theme, content: NSView) {
        self.theme = theme
        let panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: theme.window.width, height: contentHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        super.init(window: panel)

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false

        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.material = .hudWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = theme.window.cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true

        panel.contentView = effectView
        effectView.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: effectView.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])

        setContent(content)
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public var isVisible: Bool { isShowing }

    public func setContent(_ view: NSView) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    public func setContentHeight(_ height: CGFloat) {
        contentHeight = max(92, min(height, CGFloat(theme.window.maxHeight)))
        if isShowing { position() }
    }

    public func apply(theme: Theme) {
        self.theme = theme
        effectView.material = Self.material(named: theme.window.material)
        effectView.layer?.cornerRadius = theme.window.cornerRadius
        effectView.layer?.borderWidth = 0
        panel.hasShadow = theme.window.shadow
        panel.appearance = NSAppearance(named: theme.appearance == "light" ? .aqua : .darkAqua)
        effectView.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : theme.window.opacity
        if isShowing { position() }
    }

    public func show() {
        guard !isShowing else { return }
        let current = NSWorkspace.shared.frontmostApplication
        if current?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = current
        }
        onShow?()
        isShowing = true
        position()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    public func hide(activatePrevious: Bool? = nil) {
        guard isShowing else { return }
        isShowing = false
        removeKeyMonitor()
        panel.orderOut(nil)
        let shouldActivate = activatePrevious ?? activatePreviousOnHide
        if shouldActivate, let previousApplication, !previousApplication.isTerminated {
            previousApplication.activate(options: [])
        }
        onHide?()
    }

    public func toggle() {
        isShowing ? hide() : show()
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard !suppressAutoHide else { return }
        // A short delay lets an in-panel menu or prompt take key first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.isShowing, !self.suppressAutoHide, !self.panel.isKeyWindow else { return }
            self.hide(activatePrevious: false)
        }
    }

    private func position() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let width = widthOverride ?? CGFloat(theme.window.width)
        let height = min(contentHeight, CGFloat(theme.window.maxHeight))
        var x = visible.midX - width / 2
        var y: CGFloat

        switch (anchorOverride ?? theme.window.anchor).lowercased() {
        case "center":
            y = visible.midY - height / 2
        case "bottom":
            let offset = theme.window.offsetYPercent
                ? visible.height * CGFloat(theme.window.offsetY) / 100
                : CGFloat(theme.window.offsetY)
            y = visible.minY + offset
        default:
            let offset = theme.window.offsetYPercent
                ? visible.height * CGFloat(theme.window.offsetY) / 100
                : CGFloat(theme.window.offsetY)
            y = visible.maxY - offset - height
        }

        x = max(visible.minX + 12, min(x, visible.maxX - width - 12))
        y = max(visible.minY + 12, min(y, visible.maxY - height - 12))
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isShowing, event.window === self.panel else { return event }
            if self.onKeyDown?(event) == true { return nil }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private static func material(named name: String) -> NSVisualEffectView.Material {
        switch name.lowercased() {
        case "popover": return .popover
        case "menu": return .menu
        case "sidebar": return .sidebar
        case "underwindowbackground": return .underWindowBackground
        case "windowbackground": return .windowBackground
        case "contentbackground": return .contentBackground
        case "titlebar": return .titlebar
        default: return .hudWindow
        }
    }
}
