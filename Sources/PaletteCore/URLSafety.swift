import Foundation

/// Shared address checks for URLs that come from model output or the web.
public enum SafeURL {
    /// A URL the app may contact automatically: https only, and never a
    /// literal loopback, link-local or private address. `shortcut: a DNS name
    /// that resolves to a private address is not resolved here; add
    /// getaddrinfo checks if the threat model needs it.`
    public static func isSafeRemoteHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        if isPrivateIPv4(host) { return false }
        if host.contains(":") {
            // IPv6 literals: loopback, unspecified, link-local and unique-local.
            if host == "::1" || host == "::" || host == "0:0:0:0:0:0:0:1" { return false }
            if host.hasPrefix("fe8") || host.hasPrefix("fe9")
                || host.hasPrefix("fea") || host.hasPrefix("feb") { return false }
            if host.hasPrefix("fc") || host.hasPrefix("fd") { return false }
        }
        return true
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard part.count <= 3, let value = Int(part), value >= 0, value <= 255,
                  part.allSatisfy(\.isNumber) else { return false }
            octets.append(value)
        }
        let first = octets[0]
        let second = octets[1]
        if first == 10 || first == 0 || first == 127 { return true }
        if first == 169 && second == 254 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        if first == 192 && second == 168 { return true }
        return false
    }
}
