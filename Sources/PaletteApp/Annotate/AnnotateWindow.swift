import AppKit
import PalettePlatform
import SwiftUI

/// Back to a menu-bar app once no editor or player window is left.
@MainActor
func restoreAccessoryPolicyIfIdle() {
    let editing = NSApp.windows.contains { $0.isVisible && $0.canBecomeKey && $0.title != "" && $0.className != "NSStatusBarWindow" }
    if !editing, NSApp.activationPolicy() == .regular {
        NSApp.setActivationPolicy(.accessory)
    }
}

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
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale + 44),
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
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(white: 0.10, alpha: 1)
        window.isOpaque = true
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
        restoreAccessoryPolicyIfIdle()
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
    @State private var toast: String?
    @State private var toastToken = 0
    @State private var unsaved = false

    private let palette: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white, .black]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                let fitted = fittedRect(in: geo.size)
                ZStack {
                    Color(white: 0.10)
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
                .overlay(alignment: .top) {
                    if let toast {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text(toast)
                                .lineLimit(2)
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
                .task(id: toastToken) {
                    guard toast != nil else { return }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    withAnimation { toast = nil }
                }
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
                    unsaved = true
                case .rectangle:
                    let rect = CGRect(
                        x: min(start.x, end.x),
                        y: min(start.y, end.y),
                        width: abs(end.x - start.x),
                        height: abs(end.y - start.y)
                    )
                    guard rect.width > 0.01, rect.height > 0.01 else { return }
                    editor.add(.rectangle(rect: rect, color: editor.color, width: editor.lineWidth))
                    unsaved = true
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
                    unsaved = true
                    notify("Cropped · ⌘Z to undo")
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
        unsaved = true
    }

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

    /// The toast is the confirmation, then the window gets out of the way.
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

    private func finish() {
        // Done must not throw work away: save first when anything was drawn.
        if unsaved, !save() { return }
        close()
    }
}
