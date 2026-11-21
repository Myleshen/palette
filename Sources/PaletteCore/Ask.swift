import Foundation

public enum AskEndpoint: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case opencodeGo = "opencode-go"

    public var displayName: String {
        "OpenCode Go"
    }

    public var baseURL: URL {
        URL(string: "https://opencode.ai/inference/go/openai/v1")!
    }

    public var keyEnvironment: [String] {
        ["PALETTE_ASK_KEY", "OPENCODE_GO_API_KEY"]
    }
}

public struct AskModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var endpoint: AskEndpoint
    public var free: Bool
    public var note: String
    /// USD per million input tokens. Zero for free models.
    public var inputCost: Double
    /// USD per million output tokens. Zero for free models.
    public var outputCost: Double

    public init(
        id: String,
        name: String,
        endpoint: AskEndpoint,
        free: Bool,
        note: String = "",
        inputCost: Double = 0,
        outputCost: Double = 0
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.free = free
        self.note = note
        self.inputCost = inputCost
        self.outputCost = outputCost
    }

    public var costLabel: String {
        free ? "Free" : "$\(Self.price(inputCost)) in / $\(Self.price(outputCost)) out per 1M"
    }

    private static func price(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    /// Endpoint-qualified identity used in the runtime preference.
    public var key: String { "\(endpoint.rawValue)/\(id)" }

    /// Model ids and prices come from the live endpoint, so this list can
    /// drift as the provider adds or retires models.
    public static let catalog: [AskModel] = [
        .init(id: "beam-free", name: "Beam Free", endpoint: .opencodeGo, free: true),
        .init(id: "hy4-flash-free", name: "Hy4 flash Free", endpoint: .opencodeGo, free: true),
        .init(id: "iceman-contributor-free", name: "Iceman Contributor Free", endpoint: .opencodeGo, free: true),
        .init(id: "longcat-2.5-free", name: "LongCat 2.5 Free", endpoint: .opencodeGo, free: true),
        .init(id: "muse-spark-1.2-contributor", name: "Muse Spark 1.2 Contributor", endpoint: .opencodeGo, free: false, inputCost: 0.1, outputCost: 0.2),
        .init(id: "muse-spark-1.3-contributor", name: "Muse Spark 1.3 Contributor", endpoint: .opencodeGo, free: false, inputCost: 0.1, outputCost: 0.2),
        .init(id: "mimo-v2.6-flash", name: "MiMo-V2.6-Flash", endpoint: .opencodeGo, free: false, inputCost: 0.14, outputCost: 0.28),
        .init(id: "qwen3.8-flash", name: "Qwen3.8 Flash", endpoint: .opencodeGo, free: false, inputCost: 0.15, outputCost: 0.47),
        .init(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", endpoint: .opencodeGo, free: false, inputCost: 0.1, outputCost: 0.5),
        .init(id: "gpt-6-luna", name: "GPT-6 Luna", endpoint: .opencodeGo, free: false, inputCost: 0.1, outputCost: 0.5),
        .init(id: "glm-5.3-flash", name: "GLM-5.3-Flash", endpoint: .opencodeGo, free: false, inputCost: 0.15, outputCost: 0.5),
        .init(id: "hy3", name: "Hy3", endpoint: .opencodeGo, free: false, inputCost: 0.14, outputCost: 0.58),
        .init(id: "deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash 1017", endpoint: .opencodeGo, free: false, inputCost: 0.15, outputCost: 0.6),
        .init(id: "minimax-m3.1-flash", name: "MiniMax M3.1 Flash", endpoint: .opencodeGo, free: false, inputCost: 0.15, outputCost: 0.6),
        .init(id: "mimo-v2.6-pro", name: "MiMo-V2.6-Pro", endpoint: .opencodeGo, free: false, inputCost: 0.435, outputCost: 0.87),
        .init(id: "gpt-5.6-luna", name: "GPT-5.6 Luna", endpoint: .opencodeGo, free: false, inputCost: 0.2, outputCost: 1.2),
        .init(id: "longcat-2.0", name: "LongCat-2.0", endpoint: .opencodeGo, free: false, inputCost: 0.3, outputCost: 1.2),
        .init(id: "minimax-m3", name: "MiniMax-M3", endpoint: .opencodeGo, free: false, inputCost: 0.3, outputCost: 1.2),
        .init(id: "qwen3.7-plus", name: "Qwen3.7 Plus", endpoint: .opencodeGo, free: false, inputCost: 0.4, outputCost: 1.6),
        .init(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", endpoint: .opencodeGo, free: false, inputCost: 0.66, outputCost: 1.98),
        .init(id: "hy4", name: "Hy4", endpoint: .opencodeGo, free: false, inputCost: 0.834, outputCost: 2.501),
        .init(id: "hy4-preview", name: "Hy4 preview", endpoint: .opencodeGo, free: false, inputCost: 0.834, outputCost: 2.501),
        .init(id: "step-5-preview", name: "Step 5 Preview", endpoint: .opencodeGo, free: false, inputCost: 1, outputCost: 2.7),
        .init(id: "kimi-k2.7-code", name: "Kimi K2.7 Code", endpoint: .opencodeGo, free: false, inputCost: 0.95, outputCost: 4),
        .init(id: "glm-5.3", name: "GLM-5.3", endpoint: .opencodeGo, free: false, inputCost: 1.4, outputCost: 4.4),
        .init(id: "qwen4-max", name: "Qwen4 Max", endpoint: .opencodeGo, free: false, inputCost: 1.5, outputCost: 4.5),
        .init(id: "grok-4.7", name: "Grok 4.7", endpoint: .opencodeGo, free: false, inputCost: 2, outputCost: 6),
        .init(id: "qwen3.8-max", name: "Qwen3.8 Max", endpoint: .opencodeGo, free: false, inputCost: 2, outputCost: 6),
        .init(id: "gemini-4-argon", name: "Gemini 4 Argon", endpoint: .opencodeGo, free: false, inputCost: 2, outputCost: 10),
        .init(id: "kimi-k3.1-pro", name: "Kimi K3.1 Pro", endpoint: .opencodeGo, free: false, inputCost: 2, outputCost: 10),
        .init(id: "kimi-k3", name: "Kimi K3", endpoint: .opencodeGo, free: false, inputCost: 3, outputCost: 15),
    ]

    /// Free models first, then the cheap/small fallbacks. Keeping this stable
    /// makes the chooser predictable even when a provider catalog changes.
    public static let fallbackOrder: [AskModel] = {
        let free = catalog.filter(\.free)
        let paid = catalog.filter { !$0.free }.sorted { lhs, rhs in
            if lhs.outputCost != rhs.outputCost { return lhs.outputCost < rhs.outputCost }
            if lhs.inputCost != rhs.inputCost { return lhs.inputCost < rhs.inputCost }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return free + paid
    }()

    public static func models(for endpoint: AskEndpoint) -> [AskModel] {
        fallbackOrder.filter { $0.endpoint == endpoint }
    }

    public static func find(key: String) -> AskModel? {
        catalog.first { $0.key == key }
    }

    public static func find(id: String) -> AskModel? {
        catalog.first { $0.id == id }
    }

    public static let defaultModel = catalog[0]
}

public struct AskConfig: Sendable, Equatable {
    public var endpoint: AskEndpoint
    public var model: String
    public var maxHistory: Int
    public var retentionDays: Int
    public var maxTokens: Int
    public var fallback: Bool
    /// Sound and Dock bounce when an answer lands while the window is in the
    /// background.
    public var notify: Bool

    public init(
        endpoint: AskEndpoint = .opencodeGo,
        model: String = AskModel.defaultModel.id,
        maxHistory: Int = 200,
        retentionDays: Int = 30,
        maxTokens: Int = 8_192,
        fallback: Bool = true,
        notify: Bool = true
    ) {
        self.endpoint = endpoint
        self.model = model
        self.maxHistory = maxHistory
        self.retentionDays = retentionDays
        self.maxTokens = maxTokens
        self.fallback = fallback
        self.notify = notify
    }

    public var selectedModel: AskModel {
        AskModel.catalog.first { $0.endpoint == endpoint && $0.id == model }
            ?? AskModel(id: model, name: model, endpoint: endpoint, free: false)
    }

    /// Identifies the configured pair. A runtime model choice is only valid
    /// while this still matches, so changing provider/model in Settings wins.
    public var selectionSignature: String { "\(endpoint.rawValue)|\(model)" }
}

public struct AskRecord: Identifiable, Equatable, Sendable, Codable {
    public var id: String
    public var question: String
    public var answer: String
    public var model: String
    public var provider: String
    public var createdAt: Date
    public var durationMs: Int
    public var promptTokens: Int
    public var completionTokens: Int
    public var error: String?

    public init(
        id: String,
        question: String,
        answer: String,
        model: String,
        provider: String,
        createdAt: Date,
        durationMs: Int = 0,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        error: String? = nil
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.model = model
        self.provider = provider
        self.createdAt = createdAt
        self.durationMs = durationMs
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.error = error
    }

    /// One line under an answer: what answered, how long it took, how big it was.
    public var metaLine: String {
        var parts = [model, "\(durationMs) ms"]
        let tokens = promptTokens + completionTokens
        if tokens > 0 { parts.append("\(tokens) tokens") }
        return parts.joined(separator: " · ")
    }
}
