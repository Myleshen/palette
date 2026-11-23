import Foundation

/// A tag like `v2.18.1` or `2.19.0-beta.2`, compared the semver way. Tags are
/// not required to carry three numbers: `2.18` reads as `2.18.0`.
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Empty means a normal release, which sorts above every prerelease.
    public let prerelease: [String]

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" {
            text.removeFirst()
        }
        guard !text.isEmpty else { return nil }
        // Build metadata never takes part in precedence.
        if let plus = text.firstIndex(of: "+") {
            text = String(text[..<plus])
        }
        var prereleaseText: String?
        if let dash = text.firstIndex(of: "-") {
            prereleaseText = String(text[text.index(after: dash)...])
            text = String(text[..<dash])
        }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let major = Int(parts[0]) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) : 0
        let patch = parts.count > 2 ? Int(parts[2]) : 0
        guard let minor, let patch else { return nil }

        var identifiers: [String] = []
        if let prereleaseText {
            identifiers = prereleaseText
                .split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
            guard !identifiers.isEmpty,
                  identifiers.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } })
            else { return nil }
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = identifiers
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // A release outranks any prerelease of the same core version.
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumber = Int(left)
            let rightNumber = Int(right)
            switch (leftNumber, rightNumber) {
            case let (leftNumber?, rightNumber?):
                return leftNumber < rightNumber
            case (_?, nil):
                return true                      // numeric identifiers sort first
            case (nil, _?):
                return false
            case (nil, nil):
                return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// What a GitHub release response needs: the version and the page to read.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: SemanticVersion
    public let tag: String
    public let url: URL

    public init(version: SemanticVersion, tag: String, url: URL) {
        self.version = version
        self.tag = tag
        self.url = url
    }
}

/// The decisions a release check makes, kept free of networking and UI so they
/// can be tested directly.
public enum UpdatePolicy {
    public static let releasesAPI = URL(string: "https://api.github.com/repos/Myleshen/palette/releases/latest")!
    /// Automatic checks wait this long between attempts. A launch inside the
    /// window reuses the cached answer instead of hitting GitHub.
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    /// Homebrew stays the update mechanism; Palette only runs this for you.
    public static let brewCommand = "brew update && brew upgrade --cask palette"

    public static func isCheckDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval
    }

    /// A failed automatic check must not retry on every launch: 15 minutes,
    /// doubling, capped at the normal daily interval.
    public static func retryDelay(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = min(failures - 1, 8)
        return min(checkInterval, 15 * 60 * pow(2, Double(exponent)))
    }

    public static func isRetryAllowed(retryAfter: Date?, now: Date = Date()) -> Bool {
        guard let retryAfter else { return true }
        return now >= retryAfter
    }

    /// One banner per version; relaunching or checking again stays quiet.
    public static func shouldNotify(version: String, lastNotified: String?) -> Bool {
        version != lastNotified
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = SemanticVersion(candidate),
              let current = SemanticVersion(current) else { return false }
        return candidate > current
    }

    public static func parseRelease(_ data: Data) -> ReleaseInfo? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any],
              let tag = object["tag_name"] as? String,
              let version = SemanticVersion(tag),
              let page = object["html_url"] as? String,
              let url = URL(string: page) else { return nil }
        return ReleaseInfo(version: version, tag: tag, url: url)
    }
}
