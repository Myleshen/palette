import AppKit
import PaletteCore

/// One screenshot floating above other apps. It is click-through until Option
/// is held, so a pin never takes a click meant for the window underneath.
@MainActor
final class PinnedScreenshotWindowController: NSWindowController, NSWindowDelegate {
    private let imageView = PinImageView()
    private let closeButton = NSButton()
    private let resizeHandle = PinResizeHandle()
    private let aspect: CGFloat
    private var isInteractive = false
    var onClose: ((PinnedScreenshotWindowController) -> Void)?
    /// Reports moves and resizes so the next pin cascades from where this one
    /// actually sits.
    var onFrameChange: ((CGRect) -> Void)?

    init(image: NSImage, name: String, frame: CGRect) {
        aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let window = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.ignoresMouseEvents = true
        super.init(window: window)
        window.delegate = self

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = content.bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.setAccessibilityLabel("Pinned screenshot \(name)")
        imageView.onScroll = { [weak self] delta in self?.scrollZoom(delta) }
        content.addSubview(imageView)

        closeButton.frame = NSRect(x: 8, y: frame.height - 30, width: 22, height: 22)
        closeButton.autoresizingMask = [.minYMargin]
        closeButton.isBordered = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Close pinned screenshot"
        )
        closeButton.contentTintColor = .white
        closeButton.target = self
        closeButton.action = #selector(closePin)
        closeButton.isHidden = true
        content.addSubview(closeButton)

        resizeHandle.frame = NSRect(x: frame.width - 20, y: 0, width: 20, height: 20)
        resizeHandle.autoresizingMask = [.minXMargin, .maxYMargin]
        resizeHandle.onDrag = { [weak self] delta in self?.resize(by: delta) }
        resizeHandle.isHidden = true
        content.addSubview(resizeHandle)

        window.contentView = content
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Option-hover switches the pin from click-through to draggable and shows
    /// the controls that only matter in that mode.
    func setInteractive(_ interactive: Bool) {
        guard interactive != isInteractive, let window else { return }
        isInteractive = interactive
        window.ignoresMouseEvents = !interactive
        closeButton.isHidden = !interactive
        resizeHandle.isHidden = !interactive
    }

    func contains(screenPoint: NSPoint) -> Bool {
        window?.frame.contains(screenPoint) ?? false
    }

    private func resize(by delta: CGFloat) {
        guard let window else { return }
        let screen = window.screen?.visibleFrame ?? window.frame
        let maximum = screen.width - PinnedPlacement.margin * 2
        let width = min(max(80, window.frame.width + delta), maximum)
        let height = width / aspect
        // Keep the top-left corner put: a pin grows from where it was.
        var next = CGRect(
            x: window.frame.minX,
            y: window.frame.maxY - height,
            width: width,
            height: height
        )
        next = PinnedPlacement.clamp(next, to: screen)
        window.setFrame(next, display: true)
    }

    private func scrollZoom(_ delta: CGFloat) {
        guard let window, delta != 0 else { return }
        let screen = window.screen?.visibleFrame ?? window.frame
        let factor = pow(1.1, min(max(delta, -3), 3))
        let width = min(max(80, window.frame.width * factor), screen.width - PinnedPlacement.margin * 2)
        let height = width / aspect
        var next = CGRect(
            x: window.frame.midX - width / 2,
            y: window.frame.midY - height / 2,
            width: width,
            height: height
        )
        next = PinnedPlacement.clamp(next, to: screen)
        window.setFrame(next, display: true)
    }

    @objc private func closePin() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        imageView.image = nil
        onClose?(self)
    }

    func windowDidMove(_ notification: Notification) {
        reportFrame()
    }

    func windowDidResize(_ notification: Notification) {
        reportFrame()
    }

    private func reportFrame() {
        guard let frame = window?.frame else { return }
        onFrameChange?(frame)
    }
}

/// Only receives scrolls while Option is held, because the panel ignores the
/// mouse the rest of the time.
private final class PinImageView: NSImageView {
    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 120 : event.scrollingDeltaY
        if step != 0 { onScroll?(step) }
    }
}

/// Bottom-right corner grip, visible only in Option mode.
private final class PinResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        let line = NSBezierPath()
        line.lineWidth = 1.5
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: 6, y: 14))
        line.line(to: NSPoint(x: 14, y: 6))
        line.move(to: NSPoint(x: 11, y: 14))
        line.line(to: NSPoint(x: 14, y: 11))
        NSColor.white.withAlphaComponent(0.9).setStroke()
        line.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // Absorb the press so the window's background drag does not start.
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX)
    }
}

/// Owns every live pin for the session. Pins are few, so the cascade position
/// and the cap are all the state there is; nothing survives a relaunch.
@MainActor
final class PinnedScreenshotManager {
    private var pins: [PinnedScreenshotWindowController] = []
    private var lastFrame: CGRect?
    private var ticker: Timer?

    /// Shows the file already on disk; no second capture and no copy.
    @discardableResult
    func pin(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data),
              image.size.width > 0, image.size.height > 0,
              let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                  ?? NSScreen.main)?.visibleFrame else { return false }
        let frame = PinnedPlacement.frame(previous: lastFrame, size: image.size, screen: screen)
        let controller = PinnedScreenshotWindowController(
            image: image,
            name: url.lastPathComponent,
            frame: frame
        )
        controller.onClose = { [weak self, weak controller] _ in
            guard let self else { return }
            self.pins.removeAll { $0 === controller }
            self.stopTickerIfIdle()
        }
        controller.onFrameChange = { [weak self, weak controller] frame in
            guard let self, let controller, self.pins.last === controller else { return }
            self.lastFrame = frame
        }
        pins.append(controller)
        lastFrame = frame
        while pins.count > PinnedPlacement.maximumPins {
            pins.removeFirst().close()
        }
        controller.showWindow(nil)
        controller.window?.orderFrontRegardless()
        startTicker()
        return true
    }

    func closeAll() {
        ticker?.invalidate()
        ticker = nil
        let open = pins
        pins.removeAll()
        for controller in open { controller.close() }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshInteraction() }
        }
    }

    private func stopTickerIfIdle() {
        guard pins.isEmpty else { return }
        ticker?.invalidate()
        ticker = nil
    }

    /// Option is not delivered to a click-through window, so the modifier and
    /// pointer are sampled while any pin is alive.
    private func refreshInteraction() {
        let option = NSEvent.modifierFlags.contains(.option)
        let point = NSEvent.mouseLocation
        for pin in pins {
            pin.setInteractive(option && pin.contains(screenPoint: point))
        }
    }
}
