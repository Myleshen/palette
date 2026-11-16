import AppKit
import PalettePlatform
import SwiftUI
import UniformTypeIdentifiers

/// Annotate window: a screenshot, a small tool strip, and Save/Copy.
@MainActor
final class AnnotateWindowController: NSWindowController, NSWindowDelegate {
    private let editor: AnnotationEditor
    var onClose: (() -> Void)?
    var shapeCount: Int { editor.shapes.count }

    init(image: NSImage, url: URL?) {
        editor = AnnotationEditor(image: image, url: url)

        let size = image.size
        let maxSize = NSSize(width: 1180, height: 760)
        let scale = min(1, min(maxSize.width / max(1, size.width), maxSize.height / max(1, size.height)))
        // A panel, not a standard window: tiling WMs (Amethyst) only manage
        // AXStandardWindow, so this stays where it is instead of going
        // full-screen, and a floating level keeps it above the app the user
        // came from.
        // The toolbar needs ~780 pt; a small screenshot must not squeeze its
        // buttons to nothing, so the window keeps a floor and letterboxes.
        let width = max(820, size.width * scale)
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: max(360, size.height * scale + 44)),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setAccessibilitySubrole(.dialog)
        window.title = url?.lastPathComponent ?? "Annotate"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.backgroundColor = NSColor(white: 0.10, alpha: 1)
        window.isOpaque = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 320)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: AnnotateView(editor: editor, close: { [weak self] in self?.close() }))
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        // Palette is an accessory app (LSUIElement), so its windows never become
        // key on their own and the canvas would not receive clicks.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        showWindow(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window?.makeKeyAndOrderFront(nil)
        window?.makeKey()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// Plain capsules instead of AppKit push buttons: the stock bezel drew a
/// white pill with invisible text inside a dark window.
struct PillButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color(white: 1, opacity: configuration.isPressed ? 0.28 : 0.14))
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

struct AnnotateView: View {
    @ObservedObject var editor: AnnotationEditor
    var close: () -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var moving: Moving?
    @State private var textEntry: TextEntry?
    @State private var zoom: CGFloat = 1
    @State private var toast: String?
    @State private var toastToken = 0
    @State private var unsaved = false
    @FocusState private var textFocused: Bool

    private struct Moving {
        var index: Int
        var original: AnnotationShape
        var start: CGPoint
    }

    private struct TextEntry {
        var point: CGPoint
        var value: String
    }

    private let palette: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white, .black]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                let base = fittedSize(in: geo.size)
                let canvas = CGSize(width: base.width * zoom, height: base.height * zoom)
                ScrollView([.horizontal, .vertical]) {
                    ZStack {
                        Color(white: 0.10)
                        canvasView(canvas)
                    }
                    .frame(
                        width: max(canvas.width, geo.size.width),
                        height: max(canvas.height, geo.size.height)
                    )
                }
                .background(Color(white: 0.10))
                .overlay(alignment: .top) { toastView }
                .task(id: toastToken) {
                    guard toast != nil else { return }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    withAnimation { toast = nil }
                }
            }
        }
        .onKeyPress(.delete) {
            guard editor.selected != nil else { return .ignored }
            editor.removeSelected()
            unsaved = true
            return .handled
        }
        .onKeyPress(.deleteForward) {
            guard editor.selected != nil else { return .ignored }
            editor.removeSelected()
            unsaved = true
            return .handled
        }
        .onKeyPress(.escape) {
            if textEntry != nil {
                textEntry = nil
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Canvas

    private func canvasView(_ size: CGSize) -> some View {
        let rect = CGRect(origin: .zero, size: size)
        return Canvas { context, _ in
            context.draw(Image(nsImage: editor.image), in: rect)
            for (index, shape) in editor.shapes.enumerated() {
                draw(shape, context: &context, fitted: rect)
                if index == editor.selected {
                    drawSelection(shape, context: &context, fitted: rect)
                }
            }
            drawDragPreview(context: &context, fitted: rect)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(drag(in: rect))
        .overlay(alignment: .topLeading) { textFieldOverlay(size) }
    }

    private func textFieldOverlay(_ size: CGSize) -> some View {
        Group {
            if let entry = textEntry {
                TextField("Text", text: Binding(
                    get: { textEntry?.value ?? "" },
                    set: { textEntry?.value = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .frame(width: 180)
                .focused($textFocused)
                .onSubmit { commitText() }
                .position(x: entry.point.x * size.width, y: entry.point.y * size.height)
            }
        }
    }

    private var toastView: some View {
        Group {
            if let toast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(toast).lineLimit(2)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(Color(white: 0.16))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
                )
                .padding(.top, 14)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            ForEach(AnnotateTool.allCases) { tool in
                toolButton(tool)
            }
            Divider().frame(height: 18)
            ForEach(palette, id: \.self) { colour in
                Button {
                    editor.color = colour
                } label: {
                    Circle()
                        .fill(Color(nsColor: colour))
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle().strokeBorder(.white.opacity(editor.color == colour ? 0.9 : 0.2), lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour")
            }
            if editor.tool == .text {
                Stepper(value: $editor.textSize, in: 0.02...0.15, step: 0.005) {
                    Text("Aa \(Int(editor.textSize * 100))").font(.system(size: 10)).monospacedDigit()
                }
                .frame(width: 92)
                .accessibilityLabel("Text size")
            } else {
                Slider(value: $editor.lineWidth, in: 0.001...0.02)
                    .frame(width: 70)
                    .accessibilityLabel("Line width")
            }
            Divider().frame(height: 18)
            Button { zoom = max(0.25, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom out")
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38)
            Button { zoom = min(4, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom in")
            Button { zoom = 1 } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .keyboardShortcut("0", modifiers: .command)
                .buttonStyle(.plain)
                .accessibilityLabel("Fit")
            Spacer()
            Button("Undo") { undo() }
                .disabled(!editor.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button("Copy") { copyImage() }
                .keyboardShortcut("c", modifiers: .command)
            Button("Save As") { saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Done") { finish() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .buttonStyle(PillButton())
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(Color(white: 0.12))
    }

    private func toolButton(_ tool: AnnotateTool) -> some View {
        Button {
            editor.tool = tool
            editor.selected = nil
        } label: {
            Label(tool.title, systemImage: tool.symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(editor.tool == tool ? Color.accentColor.opacity(0.25) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(tool.title)
        .accessibilityLabel(tool.title)
    }

    // MARK: - Geometry

    private func fittedSize(in view: CGSize) -> CGSize {
        let image = editor.image.size
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(view.width / image.width, view.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    private func fraction(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(
            x: min(1, max(0, (point.x - rect.minX) / rect.width)),
            y: min(1, max(0, (point.y - rect.minY) / rect.height))
        )
    }

    // MARK: - Drawing

    private func draw(_ shape: AnnotationShape, context: inout GraphicsContext, fitted: CGRect) {
        let colour = Color(nsColor: shape.color)
        switch shape {
        case let .arrow(from, to, _, width):
            let start = CGPoint(x: fitted.minX + from.x * fitted.width, y: fitted.minY + from.y * fitted.height)
            let end = CGPoint(x: fitted.minX + to.x * fitted.width, y: fitted.minY + to.y * fitted.height)
            let line = max(1, width * fitted.width)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = max(line * 4.5, 10)
            let barb = CGFloat.pi / 7
            path.move(to: CGPoint(x: end.x - head * cos(angle - barb), y: end.y - head * sin(angle - barb)))
            path.addLine(to: end)
            path.addLine(to: CGPoint(x: end.x - head * cos(angle + barb), y: end.y - head * sin(angle + barb)))
            context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))

        case let .rectangle(rect, _, width):
            let target = CGRect(
                x: fitted.minX + rect.minX * fitted.width,
                y: fitted.minY + rect.minY * fitted.height,
                width: rect.width * fitted.width,
                height: rect.height * fitted.height
            )
            context.stroke(Path(target), with: .color(colour), lineWidth: max(1, width * fitted.width))

        case let .text(at, text, size, _):
            let fontSize = max(7, size * fitted.height)
            var resolved = context.resolve(
                Text(text).font(.system(size: fontSize, weight: .semibold)).foregroundColor(colour)
            )
            resolved.shading = .color(colour)
            context.draw(resolved, at: CGPoint(x: fitted.minX + at.x * fitted.width, y: fitted.minY + at.y * fitted.height), anchor: .topLeading)
        }
    }

    private func drawSelection(_ shape: AnnotationShape, context: inout GraphicsContext, fitted: CGRect) {
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: fitted.minX + p.x * fitted.width, y: fitted.minY + p.y * fitted.height)
        }
        let box: CGRect
        switch shape {
        case let .arrow(from, to, _, _):
            box = CGRect(
                x: min(point(from).x, point(to).x),
                y: min(point(from).y, point(to).y),
                width: abs(point(to).x - point(from).x),
                height: abs(point(to).y - point(from).y)
            )
        case let .rectangle(rect, _, _):
            box = CGRect(
                x: fitted.minX + rect.minX * fitted.width,
                y: fitted.minY + rect.minY * fitted.height,
                width: rect.width * fitted.width,
                height: rect.height * fitted.height
            )
        case let .text(at, text, size, _):
            let fontSize = max(7, size * fitted.height)
            box = CGRect(
                x: fitted.minX + at.x * fitted.width,
                y: fitted.minY + at.y * fitted.height,
                width: max(fontSize, CGFloat(text.count) * fontSize * 0.62),
                height: fontSize * 1.3
            )
        }
        let padded = box.insetBy(dx: -4, dy: -4)
        context.stroke(
            Path(padded),
            with: .color(Color.white.opacity(0.85)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
        )
    }

    private func drawDragPreview(context: inout GraphicsContext, fitted: CGRect) {
        guard moving == nil, let start = dragStart, let current = dragCurrent else { return }
        let colour = Color(nsColor: editor.color)
        let line = max(1, editor.lineWidth * fitted.width)
        switch editor.tool {
        case .pointer:
            break
        case .arrow:
            var path = Path()
            path.move(to: start)
            path.addLine(to: current)
            context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: line, lineCap: .round))
        case .rectangle:
            let rect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            context.stroke(Path(rect), with: .color(colour), lineWidth: line)
        case .crop:
            let rect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            context.stroke(Path(rect), with: .color(colour), lineWidth: 1.5)
            let outside = Path(fitted).subtracting(Path(rect))
            context.fill(outside, with: .color(Color.black.opacity(0.45)))
        case .text:
            break
        }
    }

    // MARK: - Gestures

    private func drag(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = value.startLocation
                    let startFraction = fraction(value.startLocation, in: rect)
                    if editor.tool == .pointer {
                        if let index = editor.hitTest(startFraction) {
                            editor.selected = index
                            moving = Moving(index: index, original: editor.shapes[index], start: startFraction)
                            editor.beginChange()
                        } else {
                            editor.selected = nil
                        }
                    }
                }
                dragCurrent = value.location

                if let moving {
                    let current = fraction(value.location, in: rect)
                    let delta = CGPoint(x: current.x - moving.start.x, y: current.y - moving.start.y)
                    editor.replace(moving.index, with: moving.original.offset(by: delta))
                }
            }
            .onEnded { value in
                defer {
                    dragStart = nil
                    dragCurrent = nil
                }
                if let moving {
                    self.moving = nil
                    let distance = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                    if distance > 1 { unsaved = true }
                    return
                }
                guard editor.tool != .pointer else { return }
                let start = fraction(value.startLocation, in: rect)
                let end = fraction(value.location, in: rect)
                switch editor.tool {
                case .pointer:
                    return
                case .arrow:
                    guard hypot(end.x - start.x, end.y - start.y) > 0.01 else { return }
                    editor.add(.arrow(from: start, to: end, color: editor.color, width: editor.lineWidth))
                    unsaved = true
                case .rectangle:
                    let box = CGRect(
                        x: min(start.x, end.x),
                        y: min(start.y, end.y),
                        width: abs(end.x - start.x),
                        height: abs(end.y - start.y)
                    )
                    guard box.width > 0.01, box.height > 0.01 else { return }
                    editor.add(.rectangle(rect: box, color: editor.color, width: editor.lineWidth))
                    unsaved = true
                case .text:
                    textEntry = TextEntry(point: start, value: "")
                    DispatchQueue.main.async { textFocused = true }
                case .crop:
                    let box = CGRect(
                        x: min(start.x, end.x),
                        y: min(start.y, end.y),
                        width: abs(end.x - start.x),
                        height: abs(end.y - start.y)
                    )
                    editor.crop(to: box)
                    unsaved = true
                    notify("Cropped · ⌘Z to undo")
                }
            }
    }

    private func commitText() {
        guard let entry = textEntry else { return }
        let text = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        textEntry = nil
        guard !text.isEmpty else { return }
        editor.add(.text(at: entry.point, text: text, size: editor.textSize, color: editor.color))
        unsaved = true
    }

    // MARK: - Actions

    private func notify(_ message: String) {
        Log.shared.info("Annotator: \(message)", source: "capture")
        withAnimation { toast = message }
        toastToken += 1
    }

    private func undo() {
        editor.undo()
    }

    private func copyImage() {
        editor.copy()
        notify("Copied to the clipboard")
        closeAfterToast()
    }

    private func closeAfterToast() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            close()
        }
    }

    @discardableResult
    private func save() -> Bool {
        do {
            let url = try editor.save()
            unsaved = false
            notify("Saved \(url.lastPathComponent)")
            closeAfterToast()
            return true
        } catch {
            Log.shared.error("Annotator: save failed: \(error.localizedDescription)", source: "capture")
            notify("Save failed: \(error.localizedDescription)")
            return false
        }
    }

    private func saveAs() {
        guard let source = editor.sourceURL else {
            notify("This image has no source to copy from")
            return
        }
        let panel = NSSavePanel()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        panel.nameFieldStringValue = "\(base)-annotated.\(ext)"
        panel.allowedContentTypes = ext.lowercased() == "jpg" || ext.lowercased() == "jpeg" ? [.jpeg] : [.png]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try editor.save(to: url)
            unsaved = false
            notify("Saved \(url.lastPathComponent)")
            closeAfterToast()
        } catch {
            notify("Save failed: \(error.localizedDescription)")
        }
    }

    private func finish() {
        if unsaved, !save() { return }
        close()
    }
}
