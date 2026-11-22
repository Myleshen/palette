import Darwin
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
    /// `directory` resolves `Include` paths and is normally `~/.ssh`.
    public static func parse(_ text: String, directory: URL? = nil) -> [SSHHost] {
        var seen = Set<String>()
        return hosts(in: text, directory: directory, depth: 0)
            .filter { seen.insert($0.alias).inserted }
            .sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }

    private static func hosts(in text: String, directory: URL?, depth: Int) -> [SSHHost] {
        var hosts: [SSHHost] = []
        var patterns: [String] = []
        var hostName: String?
        var user: String?
        var port: String?

        func reset() {
            patterns = []
            hostName = nil
            user = nil
            port = nil
        }

        func flush() {
            defer { reset() }
            for pattern in patterns where !pattern.contains("*") && !pattern.contains("?") {
                hosts.append(SSHHost(alias: pattern, hostName: hostName, user: user, port: port))
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let key = parts.first?.lowercased() else { continue }
            switch key {
            case "host":
                flush()
                // A Host line can list several patterns; each real host is
                // addressable on its own.
                patterns = Array(parts.dropFirst())
            case "include" where depth == 0:
                for pattern in parts.dropFirst() {
                    for url in includeURLs(pattern, directory: directory) {
                        guard let included = try? String(contentsOf: url, encoding: .utf8) else { continue }
                        hosts += Self.hosts(in: included, directory: directory, depth: 1)
                    }
                }
            case "hostname", "user", "port":
                guard !patterns.isEmpty, parts.count >= 2 else { continue }
                let value = parts[1]
                if key == "hostname" { hostName = value }
                if key == "user" { user = value }
                if key == "port" { port = value }
            default:
                break
            }
        }
        flush()
        return hosts
    }

    /// `Include` takes patterns relative to the config directory. One level
    /// only: an included file never pulls in another include.
    private static func includeURLs(_ pattern: String, directory: URL?) -> [URL] {
        var path = pattern
        if path == "~" {
            path = NSHomeDirectory()
        } else if path.hasPrefix("~/") {
            path = NSHomeDirectory() + String(path.dropFirst(1))
        } else if !path.hasPrefix("/") {
            guard let directory else { return [] }
            path = directory.appendingPathComponent(path).path
        }

        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(path, 0, nil, &matches) == 0 else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { index in
            guard let entry = matches.gl_pathv[index] else { return nil }
            return URL(fileURLWithPath: String(cString: entry))
        }
    }
}
