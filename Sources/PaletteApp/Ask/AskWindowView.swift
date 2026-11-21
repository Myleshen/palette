import AppKit
import PaletteCore
import PaletteProviders
import SwiftUI

/// Chat state: a transcript, the model for the next turn, and at most one
/// request in flight. History is sent to the service on each turn; only the
/// last question and answer are persisted by the service.
@MainActor
final class AskWindowState: ObservableObject {
    struct Turn: Identifiable, Equatable {
        enum Status: Equatable {
            case streaming
            case answered(AskRecord)
            case failed(String)
            case stopped
        }

        let id = UUID()
        var question: String
        var answer = ""
        var blocks: [AskMarkdownBlock] = []
        var status: Status = .streaming
    }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var selectedModel: AskModel
    @Published private(set) var streaming = false

    private let service: AskService
    private let notify: Bool
    private let isKey: () -> Bool
    private var task: Task<Void, Never>?
    private var started = false
    /// Deltas arrive much faster than a frame; this buffers them and republishes
    /// at most every 50 ms so a long answer cannot thrash layout.
    private var streamedText = ""
    private var streamedTurn: UUID?
    private var lastParse = Date.distantPast

    init(service: AskService, question: String, model: AskModel, notify: Bool, isKey: @escaping () -> Bool) {
        self.service = service
        self.selectedModel = model
        self.notify = notify
        self.isKey = isKey
        self.turns = [Turn(question: question)]
    }

    func start() {
        guard !started else { return }
        started = true
        guard let first = turns.first else { return }
        run(turnID: first.id)
    }

    /// Appends a user turn and sends the whole conversation.
    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !streaming else { return }
        let turn = Turn(question: question)
        turns.append(turn)
        run(turnID: turn.id)
    }

    /// Re-asks one turn after it failed or was stopped. Only the last turn can
    /// be retried, so later answers are never invalidated.
    func canRetry(_ turn: Turn) -> Bool {
        turns.last?.id == turn.id && turn.status != .streaming
    }

    func retry(_ turn: Turn) {
        guard canRetry(turn), let last = turns.last else { return }
        run(turnID: last.id)
    }

    func stop() {
        guard streaming else { return }
        task?.cancel()
        task = nil
        streaming = false
        if let index = turns.indices.last, turns[index].status == .streaming {
            flushStream(into: index)
            turns[index].status = .stopped
        }
    }

    /// Closing the window abandons the request without touching the transcript.
    func cancel() {
        task?.cancel()
        task = nil
        streaming = false
        streamedText = ""
        streamedTurn = nil
    }

    func newChat() {
        cancel()
        turns.removeAll()
    }

    /// A model picked here applies to subsequent turns only; changing it does
    /// not rewrite answers that already landed.
    func select(key: String) {
        guard let picked = AskModel.find(key: key), picked.key != selectedModel.key else { return }
        selectedModel = picked
        Task { try? await service.selectModel(picked) }
    }

    private func run(turnID: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        var messages: [AskMessage] = []
        for turn in turns[..<index] {
            messages.append(AskMessage(role: .user, content: turn.question))
            if case .answered(let record) = turn.status, !record.answer.isEmpty {
                messages.append(AskMessage(role: .assistant, content: record.answer))
            }
        }
        messages.append(AskMessage(role: .user, content: turns[index].question))

        streaming = true
        turns[index].answer = ""
        turns[index].blocks = []
        turns[index].status = .streaming
        streamedText = ""
        streamedTurn = turnID
        lastParse = .distantPast
        let chosen = selectedModel
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Persisting the choice keeps the panel's model picker honest.
                try? await service.selectModel(chosen)
                let record = try await service.ask(
                    messages,
                    onDelta: { [weak self] piece in
                        Task { @MainActor in self?.append(piece, to: turnID) }
                    },
                    onReset: { [weak self] in
                        Task { @MainActor in self?.resetAnswer(turnID) }
                    }
                )
                guard !Task.isCancelled,
                      let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
                streamedText = ""
                streamedTurn = nil
                turns[index].answer = record.answer
                turns[index].blocks = AskMarkdown.blocks(record.answer)
                turns[index].status = .answered(record)
                streaming = false
                if notify {
                    if !isKey() { NSSound(named: "Glass")?.play() }
                    if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
                }
            } catch {
                guard !Task.isCancelled,
                      let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
                flushStream(into: index)
                streamedText = ""
                streamedTurn = nil
                if error is CancellationError {
                    turns[index].status = .stopped
                } else {
                    turns[index].status = .failed(error.localizedDescription)
                }
                streaming = false
            }
        }
    }

    private func append(_ piece: String, to id: UUID) {
        guard id == streamedTurn,
              let index = turns.firstIndex(where: { $0.id == id }),
              turns[index].status == .streaming else { return }
        streamedText += piece
        let now = Date()
        guard now.timeIntervalSince(lastParse) >= 0.05 else { return }
        lastParse = now
        flushStream(into: index)
    }

    /// Publishes the buffered stream text and re-parses it. Called at most
    /// every 50 ms while streaming, and once when the turn ends.
    private func flushStream(into index: Int) {
        turns[index].answer = streamedText
        turns[index].blocks = AskMarkdown.blocks(streamedText)
    }

    private func resetAnswer(_ id: UUID) {
        guard id == streamedTurn,
              let index = turns.firstIndex(where: { $0.id == id }) else { return }
        streamedText = ""
        turns[index].answer = ""
        turns[index].blocks = []
    }
}

struct AskWindowView: View {
    @ObservedObject var state: AskWindowState
    @ObservedObject var themeManager: ThemeManager
    var close: () -> Void

    @State private var draft = ""
    @State private var copiedTurn: UUID?
    @State private var copiedAll = false
    @State private var pinned = true
    @State private var lastOffset: CGFloat = 0
    @State private var escapedAt = Date.distantPast
    @FocusState private var composerFocused: Bool

    private var theme: Theme { themeManager.theme }

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
            transcript
            Divider()
            composer
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(theme.color(theme.palette.bg))
        .onExitCommand { escape() }
        .task {
            // The window is made key just before the view appears; focusing a
            // beat later wins the race with AppKit's own first responder.
            try? await Task.sleep(for: .milliseconds(120))
            composerFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Ask")
                .font(theme.font(size: theme.typography.size, weight: .semibold))
                .foregroundStyle(theme.color(theme.palette.fg))
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
            .frame(minWidth: 200, maxWidth: 320)
            Spacer()
            Button(copiedAll ? "Copied" : "Copy all") { copyAll() }
                .disabled(!state.turns.contains { !$0.answer.isEmpty })
            Button("New chat") { newChat() }
                .keyboardShortcut("n", modifiers: .command)
        }
        .buttonStyle(PillButton(theme: theme))
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(state.turns) { turn in
                            row(turn).id(turn.id)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        GeometryReader { inner in
                            Color.clear.preference(
                                key: TranscriptMetricsKey.self,
                                value: TranscriptMetrics(
                                    offset: inner.frame(in: .named("askTranscript")).minY,
                                    height: inner.size.height
                                )
                            )
                        }
                    }
                }
                .coordinateSpace(name: "askTranscript")
                .onPreferenceChange(TranscriptMetricsKey.self) { metrics in
                    // Growing content leaves the scroll origin alone, so only a
                    // rising origin means the reader deliberately scrolled up.
                    let distance = metrics.offset + metrics.height - outer.size.height
                    if metrics.offset > lastOffset + 1 {
                        pinned = false
                    } else if distance <= 32 {
                        pinned = true
                    }
                    lastOffset = metrics.offset
                }
                .onChange(of: state.turns) { _, turns in
                    guard pinned, let last = turns.last else { return }
                    // scrollTo during onChange still sees the previous layout;
                    // hop once so it targets the new answer height.
                    DispatchQueue.main.async {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .overlay {
                    if state.turns.isEmpty {
                        Text("Ask anything. Enter sends, Shift+Enter adds a line.")
                            .font(theme.font(size: theme.typography.subtitleSize))
                            .foregroundStyle(theme.color(theme.palette.fgMuted))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func row(_ turn: AskWindowState.Turn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 60)
                Text(turn.question)
                    .font(theme.font(size: theme.typography.size))
                    .foregroundStyle(theme.color(theme.palette.fg))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme.color(theme.palette.accent).opacity(0.16))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(theme.color(theme.palette.accent).opacity(0.35), lineWidth: 0.5)
                    )
            }
            answer(turn)
        }
    }

    @ViewBuilder
    private func answer(_ turn: AskWindowState.Turn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !turn.answer.isEmpty {
                AskMarkdownView(blocks: turn.blocks, theme: theme)
            } else if turn.status == .streaming {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking \(state.selectedModel.name)…")
                        .font(theme.font(size: theme.typography.subtitleSize))
                        .foregroundStyle(theme.color(theme.palette.fgMuted))
                }
            }

            switch turn.status {
            case .streaming:
                if !turn.answer.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        // No model name here: a fallback may be the one talking.
                        Text("Streaming…")
                            .font(theme.font(size: metaSize))
                            .foregroundStyle(theme.color(theme.palette.fgMuted))
                    }
                }
            case .answered(let record):
                HStack(spacing: 8) {
                    Text(record.metaLine)
                        .font(theme.font(size: metaSize))
                        .foregroundStyle(theme.color(theme.palette.fgMuted))
                    Spacer()
                    copyButton(turn)
                }
            case .failed(let message):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message)
                        .font(theme.font(size: theme.typography.subtitleSize))
                        .foregroundStyle(theme.color(theme.palette.fg))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if state.canRetry(turn) {
                        Button("Retry") { state.retry(turn) }
                            .buttonStyle(PillButton(theme: theme))
                    }
                    copyButton(turn)
                }
            case .stopped:
                HStack(spacing: 8) {
                    Text("Stopped")
                        .font(theme.font(size: metaSize))
                        .foregroundStyle(theme.color(theme.palette.fgMuted))
                    Spacer()
                    if state.canRetry(turn) {
                        Button("Retry") { state.retry(turn) }
                            .buttonStyle(PillButton(theme: theme))
                    }
                    copyButton(turn)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.color(theme.palette.elevated).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.color(theme.palette.border).opacity(0.6), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func copyButton(_ turn: AskWindowState.Turn) -> some View {
        if !turn.answer.isEmpty {
            Button {
                copy(turn.answer, turn: turn.id)
            } label: {
                Image(systemName: copiedTurn == turn.id ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(theme.color(theme.palette.fgMuted))
            }
            .buttonStyle(.plain)
            .help("Copy this answer")
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                state.streaming ? "Waiting for the answer…" : "Message",
                text: $draft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(theme.font(size: theme.typography.size))
            .foregroundStyle(theme.color(theme.palette.fg))
            .lineLimit(1...6)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.color(theme.palette.elevated).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.color(theme.palette.border), lineWidth: 0.5)
            )
            .focused($composerFocused)
            .onKeyPress(keys: [.return]) { press in
                if press.modifiers.contains(.shift) { return .ignored }
                send()
                return .handled
            }
            .onKeyPress(keys: [.escape]) { _ in
                escape()
                return .handled
            }

            if state.streaming {
                Button("Stop") { state.stop() }
                    .buttonStyle(PillButton(theme: theme))
            } else {
                Button("Send") { send() }
                    .buttonStyle(PillButton(theme: theme))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            GlassSurface(shape: Rectangle(), tint: theme.color(theme.palette.elevated).opacity(0.55))
        }
    }

    private var metaSize: Double {
        max(9, theme.typography.size - 3)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !state.streaming else { return }
        draft = ""
        // A new question is the reader's focus, even if they had scrolled up.
        pinned = true
        state.send(text)
        composerFocused = true
    }

    /// Esc stops a running answer; with nothing in flight it closes the window.
    private func escape() {
        // The focused field and the window's cancel action can both deliver
        // Esc; without this, one press would stop and then close.
        let now = Date()
        guard now.timeIntervalSince(escapedAt) > 0.15 else { return }
        escapedAt = now
        if state.streaming {
            state.stop()
        } else {
            close()
        }
    }

    private func newChat() {
        state.newChat()
        draft = ""
        copiedTurn = nil
        composerFocused = true
    }

    private func copy(_ text: String, turn: UUID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedTurn = turn
        Task {
            try? await Task.sleep(for: .milliseconds(1_200))
            if copiedTurn == turn { copiedTurn = nil }
        }
    }

    private func copyAll() {
        let transcript = state.turns.map { turn -> String in
            var text = "You: \(turn.question)"
            if !turn.answer.isEmpty { text += "\n\n\(turn.answer)" }
            return text
        }.joined(separator: "\n\n")
        guard !transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
        copiedAll = true
        Task {
            try? await Task.sleep(for: .milliseconds(1_200))
            copiedAll = false
        }
    }
}

private struct TranscriptMetrics: Equatable {
    var offset: CGFloat = 0
    var height: CGFloat = 0
}

private struct TranscriptMetricsKey: PreferenceKey {
    static let defaultValue = TranscriptMetrics()

    static func reduce(value: inout TranscriptMetrics, nextValue: () -> TranscriptMetrics) {
        value = nextValue()
    }
}
