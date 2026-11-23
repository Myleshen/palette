import Foundation

/// A command line tool a provider cannot work without. Detected once when the
/// provider is enabled (Settings or first launch), never from inside `search`.
public struct ProviderRequirement: Equatable, Sendable, Hashable {
    /// The executable name `ToolLocator` resolves, e.g. `devx`.
    public var tool: String
    /// The shell command that installs it, shown with a Copy button.
    public var install: String
    /// One line on what stops working without it.
    public var why: String
    /// Where to read more, when a command is not enough.
    public var docs: String?

    public init(tool: String, install: String, why: String, docs: String? = nil) {
        self.tool = tool
        self.install = install
        self.why = why
        self.docs = docs
    }
}

/// The central map of provider id → tools. Paths providers are not in here:
/// they are matched by engine, since a user provider chooses its own id.
public enum ProviderRequirements {
    public static let fd = ProviderRequirement(
        tool: "fd",
        install: "brew install fd",
        why: "file providers need fd to enumerate paths"
    )
    public static let fzf = ProviderRequirement(
        tool: "fzf",
        install: "brew install fzf",
        why: "file providers need fzf to rank large path lists"
    )
    public static let pathTools = [fd, fzf]
    static let gh = ProviderRequirement(
        tool: "gh",
        install: "brew install gh",
        why: "GitHub providers list repos, pull requests, issues and runs through gh"
    )
    static let bw = ProviderRequirement(
        tool: "bw",
        install: "brew install bitwarden-cli",
        why: "the Bitwarden providers read the vault through the bw CLI"
    )

    public static let map: [String: [ProviderRequirement]] = [
        "proj": [ProviderRequirement(
            tool: "devx",
            install: "brew install Myleshen/tap/devx",
            why: "/proj lists and creates projects through devx"
        )],
        "atlas": [ProviderRequirement(
            tool: "atlas",
            install: "brew install Myleshen/tap/atlas",
            why: "/atlas reads the index and review state that atlas writes"
        )],
        "gh": [gh], "ghr": [gh], "ghp": [gh], "ghi": [gh], "gha": [gh], "ghn": [gh],
        "bw": [bw], "bwu": [bw], "bwt": [bw], "bwn": [bw], "bwo": [bw],
        "docker": [ProviderRequirement(
            tool: "docker",
            install: "brew install --cask docker",
            why: "/docker lists and controls containers through the docker CLI"
        )],
        "zj": [ProviderRequirement(
            tool: "zellij",
            install: "brew install zellij",
            why: "/zj lists terminal sessions through zellij"
        )],
    ]

    public static func requirements(forProviderID id: String) -> [ProviderRequirement] {
        map[id] ?? []
    }
}
