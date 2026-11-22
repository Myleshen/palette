import AppKit
import PaletteCore
import PalettePlatform
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
        /// A restored turn already exists in `ask_chat_messages`, so Retry must
        /// not append the question a second time.
        var userSaved = false
        /// Search is a per-turn choice captured when the turn is sent.
        var webSearch = false
        /// Transient status while searching/reading, then nil.
        var progress: String?
        /// Kept after a degraded search so the answer explains the gap.
        var searchNote: String?
    }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var selectedModel: AskModel
    @Published private(set) var streaming = false
    @Published private(set) var chats: [AskChat] = []
    /// Nil until the first send creates the row, or a saved chat is opened.
    @Published private(set) var chatID: String?
    @Published private(set) var loadingChat = false
    @Published var webSearch: Bool

    private let service: AskService
    private let notify: Bool
    private let isKey: () -> Bool
    var onStatusChange: () -> Void
    private var task: Task<Void, Never>?
    private var started = false
    /// Deltas arrive much faster than a frame; this buffers them and republishes
    /// at most every 50 ms so a long answer cannot thrash layout.
    private var streamedText = ""
    private var streamedTurn: UUID?
    private var lastParse = Date.distantPast

    init(
        service: AskService,
        question: String,
        model: AskModel,
        notify: Bool,
        webSearch: Bool = false,
        isKey: @escaping () -> Bool,
        onStatusChange: @escaping () -> Void = {}
    ) {
        self.service = service
        self.selectedModel = model
        self.notify = notify
        self.webSearch = webSearch
        self.isKey = isKey
        self.onStatusChange = onStatusChange
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var first = Turn(question: trimmed)
        first.webSearch = webSearch
        self.turns = trimmed.isEmpty ? [] : [first]
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await refreshChats() }
        guard let first = turns.first else { return }
        run(turnID: first.id)
    }

    /// Appends a user turn and sends the whole conversation.
    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !streaming else { return }
        var turn = Turn(question: question)
        turn.webSearch = webSearch
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
        onStatusChange()
    }

    /// Closing the window abandons the request without touching the transcript.
    func cancel() {
        task?.cancel()
        task = nil
        streaming = false
        streamedText = ""
        streamedTurn = nil
        onStatusChange()
    }

    func newChat() {
        cancel()
        turns.removeAll()
        chatID = nil
    }

    /// A model picked here applies to subsequent turns only; changing it does
    /// not rewrite answers that already landed.
    func select(key: String) {
        guard let picked = AskModel.find(key: key), picked.key != selectedModel.key else { return }
        selectedModel = picked
        let chatID = chatID
        Task {
            try? await service.selectModel(picked)
            if let chatID {
                try? await service.updateChatModel(chatID: chatID, model: picked)
                await refreshChats()
            }
        }
    }

    // MARK: - Saved chats

    func openChat(_ chat: AskChat) {
        cancel()
        chatID = chat.id
        if let stored = AskModel.find(id: chat.model) {
            selectedModel = stored
        }
        loadingChat = true
        Task {
            let messages = (try? await service.messages(chatID: chat.id)) ?? []
            var restored: [Turn] = []
            var current: Turn?
            for message in messages {
                switch message.role {
                case .user:
                    if let unanswered = current {
                        var pending = unanswered
                        pending.status = .failed("No answer was saved for this turn.")
                        restored.append(pending)
                    }
                    var turn = Turn(question: message.content)
                    turn.userSaved = true
                    current = turn
                case .assistant:
                    guard var turn = current else { continue }
                    let record = AskRecord(
                        id: message.id,
                        question: turn.question,
                        answer: message.content,
                        model: chat.model,
                        provider: AskModel.find(id: chat.model)?.endpoint.rawValue ?? "",
                        createdAt: message.createdAt,
                        durationMs: message.durationMs,
                        promptTokens: message.promptTokens,
                        completionTokens: message.completionTokens,
                        sources: message.sources
                    )
                    turn.answer = message.content
                    turn.blocks = AskMarkdown.blocks(message.content)
                    turn.status = .answered(record)
                    restored.append(turn)
                    current = nil
                case .system:
                    continue
                }
            }
            if var pending = current {
                pending.status = .failed("No answer was saved for this turn.")
                restored.append(pending)
            }
            turns = restored
            loadingChat = false
        }
    }

    func deleteChat(_ chat: AskChat) {
        Task {
            try? await service.deleteChat(id: chat.id)
            if chatID == chat.id {
                cancel()
                chatID = nil
                turns.removeAll()
            }
            await refreshChats()
        }
    }

    private func refreshChats() async {
        chats = (try? await service.chats(limit: 200)) ?? chats
    }

    /// Creates the row on the first send. Returns nil when persistence fails;
    /// the chat itself still works in memory.
    private func ensureChat(question: String, model: AskModel) async -> String? {
        if let chatID {
            try? await service.updateChatModel(chatID: chatID, model: model)
            return chatID
        }
        do {
            let chat = try await service.createChat(title: AskChat.title(from: question), model: model)
            chatID = chat.id
            await refreshChats()
            return chat.id
        } catch {
            Log.shared.warn("ask chat create failed: \(error.localizedDescription)", source: "ask")
            return nil
        }
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
        onStatusChange()
        turns[index].answer = ""
        turns[index].blocks = []
        turns[index].status = .streaming
        streamedText = ""
        streamedTurn = turnID
        lastParse = .distantPast
        let chosen = selectedModel
        let question = turns[index].question
        let wantsSearch = turns[index].webSearch
        task = Task { [weak self] in
            guard let self else { return }
            let savedChatID = await ensureChat(question: question, model: chosen)
            do {
                guard !Task.isCancelled else { return }
                // Persisting the choice keeps the panel's model picker honest.
                try? await service.selectModel(chosen)
                if let savedChatID,
                   let current = turns.firstIndex(where: { $0.id == turnID }),
                   !turns[current].userSaved {
                    _ = try? await service.appendMessage(
                        chatID: savedChatID,
                        role: .user,
                        content: question
                    )
                    if let updated = turns.firstIndex(where: { $0.id == turnID }) {
                        turns[updated].userSaved = true
                    }
                    await refreshChats()
                }
                let record = try await service.ask(
                    messages,
                    webSearch: wantsSearch,
                    onProgress: { [weak self] text in
                        Task { @MainActor in self?.setProgress(text, for: turnID) }
                    },
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
                turns[index].progress = nil
                streaming = false
                let unseen = !isKey()
                if unseen {
                    NSApp.dockTile.badgeLabel = "1"
                    Log.shared.info("Ask answer ready unseen; badge set", source: "ask")
                }
                onStatusChange()
                // Persist the completed answer once, not per delta.
                if let savedChatID {
                    _ = try? await service.appendMessage(
                        chatID: savedChatID,
                        role: .assistant,
                        content: record.answer,
                        durationMs: record.durationMs,
                        promptTokens: record.promptTokens,
                        completionTokens: record.completionTokens,
                        sources: record.sources
                    )
                    await refreshChats()
                }
                if notify, unseen {
                    Log.shared.info("Ask completion notification: sound + Dock bounce", source: "ask")
                    NSSound(named: "Glass")?.play()
                    if !NSApp.isActive {
                        NSApp.requestUserAttention(.informationalRequest)
                        SystemNotification.post(
                            title: "Answer ready",
                            body: turns[index].question
                        )
                    }
                }
            } catch {
                guard !Task.isCancelled,
                      let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
                flushStream(into: index)
                streamedText = ""
                streamedTurn = nil
                turns[index].progress = nil
                if error is CancellationError {
                    turns[index].status = .stopped
                } else {
                    turns[index].status = .failed(error.localizedDescription)
                }
                streaming = false
                onStatusChange()
            }
        }
    }

    private func append(_ piece: String, to id: UUID) {
        guard id == streamedTurn,
              let index = turns.firstIndex(where: { $0.id == id }),
              turns[index].status == .streaming else { return }
        streamedText += piece
        turns[index].progress = nil
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

    private func setProgress(_ text: String, for id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }),
              turns[index].status == .streaming else { return }
        if text == "Search unavailable" {
            turns[index].searchNote = text
            turns[index].progress = nil
        } else {
            turns[index].progress = text
        }
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
    var openSettings: () -> Void
    var close: () -> Void

    @State private var draft = ""
    @State private var copiedTurn: UUID?
    @State private var copiedAll = false
    @State private var pinned = true
    @State private var lastOffset: CGFloat = 0
    @State private var escapedAt = Date.distantPast
    @State private var showSidebar = true
    @State private var chatSearch = ""
    @State private var hoveredChat: String?
    @State private var deletingChat: AskChat?
    @FocusState private var composerFocused: Bool

    private var theme: Theme { themeManager.theme }

    private var filteredChats: [AskChat] {
        let query = chatSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return state.chats }
        return state.chats.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.model.localizedCaseInsensitiveContains(query)
        }
    }

    /// A config can name a model that has since left the catalog; showing it
    /// beats an empty picker.
    private var modelChoices: [AskModel] {
        var choices = AskModel.catalog
        if !choices.contains(where: { $0.key == state.selectedModel.key }) {
            choices.append(state.selectedModel)
        }
        return choices
    }

    private func modelChoices(for endpoint: AskEndpoint) -> [AskModel] {
        modelChoices.filter { $0.endpoint == endpoint }
    }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                sidebar
                Divider()
            }
            VStack(spacing: 0) {
                header
                Divider()
                transcript
                Divider()
                composer
            }
        }
        .frame(minWidth: 700, minHeight: 460)
        .background(theme.color(theme.palette.bg))
        .onExitCommand { escape() }
        .task {
            // The window is made key just before the view appears; focusing a
            // beat later wins the race with AppKit's own first responder.
            try? await Task.sleep(for: .milliseconds(120))
            composerFocused = true
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(
                get: { deletingChat != nil },
                set: { if !$0 { deletingChat = nil } }
            ),
            presenting: deletingChat
        ) { chat in
            Button("Delete", role: .destructive) {
                state.deleteChat(chat)
                deletingChat = nil
            }
            Button("Cancel", role: .cancel) { deletingChat = nil }
        } message: { chat in
            Text(chat.title)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Chats")
                    .font(theme.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.color(theme.palette.fg))
                Spacer()
                Button {
                    newChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(theme.color(theme.palette.fgMuted))
                }
                .buttonStyle(.plain)
                .help("New chat (⌘N)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            if state.chats.count > 5 {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.color(theme.palette.fgMuted))
                    TextField("Search chats", text: $chatSearch)
                        .textFieldStyle(.plain)
                        .font(theme.font(size: 11))
                        .foregroundStyle(theme.color(theme.palette.fg))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.color(theme.palette.elevated).opacity(0.55))
                )
                .padding(.horizontal, 10)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredChats) { chat in
                        chatRow(chat)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }

            if state.chats.isEmpty {
                Text("No saved chats yet")
                    .font(theme.font(size: 10))
                    .foregroundStyle(theme.color(theme.palette.fgMuted))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else if filteredChats.isEmpty {
                Text("No matches")
                    .font(theme.font(size: 10))
                    .foregroundStyle(theme.color(theme.palette.fgMuted))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.color(theme.palette.bg))
    }

    private func chatRow(_ chat: AskChat) -> some View {
        let selected = state.chatID == chat.id
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title.isEmpty ? "Untitled" : chat.title)
                    .font(theme.font(size: 11, weight: selected ? .medium : .regular))
                    .foregroundStyle(theme.color(theme.palette.fg))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(modelName(chat.model))
                        .lineLimit(1)
                    Text("·")
                    Text(relative(chat.updatedAt))
                }
                .font(theme.font(size: max(8, theme.typography.size - 4)))
                .foregroundStyle(theme.color(theme.palette.fgMuted))
            }
            Spacer(minLength: 0)
            if hoveredChat == chat.id {
                Button {
                    deletingChat = chat
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(theme.color(theme.palette.fgMuted))
                }
                .buttonStyle(.plain)
                .help("Delete chat")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? theme.color(theme.palette.accent).opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { state.openChat(chat) }
        .onHover { inside in
            if inside {
                hoveredChat = chat.id
            } else if hoveredChat == chat.id {
                hoveredChat = nil
            }
        }
        .contextMenu {
            Button("Delete", role: .destructive) { deletingChat = chat }
        }
    }

    private func modelName(_ id: String) -> String {
        AskModel.find(id: id)?.name ?? id
    }

    private func relative(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
                    .foregroundStyle(theme.color(theme.palette.fgMuted))
            }
            .buttonStyle(.plain)
            .help(showSidebar ? "Hide saved chats" : "Show saved chats")
            Text("Ask")
                .font(theme.font(size: theme.typography.size, weight: .semibold))
                .foregroundStyle(theme.color(theme.palette.fg))
            Picker("Model", selection: Binding(
                get: { state.selectedModel.key },
                set: { state.select(key: $0) }
            )) {
                ForEach([AskEndpoint.opencodeGo, .nvidia], id: \.self) { endpoint in
                    if !modelChoices(for: endpoint).isEmpty {
                        Section(endpoint.displayName) {
                            ForEach(modelChoices(for: endpoint)) { model in
                                Text(model.free ? "\(model.name) · Free" : model.name)
                                    .tag(model.key)
                            }
                        }
                    }
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(minWidth: 180, maxWidth: 300)
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
                        Color.clear
                            .frame(height: 1)
                            .id("transcript-bottom")
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
                    guard pinned, !turns.isEmpty else { return }
                    // scrollTo during onChange still sees the previous layout;
                    // the bottom marker sits after the last row (sources, meta)
                    // so two hops always land on the true end.
                    DispatchQueue.main.async {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                        DispatchQueue.main.async {
                            proxy.scrollTo("transcript-bottom", anchor: .bottom)
                        }
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
                    Text(turn.progress ?? "Asking \(state.selectedModel.name)…")
                        .font(theme.font(size: theme.typography.subtitleSize))
                        .foregroundStyle(theme.color(theme.palette.fgMuted))
                }
            }

            if let note = turn.searchNote {
                HStack(spacing: 5) {
                    Image(systemName: "wifi.exclamationmark")
                    Text(note)
                }
                .font(theme.font(size: max(9, theme.typography.size - 3)))
                .foregroundStyle(theme.color(theme.palette.fgMuted))
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
                if !record.sources.isEmpty {
                    sourcesView(record.sources)
                }
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
                    if message.localizedCaseInsensitiveContains("API key") {
                        Button("Open Ask Settings") {
                            openSettings()
                            close()
                        }
                        .buttonStyle(PillButton(theme: theme))
                    }
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

    private func sourcesView(_ sources: [AskSource]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Sources")
                .font(theme.font(size: max(9, theme.typography.size - 4), weight: .semibold))
                .foregroundStyle(theme.color(theme.palette.fgMuted))
            ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                Button {
                    NSWorkspace.shared.open(source.url)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("[\(index + 1)]")
                            .foregroundStyle(theme.color(theme.palette.accent))
                        Text(source.title)
                            .foregroundStyle(theme.color(theme.palette.fg))
                            .lineLimit(1)
                        if let host = source.url.host {
                            Text(host)
                                .foregroundStyle(theme.color(theme.palette.fgMuted))
                                .lineLimit(1)
                        }
                    }
                    .font(theme.font(size: max(9, theme.typography.size - 3)))
                }
                .buttonStyle(.plain)
                .help(source.url.absoluteString)
            }
        }
        .padding(.vertical, 2)
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
            Button {
                state.webSearch.toggle()
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 13))
                    .foregroundStyle(
                        state.webSearch
                            ? theme.color(theme.palette.bg)
                            : theme.color(theme.palette.fgMuted)
                    )
                    .frame(width: 28, height: 28)
                    .background(
                        Capsule().fill(
                            state.webSearch
                                ? theme.color(theme.palette.accent)
                                : theme.color(theme.palette.elevated).opacity(0.6)
                        )
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .help("Search the web for the next turn (⇧⌘G)")
            .accessibilityLabel("Web search")

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
            ZStack {
                theme.color(theme.palette.bg)
                GlassSurface(shape: Rectangle(), tint: theme.color(theme.palette.elevated).opacity(0.55))
            }
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
