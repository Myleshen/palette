import Foundation
import PaletteCore

public protocol PathEnumerating: Sendable {
    func enumerate(scope: Scope, kind: PathKind) async throws -> [String]
    /// Same walk, but carries the directory flag so callers don't stat again.
    func enumerateEntries(scope: Scope, kind: PathKind) async throws -> [PathEntry]
    /// The bounded walk: stops cleanly at `maxEntries`.
    func enumerateEntries(scope: Scope, kind: PathKind, maxEntries: Int) async throws -> [PathEntry]
    /// Same bounded walk, but says whether the timeout cut it short.
    func walk(scope: Scope, kind: PathKind, maxEntries: Int) async throws -> PathWalk
}

public extension PathEnumerating {
    func enumerate(scope: Scope, kind: PathKind) async throws -> [String] {
        try await enumerateEntries(scope: scope, kind: kind).map(\.path)
    }

    func enumerateEntries(scope: Scope, kind: PathKind) async throws -> [PathEntry] {
        let paths = try await enumerate(scope: scope, kind: kind)
        return paths.compactMap { path in
            guard let isDirectory = PathFilter.inspect(path, expected: kind) else { return nil }
            return PathEntry(path: path, isDirectory: isDirectory)
        }
    }

    func enumerateEntries(scope: Scope, kind: PathKind, maxEntries: Int) async throws -> [PathEntry] {
        Array(try await enumerateEntries(scope: scope, kind: kind).prefix(max(1, maxEntries)))
    }

    /// Enumerators without a timeout of their own are never partial.
    func walk(scope: Scope, kind: PathKind, maxEntries: Int) async throws -> PathWalk {
        PathWalk(entries: try await enumerateEntries(scope: scope, kind: kind, maxEntries: maxEntries))
    }
}

/// One bounded walk's outcome. `partial` means the timeout stopped it early and
/// `entries` is whatever fd had printed by then.
public struct PathWalk: Sendable {
    public let entries: [PathEntry]
    public let partial: Bool

    public init(entries: [PathEntry], partial: Bool = false) {
        self.entries = entries
        self.partial = partial
    }
}

public struct PathEntry: Sendable, Hashable {
    public let path: String
    public let isDirectory: Bool

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }
}

/// Drops entries no launcher should offer: punctuation-only names such as `[`
/// or `]`, control characters, broken symlinks, and the wrong file kind.
public enum PathFilter {
    /// Name checks only, no filesystem access. A typed `fd` walk already knows
    /// the entry exists, so it uses this and skips a stat per entry.
    public static func hasUsableName(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard name.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
            return false
        }
        guard name.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        // Shell artifacts such as "[flags]" and "]" are not browsable paths.
        return !name.hasPrefix("[") && !name.hasSuffix("]")
    }

    /// One stat: returns whether the path is a directory, or nil when unusable.
    public static func inspect(_ path: String, expected: PathKind = .any) -> Bool? {
        guard hasUsableName(path) else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }
        switch expected {
        case .directories: return isDirectory.boolValue ? true : nil
        case .files: return isDirectory.boolValue ? nil : false
        case .any: return isDirectory.boolValue
        }
    }

    public static func isUsable(_ path: String, expected: PathKind = .any) -> Bool {
        inspect(path, expected: expected) != nil
    }
}

public final class FDEnumerator: PathEnumerating {
    /// A home walk on a big machine is millions of entries; past this the
    /// launcher cannot rank usefully anyway, so the walk stops.
    public static let defaultMaxEntries = 150_000

    /// A home walk on a big machine takes minutes, so the cap is the bound, not
    /// a short timeout that would fail every build before it finishes.
    private static let walkTimeout: TimeInterval = 120

    public init() {}

    public func enumerateEntries(scope: Scope, kind: PathKind) async throws -> [PathEntry] {
        try await enumerateEntries(scope: scope, kind: kind, maxEntries: Self.defaultMaxEntries)
    }

    public func enumerateEntries(scope: Scope, kind: PathKind, maxEntries: Int) async throws -> [PathEntry] {
        try await walk(scope: scope, kind: kind, maxEntries: max(1, maxEntries)).entries
    }

    public func walk(scope: Scope, kind: PathKind, maxEntries: Int) async throws -> PathWalk {
        #if DEBUG
        // The walk blocks in read(2) for seconds: never on the main thread.
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif


        guard let fd = ToolLocator.shared.path(for: "fd") else {
            throw ProviderError.toolMissing("fd")
        }

        let matcher = scope.matcher
        let sink = WalkSink(cap: max(1, maxEntries))
        var partial = false

        for root in scope.expandedRoots {
            try Task.checkCancellation()
            guard !sink.capped else { break }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            let canonicalRoot = Self.canonicalPath(root)
            let arguments = Self.arguments(fd: fd, scope: scope, kind: kind)
            let splitter = NULSplitter()

            let result = try await ProcessRunner.stream(arguments, cwd: root, timeout: Self.walkTimeout) { chunk in
                // One pool per 64 KB read: a home walk makes millions of
                // temporary NSStrings and would otherwise only release them at
                // the end.
                autoreleasepool {
                    splitter.feed(chunk) { record in
                        sink.append(record, matcher: matcher, kind: kind, root: canonicalRoot)
                    }
                }
            }
            if sink.capped {
                Log.shared.warn(
                    "fd walk stopped at the \(sink.cap)-entry cap for \(scope.roots.joined(separator: ", "))",
                    source: "paths"
                )
                break
            }
            if result.timedOut {
                // A stalled mount or an unreadable subtree must not throw away
                // the entries already collected: keep them and report partial.
                splitter.flush { record in
                    sink.append(record, matcher: matcher, kind: kind, root: canonicalRoot)
                }
                partial = true
                Log.shared.warn(
                    "fd walk timed out at root=\(canonicalRoot) maxDepth=\(scope.maxDepth) deepest=\(sink.deepest) entries=\(sink.results.count)/\(sink.cap) after \(Int(Self.walkTimeout))s; returning what it collected",
                    source: "paths"
                )
                break
            }
            // fd exits 1 when nothing matched, which is not an error.
            guard result.status == 0 || result.status == 1 else {
                throw ProviderError.failed("fd failed: \(result.stderrString)")
            }
            splitter.flush { record in
                sink.append(record, matcher: matcher, kind: kind, root: canonicalRoot)
            }
        }

        return PathWalk(entries: sink.results, partial: partial)
    }

    private static func arguments(fd: String, scope: Scope, kind: PathKind) -> [String] {
        var arguments = [fd, "--absolute-path"]
        if !scope.respectGitignore {
            arguments.append("--no-ignore")
        }
        arguments.append(contentsOf: ["--print0", "--max-depth", String(max(1, scope.maxDepth))])
        if scope.includeHidden {
            arguments.append("--hidden")
        }
        // fd classifies the entries, so a typed kind needs no stat pass.
        switch kind {
        case .directories: arguments.append(contentsOf: ["--type", "d"])
        case .files: arguments.append(contentsOf: ["--type", "f"])
        case .any: break
        }
        for excluded in scope.fdExcludeBasenames {
            arguments.append(contentsOf: ["--exclude", excluded])
        }
        arguments.append(".")
        return arguments
    }

    public func enumerate(scope: Scope, kind: PathKind) async throws -> [String] {
        try await enumerateEntries(scope: scope, kind: kind).map(\.path)
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

/// Collects entries from the reader thread. Only that thread touches it while
/// the walk runs; the walk's continuation provides the happens-before edge
/// before the caller reads `results`.
private final class WalkSink: @unchecked Sendable {
    let cap: Int
    private(set) var capped = false
    private(set) var results: [PathEntry] = []
    /// Slash count of the deepest accepted path, for the timeout log.
    private(set) var deepest = 0
    private var seen = Set<String>()

    init(cap: Int) {
        self.cap = cap
        results.reserveCapacity(min(cap, 20_000))
    }

    /// Returns false when the cap is reached, which stops the child.
    func append(_ path: String, matcher: ScopeMatcher, kind: PathKind, root: String) -> Bool {
        guard results.count < cap else {
            capped = true
            return false
        }
        guard !path.isEmpty else { return true }
        // A "/" root must not turn its prefix into "//".
        guard path.hasPrefix(root == "/" ? "/" : root + "/") else { return true }
        guard matcher.allows(path: path, isDirectory: kind != .files, root: root) else { return true }
        guard PathFilter.hasUsableName(path) else { return true }

        let isDirectory: Bool
        switch kind {
        case .directories: isDirectory = true
        case .files: isDirectory = false
        case .any:
            // `kind = any` needs the flag, and fd's type filter would drop
            // symlinks, so this is the one walk that pays a stat per entry.
            guard let flag = PathFilter.inspect(path, expected: .any) else { return true }
            isDirectory = flag
        }
        guard seen.insert(path).inserted else { return true }
        let depth = path.reduce(into: 0) { if $1 == "/" { $0 += 1 } }
        if depth > deepest { deepest = depth }
        results.append(PathEntry(path: path, isDirectory: isDirectory))
        return true
    }
}

/// Splits a NUL-separated stream into records across pipe reads. Only the
/// reader thread touches it.
private final class NULSplitter: @unchecked Sendable {
    private var pending = Data()

    /// Calls `handle` for every complete record; false stops the walk.
    func feed(_ chunk: UnsafeRawBufferPointer, _ handle: (String) -> Bool) -> Bool {
        pending.append(contentsOf: chunk)
        var start = pending.startIndex
        while start < pending.endIndex, let zero = pending[start...].firstIndex(of: 0) {
            if zero > start {
                let record = String(decoding: pending[start..<zero], as: UTF8.self)
                if !handle(record) { return false }
            }
            start = pending.index(after: zero)
        }
        if start > pending.startIndex {
            pending.removeSubrange(pending.startIndex..<start)
        }
        return true
    }

    func flush(_ handle: (String) -> Bool) {
        guard !pending.isEmpty else { return }
        _ = handle(String(decoding: pending, as: UTF8.self))
        pending.removeAll()
    }
}

public protocol FuzzyPathRanking: Sendable {
    func rank(paths: [String], query: String, limit: Int) async throws -> [String]
}

public enum PathOrdering {
    public static func depth(_ path: String) -> Int {
        path.split(separator: "/").count
    }

    /// Deliberately not `localizedStandardCompare`: it is ICU-backed and takes
    /// seconds over a 150k-entry snapshot, and a launcher list has no need to
    /// respect collation. Depth is computed once per path rather than on every
    /// comparison. Byte order is stable and cheap.
    public static func shallowest(_ paths: [String], limit: Int) -> [String] {
        paths.map { (depth: depth($0), path: $0) }
            .sorted { lhs, rhs in
                if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
                return lhs.path < rhs.path
            }
            .prefix(limit)
            .map(\.path)
    }
}

/// In-process filter for small snapshots: spawning `fzf` per keystroke costs
/// more than scanning a few thousand paths, and it keeps search working when
/// fzf is missing.
public struct RankingPathRanker: FuzzyPathRanking {
    public init() {}

    public func rank(paths: [String], query: String, limit: Int) async throws -> [String] {
        guard !paths.isEmpty, limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return PathOrdering.shallowest(paths, limit: limit)
        }

        let terms = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        var scored: [(path: String, score: Double)] = []
        for path in paths {
            if let score = Ranking.score(terms: terms, candidate: path) {
                scored.append((path, score))
            }
        }
        scored.sort { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.0001 { return lhs.score > rhs.score }
            let leftDepth = PathOrdering.depth(lhs.path)
            let rightDepth = PathOrdering.depth(rhs.path)
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return lhs.path < rhs.path
        }
        return scored.prefix(limit).map(\.path)
    }
}

public final class FzfRanker: FuzzyPathRanking {
    public init() {}

    public func rank(paths: [String], query: String, limit: Int) async throws -> [String] {
        guard !paths.isEmpty, limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return PathOrdering.shallowest(paths, limit: limit)
        }

        guard let fzf = ToolLocator.shared.path(for: "fzf") else {
            throw ProviderError.toolMissing("fzf")
        }

        var input = Data()
        input.reserveCapacity(paths.count * 48)
        for path in paths {
            input.append(contentsOf: path.utf8)
            input.append(0)
        }

        // ProcessRunner drains fzf's stdout while it writes this stdin, and a
        // fzf that exits early (timeout, cancelled keystroke) is a short write
        // plus a log line instead of SIGPIPE.
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
}
