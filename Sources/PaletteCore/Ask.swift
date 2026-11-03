import Foundation

public enum AskEndpoint: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case opencodeZen = "opencode-zen"
    case opencodeGo = "opencode-go"
    case openai

    public var displayName: String {
        switch self {
        case .opencodeZen: return "OpenCode Zen"
        case .opencodeGo: return "OpenCode Go"
        case .openai: return "OpenAI"
        }
    }

    public var baseURL: URL {
        switch self {
        case .opencodeZen: return URL(string: "https://opencode.ai/zen/v1")!
        case .opencodeGo: return URL(string: "https://opencode.ai/inference/go/openai/v1")!
        case .openai: return URL(string: "https://api.openai.com/v1")!
        }
    }

    public var keyEnvironment: [String] {
        switch self {
        case .opencodeZen: return ["PALETTE_ASK_KEY", "OPENCODE_API_KEY"]
        case .opencodeGo: return ["PALETTE_ASK_KEY", "OPENCODE_GO_API_KEY"]
        case .openai: return ["PALETTE_ASK_KEY", "OPENAI_API_KEY"]
        }
    }
}

public struct AskModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var endpoint: AskEndpoint
    public var free: Bool
    public var note: String

    public init(id: String, name: String, endpoint: AskEndpoint, free: Bool, note: String = "") {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.free = free
        self.note = note
    }

    /// Endpoint-qualified identity used in the runtime preference.
    public var key: String { "\(endpoint.rawValue)/\(id)" }

    public static let catalog: [AskModel] = [
        // Zen free models come first and the small flash models lead: `/ask`
        // is for quick questions, not long reasoning sessions.
        .init(id: "glm-5.3-flash-free", name: "GLM 5.3 Flash", endpoint: .opencodeZen, free: true),
        .init(id: "deepseek-v4.1-flash-free", name: "DeepSeek V4.1 Flash", endpoint: .opencodeZen, free: true),
        .init(id: "mimo-v2.6-flash-free", name: "MiMo V2.6 Flash", endpoint: .opencodeZen, free: true),
        .init(id: "flint-40b-free", name: "Flint 40B", endpoint: .opencodeZen, free: true),
        .init(id: "nemotron-3.5-lightning-free", name: "Nemotron 3.5 Lightning", endpoint: .opencodeZen, free: true),
        .init(id: "pulse-alpha-free", name: "Pulse Alpha", endpoint: .opencodeZen, free: true),
        .init(id: "beam-free", name: "Beam", endpoint: .opencodeZen, free: true),
        .init(id: "nemotron-3.5-super-vl-free", name: "Nemotron 3.5 Super VL", endpoint: .opencodeZen, free: true),
        .init(id: "big-pickle", name: "Big Pickle", endpoint: .opencodeZen, free: true, note: "Reasoning"),

        .init(id: "beam-free", name: "Beam (Go)", endpoint: .opencodeGo, free: true),
        .init(id: "iceman-contributor-free", name: "Iceman Contributor", endpoint: .opencodeGo, free: true),

        .init(id: "deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", endpoint: .opencodeGo, free: false, note: "Small"),
        .init(id: "glm-5.3-flash", name: "GLM 5.3 Flash", endpoint: .opencodeGo, free: false, note: "Small"),
        .init(id: "mimo-v2.6-flash", name: "MiMo V2.6 Flash", endpoint: .opencodeGo, free: false, note: "Small"),
        .init(id: "minimax-m3.1-flash", name: "MiniMax M3.1 Flash", endpoint: .opencodeGo, free: false, note: "Small"),
        .init(id: "qwen3.8-flash", name: "Qwen 3.8 Flash", endpoint: .opencodeGo, free: false, note: "Small"),
        .init(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", endpoint: .opencodeGo, free: false, note: "Small"),

        .init(id: "gpt-4o-mini", name: "GPT-4o mini", endpoint: .openai, free: false, note: "Small"),
        .init(id: "gpt-4.1-mini", name: "GPT-4.1 mini", endpoint: .openai, free: false, note: "Small"),
    ]

    /// Free models first, then the cheap/small fallbacks. Keeping this stable
    /// makes the chooser predictable even when a provider catalog changes.
    public static let fallbackOrder: [AskModel] = catalog.enumerated().sorted { lhs, rhs in
        if lhs.element.free != rhs.element.free { return lhs.element.free }
        return lhs.offset < rhs.offset
    }.map(\.element)

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

    public init(
        endpoint: AskEndpoint = .opencodeZen,
        model: String = AskModel.defaultModel.id,
        maxHistory: Int = 200,
        retentionDays: Int = 30,
        maxTokens: Int = 512,
        fallback: Bool = true
    ) {
        self.endpoint = endpoint
        self.model = model
        self.maxHistory = maxHistory
        self.retentionDays = retentionDays
        self.maxTokens = maxTokens
        self.fallback = fallback
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
}
