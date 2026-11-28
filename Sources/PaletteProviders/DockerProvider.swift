import Foundation
import PaletteCore
import PalettePlatform

/// Docker containers with start/stop/restart and logs in the terminal.
public final class DockerProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "docker",
        name: "Docker",
        trigger: "docker",
        isGlobal: false,
        priority: 46,
        icon: "symbol:shippingbox",
        keywords: ["docker", "container", "compose", "logs", "restart", "stop", "start"]
    )

    private let launcher: LauncherService
    private let terminalApp: String
    private let bridge: HostBridge?
    /// `docker ps -a` measured ~330 ms, so one listing serves every keystroke
    /// inside a short window and a container change clears it.
    private let psCache = ShortCache<String>(ttl: 5)
    /// Re-runs the current search after a container changes state.
    public var onRefresh: (() -> Void)?

    public init(launcher: LauncherService, terminalApp: String, bridge: HostBridge? = nil) {
        self.launcher = launcher
        self.terminalApp = terminalApp
        self.bridge = bridge
    }

    private var dockerPath: String? { ToolLocator.shared.path(for: "docker") }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let docker = dockerPath else {
            return [PaletteItem(
                id: "docker-missing",
                title: "Docker is not installed",
                subtitle: "Install Docker Desktop or colima, then reload Palette",
                icon: .symbol("shippingbox"),
                badge: "SETUP",
                group: "Docker",
                score: 1_000,
                actions: [PaletteAction(
                    id: "install",
                    title: "Install Docker Desktop",
                    kind: .openURL,
                    value: .text("https://www.docker.com/products/docker-desktop/")
                )],
                providerID: descriptor.id,
                providerName: descriptor.name
            )]
        }

        let stdout: String
        if let cached = await psCache.get("ps") {
            stdout = cached
        } else {
            guard let result = try? await ProcessRunner.run(
                [docker, "ps", "-a", "--format", "{{.Names}}\t{{.State}}\t{{.Image}}\t{{.Status}}"],
                timeout: 8
            ), result.status == 0 else {
                return [PaletteItem(
                    id: "docker-down",
                    title: "Docker is not running",
                    subtitle: "Start Docker Desktop or the daemon, then reload",
                    icon: .symbol("shippingbox"),
                    badge: "SETUP",
                    group: "Docker",
                    score: 1_000,
                    actions: [PaletteAction(id: "open-app", title: "Open Docker", kind: .custom, value: .text("open-app"))],
                    providerID: descriptor.id,
                    providerName: descriptor.name
                )]
            }
            stdout = result.stdoutString
            await psCache.set(stdout, key: "ps")
        }

        let containers = stdout
            .split(separator: "\n")
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count >= 4 }

        guard !containers.isEmpty else {
            return [PaletteItem(
                id: "docker-empty",
                title: "No containers",
                subtitle: "docker ps shows nothing on this machine",
                icon: .symbol("shippingbox"),
                badge: "EMPTY",
                group: "Docker",
                score: 1_000,
                actions: [],
                providerID: descriptor.id,
                providerName: descriptor.name
            )]
        }

        var items = containers.map { fields -> PaletteItem in
            let name = fields[0]
            let state = fields[1]
            let image = fields[2]
            let running = state == "running"
            return PaletteItem(
                id: "docker:\(name)",
                title: name,
                subtitle: "\(state) · \(image)",
                icon: .symbol(running ? "shippingbox.fill" : "shippingbox"),
                badge: running ? "RUNNING" : state.uppercased(),
                group: running ? "Running" : "Stopped",
                score: running ? 9_000 : 8_000,
                actions: [
                    PaletteAction(id: running ? "stop" : "start", title: running ? "Stop \(name)" : "Start \(name)", kind: .custom, value: .text("\(running ? "stop" : "start"):\(name)")),
                    PaletteAction(id: "restart", title: "Restart \(name)", kind: .custom, value: .text("restart:\(name)")),
                    PaletteAction(id: "logs", title: "Follow logs", kind: .custom, value: .text("logs:\(name)")),
                ],
                providerID: descriptor.id,
                providerName: descriptor.name
            )
        }
        if !query.isEmpty {
            items = items.compactMap { item in
                guard let score = Ranking.score(query: query, candidate: "\(item.title) \(item.subtitle ?? "")") else {
                    return nil
                }
                var item = item
                item.score = score
                return item
            }
        }
        return items
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let raw = action.value.text else { return }
        // "Open Docker" is not a `command:name` action; handle it first.
        if raw == "open-app" {
            if let app = ToolLocator.shared.appPath(named: "Docker") {
                await MainActor.run { launcher.activateApp(path: app) }
            }
            return
        }
        guard let docker = dockerPath else { return }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let command = parts[0]
        let name = parts[1]
        switch command {
        case "logs":
            let app = terminalApp
            try await MainActor.run {
                try launcher.openTerminal(command: Self.logsCommand(docker: docker, name: name), app: app)
            }
        default:
            let result = try? await ProcessRunner.run([docker, command, name], timeout: 20)
            if result?.status != 0 {
                let line = result?.stderrString
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .first
                    .map(String.init) ?? ""
                await bridge?.notify(line.isEmpty ? "docker \(command) \(name) failed" : line)
            } else {
                await bridge?.notify("docker \(command) \(name) done")
            }
            await psCache.invalidate()
            await MainActor.run { onRefresh?() }
        }
    }

    /// Both the binary path and the container name can contain shell
    /// metacharacters, so the terminal command quotes each one.
    static func logsCommand(docker: String, name: String) -> String {
        "\(ProjectProvider.shellQuote(docker)) logs -f \(ProjectProvider.shellQuote(name))"
    }
}
