import Foundation

/// Shared address checks for URLs that come from model output or the web.
public enum SafeURL {
    /// A URL the app may contact automatically: https only, and neither a
    /// literal nor a resolved loopback, unspecified, private, link-local,
    /// unique-local or multicast address.
    public static func isSafeRemoteHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let rawHost = url.host, !rawHost.isEmpty,
              let host = canonicalHost(rawHost) else { return false }

        if let literal = literalAddress(host) {
            return literal.allSatisfy(isPublic)
        }
        // A numeric host that is not a canonical literal is a legacy encoding
        // (127.1, 2130706433, 0x7f000001, 0177.0.0.1), never a DNS name.
        if isLegacyNumeric(host) { return false }

        guard let resolved = resolve(host) else { return false }
        return !resolved.isEmpty && resolved.allSatisfy(isPublic)
    }

    /// Classification of one literal host, for tests and callers that already
    /// have an address. `nil` when the host is not a canonical IPv4/IPv6
    /// literal. Performs no DNS lookups.
    public static func isPublicLiteralHost(_ host: String) -> Bool? {
        guard let canonical = canonicalHost(host),
              let literal = literalAddress(canonical) else { return nil }
        return literal.allSatisfy(isPublic)
    }

    /// Cancels a redirect whose target fails the same check, so a 3xx towards
    /// a private host is never followed and never checked after the fact.
    public final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        public override init() { super.init() }

        public func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url, SafeURL.isSafeRemoteHTTPS(url) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    // MARK: - Host normalising

    /// Lowercase, no trailing dot, IPv6 brackets stripped. `nil` for hosts with
    /// spaces or control characters, which URL parsers tolerate but no real
    /// host contains.
    static func canonicalHost(_ raw: String) -> String? {
        var host = raw
        guard !host.isEmpty else { return nil }
        for scalar in host.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return nil
            }
        }
        if host.hasPrefix("[") || host.hasSuffix("]") {
            guard host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 else { return nil }
            host = String(host.dropFirst().dropLast())
        }
        if host.hasSuffix(".") { host.removeLast() }
        host = host.lowercased()
        guard !host.isEmpty else { return nil }
        return host
    }

    private static func literalAddress(_ host: String) -> [Address]? {
        if host.contains(":") {
            return ipv6Address(host).map { [$0] }
        }
        if isCanonicalIPv4(host) {
            return ipv4Address(host).map { [$0] }
        }
        return nil
    }

    /// Dotted quad with no leading zeros, confirmed by `inet_pton`. The shape
    /// check keeps `0177.0.0.1` from being read as octal 127.0.0.1.
    private static func isCanonicalIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard (1...3).contains(part.count),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0",
                  let value = Int(part), value <= 255 else { return false }
        }
        return true
    }

    private static func ipv4Address(_ host: String) -> Address? {
        var raw = in_addr()
        guard inet_pton(AF_INET, host, &raw) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &raw) { Array($0) }
        return Address(family: AF_INET, bytes: bytes)
    }

    private static func ipv6Address(_ host: String) -> Address? {
        var raw = in6_addr()
        guard inet_pton(AF_INET6, host, &raw) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &raw) { Array($0) }
        return Address(family: AF_INET6, bytes: bytes)
    }

    private static func isLegacyNumeric(_ host: String) -> Bool {
        if host.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }) { return true }
        let lower = host.lowercased()
        guard lower.hasPrefix("0x") else { return false }
        return lower.dropFirst(2).allSatisfy { $0.isHexDigit || $0 == "." }
    }

    // MARK: - Resolution

    /// Resolution runs off the caller's thread and gives up after a second, so
    /// a hanging resolver cannot stall the main thread.
    /// `shortcut: the caller still blocks for up to a second and a hung lookup
    /// leaks one worker; cache results or go async if either starts to hurt.`
    private static func resolve(_ host: String) -> [Address]? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = AddressBox()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = lookup(host)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 1) == .success else { return nil }
        return box.value
    }

    /// Both A and AAAA answers are collected; every one of them must be public.
    private static func lookup(_ host: String) -> [Address] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return [] }
        defer { freeaddrinfo(info) }

        var addresses: [Address] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let node = cursor {
            defer { cursor = node.pointee.ai_next }
            guard let sa = node.pointee.ai_addr else { continue }
            switch node.pointee.ai_family {
            case AF_INET:
                var raw = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                let bytes = withUnsafeBytes(of: &raw) { Array($0) }
                addresses.append(Address(family: AF_INET, bytes: bytes))
            case AF_INET6:
                var raw = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_addr
                }
                let bytes = withUnsafeBytes(of: &raw) { Array($0) }
                addresses.append(Address(family: AF_INET6, bytes: bytes))
            default:
                continue
            }
        }
        return addresses
    }

    private struct Address {
        let family: Int32
        let bytes: [UInt8]
    }

    private final class AddressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Address]?
        var value: [Address]? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
            set {
                lock.lock()
                storage = newValue
                lock.unlock()
            }
        }
    }

    // MARK: - Address classification

    private static func isPublic(_ address: Address) -> Bool {
        switch address.family {
        case AF_INET:
            guard address.bytes.count == 4 else { return false }
            return isPublicIPv4(address.bytes)
        case AF_INET6:
            guard address.bytes.count == 16 else { return false }
            return isPublicIPv6(address.bytes)
        default:
            return false
        }
    }

    private static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        if b[0] == 0 || b[0] == 10 || b[0] == 127 { return false }   // this-host, private, loopback
        if b[0] == 169 && b[1] == 254 { return false }                // 169.254/16 link-local
        if b[0] == 172 && (b[1] & 0xF0) == 16 { return false }        // 172.16/12 private
        if b[0] == 192 && b[1] == 168 { return false }                // 192.168/16 private
        if b[0] >= 224 { return false }                               // 224/4 multicast, 240/4 reserved
        return true
    }

    private static func isPublicIPv6(_ b: [UInt8]) -> Bool {
        // :: unspecified and ::1 loopback.
        if b[0..<15].allSatisfy({ $0 == 0 }) && (b[15] == 0 || b[15] == 1) { return false }
        // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d) embed an
        // IPv4 address that must pass the same rules.
        if b[0..<10].allSatisfy({ $0 == 0 })
            && ((b[10] == 0xFF && b[11] == 0xFF) || (b[10] == 0 && b[11] == 0)) {
            return isPublicIPv4(Array(b[12..<16]))
        }
        if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return false }     // fe80::/10 link-local
        if (b[0] & 0xFE) == 0xFC { return false }                     // fc00::/7 unique-local
        if b[0] == 0xFF { return false }                              // ff00::/8 multicast
        return true
    }
}
