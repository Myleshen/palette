import AppKit
import PaletteCore
import PaletteProviders
import SwiftUI

/// One-shot ask state: a question, the model to use, and where the single
/// request is. "Ask Again" repeats the same question; nothing is threaded.
@MainActor
final class AskWindowState: ObservableObject {
    enum Phase: Equatable {
        case asking
        case answered(AskRecord)
        case failed(String)
        case cancelled
    }

    let question: String
    @Published private(set) var selectedModel: AskModel
    @Published private(set) var phase: Phase = .asking

    private let service: AskService
    private let notify: Bool
    private let isKey: () -> Bool
    private var task: Task<Void, Never>?
    private var started = false

    init(service: AskService, question: String, model: AskModel, notify: Bool, isKey: @escaping () -> Bool) {
        self.service = service
        self.question = question
        self.selectedModel = model
        self.notify = notify
        self.isKey = isKey
    }

    func start() {
        guard !started else { return }
        started = true
        run()
    }

    func askAgain() {
        run()
    }

    func cancel() {
        guard phase == .asking else { return }
        task?.cancel()
        task = nil
        phase = .cancelled
    }

    /// Picking a model re-asks: with no conversation, the only way to see what
    /// another model says about the same question.
    func select(key: String) {
        guard let picked = AskModel.find(key: key), picked.key != selectedModel.key else { return }
        selectedModel = picked
        run()
    }

    private func run() {
        task?.cancel()
        phase = .asking
        let question = question
        let chosen = selectedModel
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Persisting the choice keeps the panel's model picker honest.
                try? await service.selectModel(chosen)
                let record = try await service.ask(question)
                guard !Task.isCancelled else { return }
                phase = .answered(record)
                if notify {
                    if !isKey() { NSSound(named: "Glass")?.play() }
                    if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
                }
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

struct AskWindowView: View {
    @ObservedObject var state: AskWindowState
    @ObservedObject var themeManager: ThemeManager
    var close: () -> Void

    @State private var copied = false

    private var theme: Theme { themeManager.theme }

    private var answeredRecord: AskRecord? {
        if case .answered(let record) = state.phase { return record }
        return nil
    }

    /// A config can name a model that has since left the catalog; showing it
    /// beats an empty picker.
    private var modelChoices: [AskModel] {
        var choices = AskModel.fallbackOrder
        if !choices.contains(where: { $0.key == state.selectedModel.key }) {
            choices.insert(state.selectedModel, at: 0)
        }
        return choices
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(theme.color(theme.palette.bg))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.question)
                .font(theme.font(size: theme.typography.size, weight: .medium))
                .foregroundStyle(theme.color(theme.palette.fg))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Text("Model")
                    .font(theme.font(size: theme.typography.subtitleSize))
                    .foregroundStyle(theme.color(theme.palette.fgMuted))
                Picker("Model", selection: Binding(
                    get: { state.selectedModel.key },
                    set: { state.select(key: $0) }
                )) {
                    ForEach(modelChoices) { model in
                        Text(model.free ? "\(model.name) · Free" : model.name)
                            .tag(model.key)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(minWidth: 250, maxWidth: 360)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .asking:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Asking \(state.selectedModel.name)…")
                    .font(theme.font(size: theme.typography.subtitleSize))
                    .foregroundStyle(theme.color(theme.palette.fgMuted))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .answered(let record):
            VStack(spacing: 0) {
                PreviewTextView(
                    text: record.answer,
                    theme: theme,
                    font: theme.nsFont(size: theme.typography.size),
                    lineSpacing: 3
                )
                .padding(.horizontal, 10)
                .padding(.top, 6)
                Text(record.metaLine)
                    .font(theme.font(size: max(9, theme.typography.size - 3)))
                    .foregroundStyle(theme.color(theme.palette.fgMuted))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
        case .cancelled:
            Text("Request cancelled.")
                .font(theme.font(size: theme.typography.subtitleSize))
                .foregroundStyle(theme.color(theme.palette.fgMuted))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.color(theme.palette.accent))
                Text(message)
                    .font(theme.font(size: theme.typography.subtitleSize))
                    .foregroundStyle(theme.color(theme.palette.fg))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Retry") { state.askAgain() }
                    .buttonStyle(PillButton(theme: theme))
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            if state.phase == .asking {
                Button("Cancel") { state.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(copied ? "Copied" : "Copy") {
                    guard let record = answeredRecord else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.answer, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(1_200))
                        copied = false
                    }
                }
                .disabled(answeredRecord == nil)
                Button("Ask Again") { state.askAgain() }
                Button("Done") { close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .buttonStyle(PillButton(theme: theme))
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background {
            ZStack {
                theme.color(theme.palette.bg)
                GlassSurface(shape: Rectangle(), tint: theme.color(theme.palette.elevated).opacity(0.55))
            }
        }
    }
}

