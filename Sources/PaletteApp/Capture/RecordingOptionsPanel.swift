import AppKit
import PaletteCore
import PalettePlatform
import SwiftUI

/// The state the options panel edits. A class so SwiftUI pickers mutate one
/// copy that the controller reads back on Record.
@MainActor
final class RecordingOptionsModel: ObservableObject {
    @Published var options: RecordingOptions
    let displays: [CaptureDisplay]
    let microphones: [(id: String, name: String)]
    let format: String

    init(
        options: RecordingOptions,
        displays: [CaptureDisplay],
        microphones: [(id: String, name: String)],
        format: String
    ) {
        self.options = options
        self.displays = displays
        self.microphones = microphones
        self.format = format.uppercased()
    }
}

/// Asked once per recording: audio, microphone, display and area. The panel is
/// ordered out before `screencapture` runs so it never lands in the file.
@MainActor
final class RecordingOptionsPanelController: NSWindowController, NSWindowDelegate {
    private let model: RecordingOptionsModel
    var onRecord: ((RecordingOptions) -> Void)?
    var onCancel: (() -> Void)?
    private var finished = false

    init(
        options: RecordingOptions,
        displays: [CaptureDisplay],
        microphones: [(id: String, name: String)],
        format: String,
        themeManager: ThemeManager,
        onRecord: @escaping (RecordingOptions) -> Void,
        onCancel: @escaping () -> Void
    ) {
        model = RecordingOptionsModel(
            options: options,
            displays: displays,
            microphones: microphones,
            format: format
        )
        self.onRecord = onRecord
        self.onCancel = onCancel
        let theme = themeManager.theme
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Recording Options"
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        // A capture HUD that stays up is captured; recording starts only after
        // this panel is ordered out, and switching apps hides it too.
        window.hidesOnDeactivate = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setAccessibilitySubrole(.dialog)
        window.appearance = theme.nsAppearance
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.backgroundColor = theme.nsColor(theme.palette.bg)
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: RecordingOptionsView(
            model: model,
            themeManager: themeManager,
            record: { [weak self] in self?.record() },
            cancel: { [weak self] in self?.cancel() }
        ))
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        WindowPresentation.present(window)
    }

    private func record() {
        guard !finished else { return }
        finished = true
        let choice = model.options
        onRecord?(choice)
    }

    /// Close without reporting Cancel: used when a new panel replaces this one.
    func discard() {
        finished = true
        window?.orderOut(nil)
        close()
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        window?.orderOut(nil)
        onCancel?()
    }

    /// The red button counts as Cancel, never as "record with the old values".
    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        onCancel?()
    }
}

private struct RecordingOptionsView: View {
    @ObservedObject var model: RecordingOptionsModel
    @ObservedObject var themeManager: ThemeManager
    var record: () -> Void
    var cancel: () -> Void

    private var theme: Theme { themeManager.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Video · \(model.format) · \(areaSummary)")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.color(theme.palette.fgMuted))
                }
                Spacer()
            }

            Divider()

            Toggle("Record audio", isOn: $model.options.audio)
                .toggleStyle(.switch)
                .controlSize(.small)

            HStack {
                Text("Microphone")
                Spacer()
                Picker("Microphone", selection: $model.options.microphone) {
                    Text("System default").tag("")
                    ForEach(model.microphones, id: \.id) { microphone in
                        Text(microphone.name).tag(microphone.id)
                    }
                    if !model.options.microphone.isEmpty,
                       !model.microphones.contains(where: { $0.id == model.options.microphone }) {
                        Text("\(model.options.microphone) (missing)").tag(model.options.microphone)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                .disabled(!model.options.audio)
            }

            HStack {
                Text("Area")
                Spacer()
                Picker("Area", selection: $model.options.target) {
                    Text("Full Screen").tag(RecordingOptions.Target.screen)
                    Text("Display").tag(RecordingOptions.Target.display)
                    Text("Selection").tag(RecordingOptions.Target.region)
                }
                .labelsHidden()
                .frame(width: 220)
            }

            if model.options.target == .display {
                HStack {
                    Text("Display")
                    Spacer()
                    Picker("Display", selection: $model.options.display) {
                        ForEach(model.displays, id: \.index) { display in
                            Text(display.label).tag(display.index)
                        }
                        if !model.displays.contains(where: { $0.index == model.options.display }) {
                            Text("Display \(model.options.display) (missing)")
                                .tag(model.options.display)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            if model.options.target == .region {
                HStack {
                    Text("Selection x,y,w,h")
                    Spacer()
                    TextField("x,y,w,h", text: $model.options.region)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Record", action: record)
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(PillButton(theme: theme))
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.color(theme.palette.fg))
        .padding(16)
        .frame(width: 420, height: 300, alignment: .topLeading)
        .background(theme.color(theme.palette.bg))
        .accessibilityIdentifier("recording-options")
    }

    private var areaSummary: String {
        switch model.options.target {
        case .screen:
            return "full screen"
        case .display:
            return "display \(model.options.display)"
        case .region:
            let region = model.options.region.trimmingCharacters(in: .whitespaces)
            return region.isEmpty ? "selection" : "selection \(region)"
        }
    }
}
