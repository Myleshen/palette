import AppKit
import SwiftUI

/// Annotate window: a screenshot, a small tool strip, and Save/Copy.
@MainActor
final class AnnotateWindowController: NSWindowController, NSWindowDelegate {
    private let editor: AnnotationEditor
    private var onClose: (() -> Void)?

    init(image: NSImage, url: URL?, onClose: (() -> Void)? = nil) {
        editor = AnnotationEditor(image: image, url: url)
        self.onClose = onClose

        let size = image.size
        let maxSize = NSSize(width: 1180, height: 760)
        let scale = min(1, min(maxSize.width / max(1, size.width), maxSize.height / max(1, size.height)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale + 52),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = url?.lastPathComponent ?? "Annotate"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: AnnotateView(editor: editor, close: { [weak self] in self?.close() }))
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
    @State private var status: String?

    private let palette: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white, .black]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                let fitted = fittedRect(in: geo.size)
                ZStack {
                    Color(nsColor: .windowBackgroundColor).opacity(0.6)
                    Image(nsImage: editor.image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                    Canvas { context, _ in
                        drawShapes(context: &context, fitted: fitted)
                        drawDragPreview(context: &context, fitted: fitted)
                    }
                    .contentShape(Rectangle())
                    .gesture(drag(fitted: fitted))
                }
                .overlay(alignment: .bottomLeading) {
                    if let status {
                        Text(status)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.thinMaterial, in: Capsule())
                            .padding(10)
                    }
                }
                .onAppear { setWindowSize(fitted: fitted) }
            }
        }
    }

    // MARK: - Chrome

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
            Slider(value: $editor.lineWidth, in: 0.001...0.02)
                .frame(width: 80)
                .accessibilityLabel("Line width")
            Text(editor.sourceURL?.lastPathComponent ?? "Annotate")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Undo") { undo() }
                .disabled(!editor.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button("Copy") { copyImage() }
                .keyboardShortcut("c", modifiers: .command)
            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Done") { close() }
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
        } label: {
            Label(tool.title, systemImage: tool.symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(editor.tool == tool ? Color.accentColor.opacity(0.25) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(tool.title)
        .accessibilityLabel(tool.title)
    }

    // MARK: - Layout

    private func fittedRect(in size: CGSize) -> CGRect {
        let image = editor.image.size
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(size.width / image.width, size.height / image.height)
        let width = image.width * scale
        let height = image.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func setWindowSize(fitted: CGRect) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.title != "Palette" }) else { return }
        let desired = NSSize(width: max(520, fitted.width), height: max(360, fitted.height + 96))
        guard abs(window.frame.width - desired.width) > 1 || abs(window.frame.height - desired.height) > 40 else { return }
        window.setContentSize(desired)
        window.center()
    }

    private func fraction(_ point: CGPoint, in fitted: CGRect) -> CGPoint {
        guard fitted.width > 0, fitted.height > 0 else { return .zero }
        return CGPoint(
            x: min(1, max(0, (point.x - fitted.minX) / fitted.width)),
            y: min(1, max(0, (point.y - fitted.minY) / fitted.height))
        )
    }

    // MARK: - Drawing

    private func drawShapes(context: inout GraphicsContext, fitted: CGRect) {
        for shape in editor.shapes {
            draw(shape, context: &context, fitted: fitted)
        }
    }

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
            context.stroke(
                Path(target),
                with: .color(colour),
                lineWidth: max(1, width * fitted.width)
            )

        case let .text(at, text, size, _):
            let fontSize = max(7, size * fitted.height)
            var resolved = context.resolve(
                Text(text).font(.system(size: fontSize, weight: .semibold)).foregroundColor(colour)
            )
            resolved.shading = .color(colour)
            context.draw(resolved, at: CGPoint(x: fitted.minX + at.x * fitted.width, y: fitted.minY + at.y * fitted.height), anchor: .topLeading)
        }
    }

    private func drawDragPreview(context: inout GraphicsContext, fitted: CGRect) {
        guard let start = dragStart, let current = dragCurrent else { return }
        let colour = Color(nsColor: editor.color)
        let line = max(1, editor.lineWidth * fitted.width)
        switch editor.tool {
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

    private func drag(fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragStart = value.startLocation
                dragCurrent = value.location
            }
            .onEnded { value in
                defer {
                    dragStart = nil
                    dragCurrent = nil
                }
                let start = fraction(value.startLocation, in: fitted)
                let end = fraction(value.location, in: fitted)
                switch editor.tool {
                case .arrow:
                    guard hypot(end.x - start.x, end.y - start.y) > 0.01 else { return }
                    editor.add(.arrow(from: start, to: end, color: editor.color, width: editor.lineWidth))
                case .rectangle:
                    let rect = CGRect(
                        x: min(start.x, end.x),
                        y: min(start.y, end.y),
                        width: abs(end.x - start.x),
                        height: abs(end.y - start.y)
                    )
                    guard rect.width > 0.01, rect.height > 0.01 else { return }
                    editor.add(.rectangle(rect: rect, color: editor.color, width: editor.lineWidth))
                case .text:
                    addText(at: start)
                case .crop:
                    let rect = CGRect(
                        x: min(start.x, end.x),
                        y: min(start.y, end.y),
                        width: abs(end.x - start.x),
                        height: abs(end.y - start.y)
                    )
                    editor.crop(to: rect)
                    status = "Cropped · ⌘Z to undo"
                }
            }
    }

    // MARK: - Actions

    private func addText(at point: CGPoint) {
        let alert = NSAlert()
        alert.messageText = "Add text"
        alert.informativeText = "The text is drawn where you clicked."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Text"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        editor.add(.text(at: point, text: text, size: 0.05, color: editor.color))
    }

    private func undo() {
        editor.undo()
        status = nil
    }

    private func copyImage() {
        editor.copy()
        status = "Copied to the clipboard"
    }

    private func save() {
        do {
            let url = try editor.save()
            status = "Saved \(url.lastPathComponent)"
        } catch {
            status = error.localizedDescription
        }
    }
}
