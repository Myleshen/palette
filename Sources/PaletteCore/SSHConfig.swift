import Foundation

public struct SSHHost: Sendable, Equatable {
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: String?

    public var destination: String {
        guard let user, !user.isEmpty else { return alias }
        return "\(user)@\(alias)"
    }

    public var subtitle: String {
        var parts: [String] = []
        if let hostName, hostName != alias { parts.append(hostName) }
        if let user, !user.isEmpty { parts.append("user \(user)") }
        if let port, !port.isEmpty, port != "22" { parts.append("port \(port)") }
        return parts.isEmpty ? "ssh \(alias)" : parts.joined(separator: " · ")
    }
}

/// Minimal `~/.ssh/config` reader: enough to list hosts, not a full parser.
public enum SSHConfig {
    public static func parse(_ text: String) -> [SSHHost] {
        var hosts: [SSHHost] = []
        var current: SSHHost?
        var seen = Set<String>()

        func flush() {
            guard let host = current else { return }
            current = nil
            guard !host.alias.contains("*"), !host.alias.contains("?") else { return }
            guard !seen.contains(host.alias) else { return }
            seen.insert(host.alias)
            hosts.append(host)
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let key = parts.first?.lowercased(), parts.count >= 2 else { continue }
            let value = parts[1]
            switch key {
            case "host":
                flush()
                current = SSHHost(alias: value)
            case "hostname":
                current?.hostName = value
            case "user":
                current?.user = value
            case "port":
                current?.port = value
            default:
                break
            }
        }
        flush()
        return hosts.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }
}
