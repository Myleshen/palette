import Darwin
import Foundation
import PaletteCore
import PalettePlatform

/// Listening TCP ports with the owning process, so a dev server can be found
/// and stopped without reaching for lsof by hand.
public final class PortProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "port",
        name: "Listening Ports",
        trigger: "port",
        isGlobal: false,
        priority: 55,
        icon: "symbol:network"
    )

    private struct Listener {
        var port: Int
        var pid: Int
        var command: String
        var user: String
        var cwd: String?
    }

    private let launcher: LauncherService
    private let bridge: HostBridge
    private actor Cache {
        var listeners: [Listener] = []
        var at = Date.distantPast
        func update(_ listeners: [Listener]) { self.listeners = listeners; at = Date() }
    }
    private let cache = Cache()

    public init(launcher: LauncherService, bridge: HostBridge) {
        self.launcher = launcher
        self.bridge = bridge
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let cached = await cache.listeners
        let at = await cache.at
        let listeners: [Listener]
        if Date().timeIntervalSince(at) < 3, !cached.isEmpty {
            listeners = cached
        } else {
            listeners = try await Self.listeners()
            await cache.update(listeners)
        }
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return listeners.compactMap { listener in
            let haystack = "\(listener.port) \(listener.command) \(listener.pid) \(listener.cwd ?? "")"
            if !query.isEmpty, Ranking.score(query: query, candidate: haystack) == nil { return nil }
            return item(listener)
        }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let value = action.value.object,
              let pid = Int(value["pid"] ?? ""),
              let port = value["port"] else { return }
        switch action.id {
        case "kill-term":
            guard await bridge.prompt(kind: .confirm, title: "Send SIGTERM to \(item.title)?", placeholder: nil) != nil else { return }
            if kill(pid_t(pid), SIGTERM) == 0 {
                await bridge.notify("Sent SIGTERM to PID \(pid)")
            } else {
                await bridge.notify("Could not signal PID \(pid)")
            }
        case "kill-force":
            guard await bridge.prompt(kind: .confirm, title: "Force kill \(item.title)? Unsaved work will be lost.", placeholder: nil) != nil else { return }
            if kill(pid_t(pid), SIGKILL) == 0 {
                await bridge.notify("Force killed PID \(pid)")
            } else {
                await bridge.notify("Could not kill PID \(pid)")
            }
        case "reveal":
            if let cwd = value["cwd"], !cwd.isEmpty { await MainActor.run { launcher.reveal(cwd) } }
        default:
            _ = port
        }
    }

    private func item(_ listener: Listener) -> PaletteItem {
        let cwd = listener.cwd.map { PathExpansion.expand($0) }
        var actions: [PaletteAction] = [
            PaletteAction(id: "open", title: "Open localhost:\(listener.port)", kind: .openURL,
                          value: .text("http://localhost:\(listener.port)")),
            PaletteAction(id: "copy-port", title: "Copy Port", kind: .copyText, value: .text("\(listener.port)")),
            PaletteAction(id: "copy-pid", title: "Copy PID", kind: .copyText, value: .text("\(listener.pid)")),
            PaletteAction(id: "kill-term", title: "Terminate Process (SIGTERM)", kind: .custom,
                          value: .object(["pid": "\(listener.pid)", "port": "\(listener.port)"])),
            PaletteAction(id: "kill-force", title: "Force Kill (SIGKILL)", kind: .custom,
                          value: .object(["pid": "\(listener.pid)", "port": "\(listener.port)"])),
        ]
        if let cwd {
            actions.append(PaletteAction(id: "reveal", title: "Reveal Working Directory", kind: .custom,
                                         value: .object(["pid": "\(listener.pid)", "cwd": cwd])))
        }
        let subtitle = [listener.user, listener.command, cwd].compactMap { $0 }.joined(separator: " · ")
        return PaletteItem(
            id: "port:\(listener.port):\(listener.pid)",
            title: "localhost:\(listener.port)",
            subtitle: subtitle,
            icon: .symbol("network"),
            badge: "TCP",
            score: 1_000,
            actions: actions,
            preview: cwd.map { .files(paths: [$0]) },
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private static func listeners() async throws -> [Listener] {
        let result = try await ProcessRunner.run(
            ["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-FpcuLn"],
            timeout: 8
        )
        var listeners: [Listener] = []
        var seen = Set<String>()
        var pid = 0
        var command = ""
        var user = ""
        for line in result.stdoutString.split(separator: "\n") {
            guard let first = line.first else { continue }
            let value = String(line.dropFirst())
            switch first {
            case "p": pid = Int(value) ?? 0; command = ""; user = ""
            case "c": command = value
            case "L": user = value
            case "n":
                guard pid > 0, let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                let key = "\(pid):\(port)"
                guard seen.insert(key).inserted else { continue }
                let cwd = await workingDirectory(pid: pid)
                listeners.append(Listener(port: port, pid: pid, command: command, user: user, cwd: cwd))
            default: break
            }
        }
        return listeners.sorted { $0.port < $1.port }
    }

    private static func workingDirectory(pid: Int) async -> String? {
        guard let result = try? await ProcessRunner.run(
            ["/usr/sbin/lsof", "-a", "-p", "\(pid)", "-d", "cwd", "-Fn"],
            timeout: 3
        ) else { return nil }
        for line in result.stdoutString.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }
}
