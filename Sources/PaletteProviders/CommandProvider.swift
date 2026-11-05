import Foundation
import PaletteCore
import PalettePlatform
import TOMLKit

/// Manifest-based command shortcuts. Commands live in
/// `~/.config/palette/commands.toml`; nothing is an inline shell string in the
/// main config and every command is visible before it runs.
public final class CommandProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "cmd",
        name: "Commands",
        trigger: "cmd",
        isGlobal: false,
        priority: 57,
        icon: "symbol:terminal"
    )

    public struct Command: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var keywords: [String]
        public var executable: String
        public var arguments: [String]
        public var workingDirectory: String?
        public var terminal: Bool
        public var confirm: Bool
    }

    private let launcher: LauncherService
    private let bridge: HostBridge
    private let terminal: String
    private let fileURL: URL

    public init(
        launcher: LauncherService,
        bridge: HostBridge,
        terminal: String = "kitty",
        fileURL: URL = PalettePaths.resolve().configDir.appendingPathComponent("commands.toml")
    ) {
        self.launcher = launcher
        self.bridge = bridge
        self.terminal = terminal
        self.fileURL = fileURL
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let commands = Self.load(from: fileURL)
        guard !commands.isEmpty else {
            return [PaletteItem(
                id: "cmd:setup",
                title: "Add a command shortcut",
                subtitle: "Create \(fileURL.path) with [[command]] entries",
                icon: .symbol("doc.badge.plus"),
                badge: "SETUP",
                score: 10_000,
                actions: [PaletteAction(id: "open", title: "Open Commands File", kind: .openPath, value: .text(fileURL.path))],
                preview: .text(Self.example),
                providerID: descriptor.id,
                providerName: descriptor.name
            )]
        }
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return commands.compactMap { command in
            let haystack = ([command.title] + command.keywords + [command.executable]).joined(separator: " ")
            if !query.isEmpty, Ranking.score(query: query, candidate: haystack) == nil { return nil }
            return item(command)
        }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let command = Self.load(from: fileURL).first(where: { $0.id == action.value.text }) else { return }
        if command.confirm {
            guard await bridge.prompt(kind: .confirm, title: "Run \(command.title)?", placeholder: nil) != nil else { return }
        }
        let cwd = command.workingDirectory.map { PathExpansion.expand($0) }
        if command.terminal {
            var line = ([command.executable] + command.arguments).map(Self.shellQuote).joined(separator: " ")
            if let cwd { line = "cd \(Self.shellQuote(cwd)) && " + line }
            let finalLine = line
            try await MainActor.run { try launcher.openTerminal(command: finalLine, app: terminal) }
        } else {
            try ProcessRunner.launch([command.executable] + command.arguments, cwd: cwd)
        }
    }

    private func item(_ command: Command) -> PaletteItem {
        let subtitle = ([command.executable] + command.arguments).joined(separator: " ")
        return PaletteItem(
            id: "cmd:\(command.id)",
            title: command.title,
            subtitle: subtitle,
            icon: .symbol("terminal"),
            badge: command.terminal ? "TERMINAL" : "RUN",
            score: 1_000,
            actions: [
                PaletteAction(id: "run", title: "Run Command", kind: .custom, value: .text(command.id)),
                PaletteAction(
                    id: "cmd-run-panel",
                    title: "Run in Panel",
                    kind: .custom,
                    value: .object([
                        "executable": command.executable,
                        "args": command.arguments.joined(separator: "\u{1F}"),
                        "cwd": command.workingDirectory ?? "",
                    ])
                ),
                PaletteAction(
                    id: "term-here",
                    title: "Open in Embedded Terminal",
                    kind: .custom,
                    value: .object(["path": PathExpansion.expand(command.workingDirectory ?? "~")])
                ),
            ],
            preview: .text("\(subtitle)\n\nWorking directory: \(command.workingDirectory ?? "current")"),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    public static func load(from url: URL) -> [Command] {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let table = try? TOMLTable(string: text),
              let entries = table["command"]?.array else { return [] }
        return entries.compactMap { value in
            guard let row = value.table,
                  let title = row["title"]?.string,
                  let executable = row["executable"]?.string,
                  !title.isEmpty, !executable.isEmpty else { return nil }
            let args = row["args"]?.array?.compactMap { $0.string } ?? []
            let keywords = row["keywords"]?.array?.compactMap { $0.string } ?? []
            let cwd = row["cwd"]?.string
            return Command(
                id: "\(title)-\(executable)",
                title: title,
                keywords: keywords,
                executable: executable,
                arguments: args,
                workingDirectory: cwd,
                terminal: row["terminal"]?.bool ?? true,
                confirm: row["confirm"]?.bool ?? false
            )
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static let example = """
    # ~/.config/palette/commands.toml
    # Uncomment and edit these entries. Every command is shown before it runs.
    #
    # [[command]]
    # title = "Gradle Build"
    # keywords = ["gradle", "java", "build"]
    # executable = "gradle"
    # args = ["build"]
    # cwd = "~/dev/my-project"
    # terminal = true
    # confirm = false
    #
    # [[command]]
    # title = "Go Test"
    # executable = "go"
    # args = ["test", "./..."]
    # terminal = true
    """
}
