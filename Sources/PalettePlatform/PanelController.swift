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
    public let contentContainer = NSView()

    /// Return true to consume the event.
    public var onKeyDown: ((NSEvent) -> Bool)?
    public var onShow: (() -> Void)?
    public var onHide: (() -> Void)?

    /// Set while an in-panel prompt is open, so resigning key does not hide it.
    public var suppressAutoHide = false
    public var activatePreviousOnHide = true
    /// Scripted runs must not disturb the desktop: a quiet panel is ordered to
    /// the back of the normal level, never key, and never activates the app.
    public var quiet = false

    public private(set) var previousApplication: NSRunningApplication?

    /// Sizing comes from config's fixed per-screen frame. The panel never
    /// sizes itself to its content, a preview, or a mode.
    public var windowConfig = WindowConfig() {
        didSet { if isShowing { position() } }
    }

    /// True while the embedded terminal is open: it opens at
    /// `WindowConfig.terminalSize(for:)`, centred, instead of the launcher frame.
    public var terminalFrame = false {
        didSet { if isShowing { position() } }
    }

    /// Config `search_position` wins over the theme's window anchor.
    public var anchorOverride: String? {
        didSet { if isShowing { position() } }
    }

    private var keyMonitor: Any?
    private var theme: Theme
    private var isShowing = false

    public init(theme: Theme, content: NSView) {
        self.theme = theme
        let initial = WindowConfig().launcherSize(for: CGSize(width: 1440, height: 900))
        let panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: initial.width, height: initial.height),
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

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true

        let rootView = NSView()
        rootView.wantsLayer = true
        panel.contentView = rootView
        rootView.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: rootView.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
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

    public func apply(theme: Theme) {
        self.theme = theme
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: theme.appearance == "light" ? .aqua : .darkAqua)
        if isShowing { position() }
    }

    public func show() {
        guard !isShowing else { return }
        if !quiet {
            let current = NSWorkspace.shared.frontmostApplication
            if current?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApplication = current
            }
        }
        onShow?()
        isShowing = true
        position()
        if quiet {
            panel.level = .normal
            panel.orderBack(nil)
            Log.shared.info(
                "Script mode: panel shown without activation (appActive=\(NSApp.isActive))",
                source: "app"
            )
            return
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    public func hide(activatePrevious: Bool? = nil) {
        guard isShowing else { return }
        isShowing = false
        removeKeyMonitor()
        panel.orderOut(nil)
        let shouldActivate = !quiet && (activatePrevious ?? activatePreviousOnHide)
        if shouldActivate, let previousApplication, !previousApplication.isTerminated {
            previousApplication.activate(options: [])
        }
        onHide?()
    }

    public func toggle() {
        isShowing ? hide() : show()
    }

    public func windowDidResignKey(_ notification: Notification) {
        // A scripted run must survive the user clicking elsewhere.
        guard !quiet, !suppressAutoHide else { return }
        // A short delay lets an in-panel menu or prompt take key first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.isShowing, !self.suppressAutoHide, !self.panel.isKeyWindow else { return }
            self.hide(activatePrevious: false)
        }
    }

    /// The screen the cursor is on: that is the one the panel opens on.
    public static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Script-only visible-frame override, so a dock/undock size change can be
    /// exercised on a single-display machine.
    public var screenSizeOverride: CGSize?

    private func position() {
        let screen = Self.screenUnderPointer()
        guard let screen else { return }
        let visible = screen.visibleFrame
        // Never grow past the usable screen area, whatever an override asks for.
        let metrics = screenSizeOverride ?? visible.size
        let size = terminalFrame
            ? windowConfig.terminalSize(for: metrics)
            : windowConfig.launcherSize(for: metrics)
        let width = min(size.width, visible.width - 24)
        let height = min(size.height, visible.height - 24)
        var x = visible.midX - width / 2
        var y: CGFloat

        if terminalFrame {
            y = visible.midY - height / 2
        } else {
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
}
