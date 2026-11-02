import Foundation

public enum PathExpansion {
    public static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        var value = path
        if value == "~" { return home }
        if value.hasPrefix("~/") {
            value = home + String(value.dropFirst(1))
        }
        return (value as NSString).standardizingPath
    }
}

public struct Scope: Equatable, Sendable {
    public var roots: [String]
    public var exclude: [String]
    public var include: [String]
    public var includeHidden: Bool
    public var maxDepth: Int
    public var respectGitignore: Bool

    public init(
        roots: [String],
        exclude: [String] = [],
        include: [String] = [],
        includeHidden: Bool = false,
        maxDepth: Int = 12,
        respectGitignore: Bool = false
    ) {
        self.roots = roots
        self.exclude = exclude
        self.include = include
        self.includeHidden = includeHidden
        self.maxDepth = maxDepth
        self.respectGitignore = respectGitignore
    }

    public static let defaultExcludes = [
        "node_modules", ".git", ".build", "target", ".next", "dist",
        "Library", ".cache", ".venv", "venv", "__pycache__", "DerivedData",
        "*.app", "*.framework", "*.dSYM",
    ]

    public static let projects = Scope(
        roots: ["~/dev", "~/dot-files"],
        exclude: defaultExcludes,
        maxDepth: 12
    )

    /// The whole home directory, with the noisy and generated directories
    /// excluded. Used by `/neo`, matching Noctalia's file launcher.
    public static let home = Scope(
        roots: ["~"],
        exclude: defaultExcludes + [".Trash", "Movies", "Music", "Pictures"],
        maxDepth: 12
    )

    public var expandedRoots: [String] {
        roots.map { PathExpansion.expand($0) }
    }

    /// Paths handed to `fd --exclude`, limited to simple basename patterns.
    public var fdExcludeBasenames: [String] {
        exclude.compactMap { pattern in
            var value = pattern
            if value.hasPrefix("!") { return nil }
            if value.hasPrefix("**/") { value.removeFirst(3) }
            if value.hasSuffix("/**") { value.removeLast(3) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !value.contains("*"), !value.contains("?"), !value.contains("/") else { return nil }
            return value
        }
    }

    public var matcher: ScopeMatcher { ScopeMatcher(scope: self) }

    public func allows(path: String, isDirectory: Bool) -> Bool {
        matcher.allows(path: path, isDirectory: isDirectory)
    }
}

public struct ScopeMatcher {
    public let scope: Scope
    private let rules: [GlobRule]

    public init(scope: Scope) {
        self.scope = scope
        self.rules = (scope.exclude.map { ($0, false) } + scope.include.map { ($0, true) })
            .compactMap { pattern, isInclude in GlobRule(pattern: pattern, isInclude: isInclude) }
    }

    public func allows(path: String, isDirectory: Bool, root: String? = nil) -> Bool {
        let normalized = (path as NSString).standardizingPath
        var relative = normalized
        if let root {
            let standardizedRoot = (root as NSString).standardizingPath
            if normalized.hasPrefix(standardizedRoot + "/") {
                relative = String(normalized.dropFirst(standardizedRoot.count + 1))
            }
        }

        var allowed = true
        for rule in rules where rule.matches(relative, isDirectory: isDirectory) {
            allowed = rule.isInclude
        }
        return allowed
    }
}

public struct GlobRule: Equatable {
    public let pattern: String
    public let isInclude: Bool
    public let directoryOnly: Bool
    public let regex: NSRegularExpression?

    public init?(pattern rawPattern: String, isInclude: Bool) {
        var pattern = rawPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, !pattern.hasPrefix("#") else { return nil }

        if pattern.hasPrefix("!") {
            pattern.removeFirst()
            self.isInclude = true
        } else {
            self.isInclude = isInclude
        }

        if pattern.hasSuffix("/") {
            pattern.removeLast()
            directoryOnly = true
        } else {
            directoryOnly = false
        }

        if pattern.hasPrefix("/") {
            pattern.removeFirst()
        }

        var leadingGlobstar = false
        if pattern.hasPrefix("**/") {
            pattern.removeFirst(3)
            leadingGlobstar = true
        }

        var body = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    body += ".*"
                    index = pattern.index(after: next)
                    continue
                }
                body += "[^/]*"
                index = next
                continue
            }
            if character == "?" {
                body += "[^/]"
                index = pattern.index(after: index)
                continue
            }
            if "\\^$.|+()[]{}".contains(character) {
                body += "\\" + String(character)
            } else {
                body.append(character)
            }
            index = pattern.index(after: index)
        }

        self.pattern = pattern
        let anchored = leadingGlobstar || pattern.contains("/")
        let expression: String
        if leadingGlobstar {
            expression = "^(?:.*/)?" + body + "$"
        } else if anchored {
            expression = "^" + body + "$"
        } else {
            expression = "(?:^|/)" + body + "(?:/|$)"
        }
        self.regex = try? NSRegularExpression(pattern: expression, options: [.caseInsensitive])
    }

    public func matches(_ path: String, isDirectory: Bool) -> Bool {
        guard let regex else { return false }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }
}
