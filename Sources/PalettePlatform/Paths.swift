import Foundation
import PaletteCore

public protocol PathEnumerating: Sendable {
    func enumerate(scope: Scope, kind: PathKind) async throws -> [String]
}

/// Drops entries no launcher should offer: punctuation-only names such as `[`
/// or `]`, control characters, broken symlinks, and the wrong file kind.
public enum PathFilter {
    public static func isUsable(_ path: String, expected: PathKind = .any) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard name.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
            return false
        }
        guard name.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        // Shell artifacts such as "[flags]" and "]" are not browsable paths.
        guard !name.hasPrefix("["), !name.hasSuffix("]") else { return false }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        switch expected {
        case .directories: return isDirectory.boolValue
        case .files: return !isDirectory.boolValue
        case .any: return true
        }
    }
}

public final class FDEnumerator: PathEnumerating {
    public init() {}

    public func enumerate(scope: Scope, kind: PathKind) async throws -> [String] {
        guard let fd = ToolLocator.shared.path(for: "fd") else {
            throw ProviderError.toolMissing("fd")
        }

        let matcher = scope.matcher
        var results: [String] = []
        var seen = Set<String>()
        let limit = 100_000

        for root in scope.expandedRoots {
            try Task.checkCancellation()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            let canonicalRoot = Self.canonicalPath(root)

            var arguments = [
                fd,
                "--absolute-path",
                "--no-ignore",
                "--print0",
                "--max-depth", String(max(1, scope.maxDepth)),
            ]
            if scope.includeHidden {
                arguments.append("--hidden")
            }
            switch kind {
            case .directories: arguments.append(contentsOf: ["--type", "d"])
            case .files: arguments.append(contentsOf: ["--type", "f"])
            case .any: break
            }
            for excluded in scope.fdExcludeBasenames {
                arguments.append(contentsOf: ["--exclude", excluded])
            }
            arguments.append(".")

            let result = try await ProcessRunner.run(
                arguments,
                cwd: root,
                environment: [:],
                timeout: 15
            )
            if result.timedOut {
                throw ProviderError.timedOut
            }
            // fd exits 1 when nothing matched, which is not an error.
            guard result.status == 0 || result.status == 1 else {
                throw ProviderError.failed("fd failed: \(result.stderrString)")
            }

            for path in Self.splitNUL(result.stdout) {
                try Task.checkCancellation()
                guard !path.isEmpty else { continue }
                guard path.hasPrefix(canonicalRoot + "/") else { continue }
                guard matcher.allows(path: path, isDirectory: kind != .files, root: canonicalRoot) else { continue }
                guard PathFilter.isUsable(path, expected: kind) else { continue }
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                results.append(path)
                if results.count >= limit { return results }
            }
        }

        return results
    }

    public static func canonicalPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buffer) != nil {
            return String(cString: buffer)
        }
        return (path as NSString).standardizingPath
    }

    public static func splitNUL(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        var output: [String] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0 {
            if index > start {
                output.append(String(decoding: data[start..<index], as: UTF8.self))
            }
            start = data.index(after: index)
        }
        if start < data.endIndex {
            output.append(String(decoding: data[start..<data.endIndex], as: UTF8.self))
        }
        return output
    }
}

public protocol FuzzyPathRanking: Sendable {
    func rank(paths: [String], query: String, limit: Int) async throws -> [String]
}

public final class FzfRanker: FuzzyPathRanking {
    public init() {}

    public func rank(paths: [String], query: String, limit: Int) async throws -> [String] {
        guard !paths.isEmpty, limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Array(paths.sorted(by: Self.shallowerFirst).prefix(limit))
        }

        guard let fzf = ToolLocator.shared.path(for: "fzf") else {
            throw ProviderError.toolMissing("fzf")
        }

        var input = Data()
        for path in paths {
            input.append(contentsOf: path.utf8)
            input.append(0)
        }

        let result = try await ProcessRunner.run(
            [
                fzf,
                "--filter", trimmed,
                "--scheme=path",
                "--read0",
                "--print0",
                "--tiebreak=index",
            ],
            stdin: input,
            timeout: 8
        )
        if result.timedOut { throw ProviderError.timedOut }
        guard result.status == 0 || result.status == 1 else {
            throw ProviderError.failed("fzf failed: \(result.stderrString)")
        }
        return Array(FDEnumerator.splitNUL(result.stdout).prefix(limit))
    }

    private static func shallowerFirst(_ lhs: String, _ rhs: String) -> Bool {
        let leftDepth = lhs.split(separator: "/").count
        let rightDepth = rhs.split(separator: "/").count
        if leftDepth != rightDepth { return leftDepth < rightDepth }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
