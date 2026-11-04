import Foundation
import PaletteCore
import PalettePlatform

/// `/ask` is a one-shot question box. Empty query selects a model; a typed
/// question shows a single Ask row, and the answer is stored in Ask History.
/// No conversation is ever threaded.
public final class AskProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "ask",
        name: "Ask",
        trigger: "ask",
        isGlobal: false,
        priority: 75,
        icon: "symbol:sparkles"
    )

    private let service: AskService
    private let bridge: HostBridge

    public init(service: AskService, bridge: HostBridge) {
        self.service = service
        self.bridge = bridge
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let question = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty {
            return await modelRows()
        }

        if let answer = await service.recentAnswer(for: question) {
            return [answerRow(answer)]
        }

        let model = await service.selectedModel()
        let hasAnyKey = await service.hasAnyKey()
        if !hasAnyKey {
            return [setupRow(question: question)]
        }
        return [requestRow(question: question, model: model)]
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        switch action.id {
        case "select-model":
            guard let key = action.value.text,
                  let model = AskModel.find(key: key) else { return }
            try await service.selectModel(model)
            await bridge.notify("Ask model: \(model.name)")
        case "ask":
            guard let question = action.value.text else { return }
            let model = await service.selectedModel()
            await bridge.notify("Asking \(model.name)…")
            let record = try await service.ask(question)
            await bridge.notify("Answered with \(record.model)")
        case "ask-settings":
            await bridge.notify("Add a key in Settings → Ask")
        case "ask-history":
            break
        default:
            break
        }
    }

    private func modelRows() async -> [PaletteItem] {
        let selected = await service.selectedModel()
        let hasKey = await service.hasKey(for: selected.endpoint)
        var models = AskModel.models(for: selected.endpoint)
        if let index = models.firstIndex(where: { $0.key == selected.key }) {
            models.remove(at: index)
        }
        models.insert(selected, at: 0)

        var rows: [PaletteItem] = []
        if !hasKey {
            rows.append(setupRow(question: nil))
        }
        rows.append(contentsOf: models.enumerated().map { index, model in
            let isSelected = model.key == selected.key
            let badge: String
            if isSelected {
                badge = "SELECTED"
            } else if model.free {
                badge = "FREE"
            } else {
                badge = "PAID"
            }
            var details = [
                "\(model.endpoint.displayName) · \(model.id)",
                model.free ? "Free model" : model.costLabel,
                hasKey ? "Key saved for this endpoint" : "No key for this endpoint",
                "Enter selects this model. Then type /ask followed by your question.",
            ]
            if !model.note.isEmpty { details.insert(model.note, at: 1) }
            return PaletteItem(
                id: "model:\(model.key)",
                title: "\(model.free ? "FREE · " : "")\(model.name)",
                subtitle: "\(model.endpoint.displayName) · \(model.id) · \(model.costLabel)",
                icon: .symbol(model.free ? "gift" : "bolt"),
                badge: badge,
                group: isSelected ? "Current model" : (model.free ? "Free models" : "Paid models · cheapest first"),
                score: 10_000 - Double(index),
                actions: [
                    PaletteAction(id: "select-model", title: "Use \(model.name)", kind: .custom, value: .text(model.key)),
                ],
                preview: .text(details.joined(separator: "\n\n")),
                providerID: descriptor.id,
                providerName: descriptor.name
            )
        })
        return rows
    }

    private func requestRow(question: String, model: AskModel) -> PaletteItem {
        PaletteItem(
            id: "question:\(question)",
            title: "Ask \(model.name): \(question)",
            subtitle: "\(model.free ? "FREE" : model.costLabel) · \(model.endpoint.displayName) · ⏎ sends one request",
            icon: .symbol("sparkles"),
            badge: model.free ? "FREE" : "ASK",
            score: 50_000,
            actions: [
                PaletteAction(id: "ask", title: "Ask \(model.name)", kind: .custom, value: .text(question)),
            ],
            preview: .text("Question\n\n\(question)\n\nModel\n\n\(model.name) · \(model.endpoint.displayName)\n\(model.costLabel)\n\nOne-shot request. The answer is saved to Ask History."),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func answerRow(_ record: AskRecord) -> PaletteItem {
        PaletteItem(
            id: "answer:\(record.id)",
            title: record.question,
            subtitle: "\(record.model) · \(Self.relative(record.createdAt)) · \(record.durationMs) ms",
            icon: .symbol("text.bubble.fill"),
            badge: "ANSWER",
            score: 50_000,
            actions: [
                PaletteAction(id: "copy-answer", title: "Copy Answer", kind: .copyText, value: .text(record.answer)),
                PaletteAction(id: "ask-again", title: "Ask Again", kind: .custom, value: .text(record.question)),
                PaletteAction(id: "ask-history", title: "Show Ask History", kind: .custom, value: .text("history")),
            ],
            preview: .text(record.answer),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func setupRow(question: String?) -> PaletteItem {
        let waiting = question.map { "\n\nQuestion waiting:\n\($0)" } ?? ""
        return PaletteItem(
            id: "setup",
            title: "Add an API key for Ask",
            subtitle: "The key is stored in an encrypted local file and never written to config.toml",
            icon: .symbol("key"),
            badge: "SETUP",
            score: 50_000,
            actions: [
                PaletteAction(id: "ask-settings", title: "Open Ask Settings", kind: .custom, value: .text("settings")),
            ],
            preview: .text("Ask needs an OpenCode Zen, OpenCode Go, or OpenAI API key.\n\nOpen Settings → Ask, paste a key once, and save. Palette only shows whether a key exists after that.\(waiting)"),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private static func relative(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

/// The history half of the same tab. It is a normal provider with its own
/// trigger so Enter, selection, and actions work exactly like every other tab.
public final class AskHistoryProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "askh",
        name: "Ask History",
        trigger: "askh",
        isGlobal: false,
        priority: 74,
        icon: "symbol:clock.arrow.circlepath"
    )

    private let service: AskService
    private let bridge: HostBridge

    public init(service: AskService, bridge: HostBridge) {
        self.service = service
        self.bridge = bridge
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let records = (try? await service.history(limit: 500)) ?? []
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = max(1, request.limit)

        if query.isEmpty {
            return records.prefix(limit).map(row)
        }

        var matches: [(AskRecord, Double)] = []
        for record in records {
            let fields = [
                record.question,
                String(record.answer.prefix(4_000)),
                record.model,
                record.provider,
            ]
            let score = fields.compactMap { Ranking.score(query: query, candidate: $0) }.max()
            if let score { matches.append((record, score)) }
        }
        matches.sort {
            if abs($0.1 - $1.1) > 0.0001 { return $0.1 > $1.1 }
            return $0.0.createdAt > $1.0.createdAt
        }
        return matches.prefix(limit).map { row($0.0) }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard action.id == "delete-ask" else { return }
        try await service.deleteHistory(id: item.id)
        await bridge.notify("Deleted from Ask History")
    }

    private func row(_ record: AskRecord) -> PaletteItem {
        let tokens = record.promptTokens + record.completionTokens
        var parts = [record.model, record.provider, Self.relative(record.createdAt), "\(record.durationMs) ms"]
        if tokens > 0 { parts.append("\(tokens) tokens") }
        return PaletteItem(
            id: record.id,
            title: record.question,
            subtitle: parts.joined(separator: " · "),
            icon: .symbol("text.bubble"),
            badge: "Q&A",
            score: 0,
            actions: [
                PaletteAction(id: "copy-answer", title: "Copy Answer", kind: .copyText, value: .text(record.answer)),
                PaletteAction(id: "copy-question", title: "Copy Question", kind: .copyText, value: .text(record.question)),
                PaletteAction(id: "ask-again", title: "Ask Again", kind: .custom, value: .text(record.question)),
                PaletteAction(id: "delete-ask", title: "Delete from History", kind: .custom, value: .text(record.id)),
            ],
            preview: .text(record.answer),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private static func relative(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}
