import XCTest
import Foundation
import PaletteCore
import PalettePlatform
import PaletteProviders

final class PathsEngineTests: XCTestCase {
    func testFDAndFZFOnTemporaryTree() async throws {
        guard ToolLocator.shared.path(for: "fd") != nil, ToolLocator.shared.path(for: "fzf") != nil else {
            throw XCTSkip("fd and fzf are required for the paths engine")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palette-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("Sources/Alpha"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "let a = 1".write(to: root.appendingPathComponent("Sources/Alpha/App.swift"), atomically: true, encoding: .utf8)
        try "ignored".write(to: root.appendingPathComponent("node_modules/ignored.js"), atomically: true, encoding: .utf8)
        try "readme".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let scope = Scope(roots: [root.path], exclude: ["node_modules"], maxDepth: 8)
        let paths = try await FDEnumerator().enumerate(scope: scope, kind: .any)
        XCTAssertTrue(paths.contains { $0.hasSuffix("App.swift") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("README.md") })
        XCTAssertFalse(paths.contains { $0.contains("node_modules") })

        let ranked = try await FzfRanker().rank(paths: paths, query: "appswift", limit: 10)
        XCTAssertTrue(ranked.contains { $0.hasSuffix("App.swift") })

        let shallow = try await FzfRanker().rank(paths: paths, query: "", limit: 10)
        XCTAssertFalse(shallow.isEmpty)
    }

    func testDirectoryBrowseIsBreadthFirst() async throws {
        guard ToolLocator.shared.path(for: "fd") != nil, ToolLocator.shared.path(for: "fzf") != nil else {
            throw XCTSkip("fd and fzf are required for the paths engine")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palette-browse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("Alpha/Deep"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Beta"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let launcher = await MainActor.run { LauncherService() }
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("palette-browse-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let provider = PathsProvider(
            configuration: PathsProviderConfiguration(
                id: "browse", name: "Browse", trigger: "browse", kind: .any,
                scopeName: "test", maxResults: 50, freeform: true
            ),
            scope: Scope(roots: [root.path], exclude: [], maxDepth: 8),
            launcher: launcher,
            cacheDirectory: cacheDir
        )
        let items = try await provider.search(SearchRequest(text: root.path + "/", limit: 50, isBound: true))
        let names = items.map(\.title)
        let alpha = try XCTUnwrap(names.firstIndex(of: "Alpha"))
        let deep = try XCTUnwrap(names.firstIndex(of: "Deep"))
        XCTAssertLessThan(alpha, deep, "Direct children must come before grandchildren")
        XCTAssertTrue(names.contains("Beta"))
        XCTAssertTrue(names.contains("note.txt"))
    }

    func testCapStopsTheWalk() async throws {
        guard ToolLocator.shared.path(for: "fd") != nil else {
            throw XCTSkip("fd is required for the paths engine")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palette-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<30 {
            try "".write(to: root.appendingPathComponent("file-\(index).txt"), atomically: true, encoding: .utf8)
        }

        let entries = try await FDEnumerator().enumerateEntries(
            scope: Scope(roots: [root.path], exclude: [], maxDepth: 3),
            kind: .files,
            maxEntries: 10
        )
        XCTAssertEqual(entries.count, 10, "the walk must stop at the cap")
        XCTAssertTrue(entries.allSatisfy { !$0.isDirectory })
    }

    func testPathFilterRejectsPartialAndBrokenEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palette-filter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let good = root.appendingPathComponent("project")
        let bracket = root.appendingPathComponent("[")
        try manager.createDirectory(at: good, withIntermediateDirectories: true)
        try "".write(to: bracket, atomically: true, encoding: .utf8)
        let broken = root.appendingPathComponent("broken-link")
        try manager.createSymbolicLink(atPath: broken.path, withDestinationPath: root.appendingPathComponent("missing").path)

        XCTAssertTrue(PathFilter.isUsable(good.path, expected: .directories))
        XCTAssertFalse(PathFilter.isUsable(bracket.path, expected: .files))
        let flags = root.appendingPathComponent("[flags]")
        try "".write(to: flags, atomically: true, encoding: .utf8)
        XCTAssertFalse(PathFilter.isUsable(flags.path, expected: .files))
        XCTAssertFalse(PathFilter.isUsable(broken.path, expected: .files))
    }

    func testSplitNUL() {
        let data = Data("one\0two\0three".utf8)
        XCTAssertEqual(FDEnumerator.splitNUL(data), ["one", "two", "three"])
    }

    /// A home walk must never enter the iCloud/TCC folders that block in
    /// `open(2)`, even when the config lists its own excludes.
    func testHomeScopeExcludesStalledICloudFolders() {
        let home = NSHomeDirectory()
        let scope = Scope(roots: ["~"], exclude: [])
        for name in ["Desktop", "Documents", "Downloads", "Library", ".Trash", "CloudStorage", "Mobile Documents", "Containers"] {
            XCTAssertTrue(scope.exclude.contains(name), "\(name) must be excluded from a ~ walk")
            XCTAssertTrue(scope.fdExcludeBasenames.contains(name), "fd must be told to skip \(name)")
        }
        XCTAssertFalse(scope.matcher.allows(path: home + "/Desktop/notes.md", isDirectory: false, root: home))
        XCTAssertFalse(scope.matcher.allows(path: home + "/Library/CloudStorage/iCloud Drive/x.md", isDirectory: false, root: home))
        XCTAssertTrue(scope.matcher.allows(path: home + "/dev/project/main.swift", isDirectory: false, root: home))

        // Naming the folder as the root is still an explicit opt-in.
        let explicit = Scope(roots: [home + "/Desktop"])
        XCTAssertTrue(explicit.matcher.allows(path: home + "/Desktop/notes.md", isDirectory: false, root: home + "/Desktop"))
        XCTAssertFalse(explicit.exclude.contains("Desktop"))
    }

    func testPartialWalkWithNoSnapshotIsUsed() async throws {
        guard ToolLocator.shared.path(for: "fd") != nil else {
            throw XCTSkip("fd is required for the paths engine")
        }
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("palette-partial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let enumerator = ScriptedEnumerator(results: [
            PathWalk(entries: [
                PathEntry(path: "/tmp/alpha.md", isDirectory: false),
                PathEntry(path: "/tmp/beta.md", isDirectory: false),
            ], partial: true),
        ])
        let provider = await makeProbeProvider(enumerator: enumerator, cacheDir: cacheDir)

        let items = try await itemsWhenIndexed(provider)
        XCTAssertEqual(Set(items.map(\.title)), ["alpha.md", "beta.md"], "a timed-out walk still feeds the index")
    }

    func testPartialWalkKeepsTheFullerPreviousSnapshot() async throws {
        guard ToolLocator.shared.path(for: "fd") != nil else {
            throw XCTSkip("fd is required for the paths engine")
        }
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("palette-partial-keep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let enumerator = ScriptedEnumerator(results: [
            PathWalk(entries: [
                PathEntry(path: "/tmp/alpha.md", isDirectory: false),
                PathEntry(path: "/tmp/beta.md", isDirectory: false),
                PathEntry(path: "/tmp/gamma.md", isDirectory: false),
            ]),
            PathWalk(entries: [PathEntry(path: "/tmp/alpha.md", isDirectory: false)], partial: true),
        ])
        let provider = await makeProbeProvider(enumerator: enumerator, cacheDir: cacheDir, refreshInterval: 0)
        _ = try await itemsWhenIndexed(provider, text: "alpha")
        // Zero TTL: this query starts the timed-out refresh.
        _ = try await provider.search(SearchRequest(text: "", limit: 10, isBound: true))
        try await waitUntil { await enumerator.walkCount() >= 2 }
        try await Task.sleep(nanoseconds: 50_000_000)

        let items = try await provider.search(SearchRequest(text: "", limit: 10, isBound: true))
        XCTAssertEqual(
            Set(items.map(\.title)),
            ["alpha.md", "beta.md", "gamma.md"],
            "a thinner partial walk must not shrink the index"
        )
    }

    func testDiskCacheRoundTripAndInvalidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("palette-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PathDiskCache(directory: directory)
        let entries = [
            PathEntry(path: "/tmp/project", isDirectory: true),
            PathEntry(path: "/tmp/notes.md", isDirectory: false),
        ]

        XCTAssertNil(cache.load(signature: "missing"))
        cache.save(entries, signature: "kind=any|roots=~")
        XCTAssertEqual(Set(cache.load(signature: "kind=any|roots=~") ?? []), Set(entries))
        // A different scope must not serve another scope's paths.
        XCTAssertNil(cache.load(signature: "kind=any|roots=~/dev"))
        // A file older than the max age is ignored, forcing a fresh walk.
        let stale = Date().addingTimeInterval(PathDiskCache.maxAge + 60)
        XCTAssertNil(cache.load(signature: "kind=any|roots=~", now: stale))
    }

    func testSearchReusesDiskCacheAcrossInstances() async throws {
        guard ToolLocator.shared.path(for: "fd") != nil else {
            throw XCTSkip("fd is required for the paths engine")
        }
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("palette-reuse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let enumerator = CountingEnumerator(entries: [
            PathEntry(path: "/tmp/project", isDirectory: true),
            PathEntry(path: "/tmp/notes.md", isDirectory: false),
        ])

        // A fresh instance stands in for the next app launch / reload. The
        // first query on a cold cache returns the indexing row, so wait for the
        // background walk before checking the disk copy.
        let first = await makeProbeProvider(enumerator: enumerator, cacheDir: cacheDir)
        let firstItems = try await itemsWhenIndexed(first)
        XCTAssertEqual(enumerator.walks, 1)
        XCTAssertEqual(Set(firstItems.map(\.title)), ["project", "notes.md"])

        let second = await makeProbeProvider(enumerator: enumerator, cacheDir: cacheDir)
        let started = Date()
        let secondItems = try await second.search(SearchRequest(text: "", limit: 10, isBound: true))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(Set(secondItems.map(\.title)), ["project", "notes.md"], "served from the disk cache, not a walk")
        XCTAssertLessThan(elapsed, 1.0, "the cached snapshot must not wait for a walk")

        // The disk copy is stale by design; it still refreshes in the background.
        try await waitUntil { enumerator.walks == 2 }
    }

    func testConcurrentSearchesShareOneWalk() async throws {
        guard ToolLocator.shared.path(for: "fd") != nil else {
            throw XCTSkip("fd is required for the paths engine")
        }
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("palette-dedupe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let enumerator = CountingEnumerator(entries: [PathEntry(path: "/tmp/project", isDirectory: true)])
        let provider = await makeProbeProvider(enumerator: enumerator, cacheDir: cacheDir)

        async let a = provider.search(SearchRequest(text: "", limit: 10, isBound: true))
        async let b = provider.search(SearchRequest(text: "proj", limit: 10, isBound: true))
        _ = try await (a, b)
        try await waitUntil { enumerator.walks == 1 }
        _ = try await provider.search(SearchRequest(text: "proj", limit: 10, isBound: true))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(enumerator.walks, 1, "Concurrent keystrokes must join one walk")
    }

    func testFirstQueryReturnsIndexingRowAndRefreshReplacesIt() async throws {
        guard ToolLocator.shared.path(for: "fd") != nil else {
            throw XCTSkip("fd is required for the paths engine")
        }
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("palette-first-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let gate = GateEnumerator(entries: [
            PathEntry(path: "/tmp/alpha.md", isDirectory: false),
        ])
        let provider = await makeProbeProvider(enumerator: gate, cacheDir: cacheDir)
        let updated = expectation(forNotification: PathsProvider.indexUpdatedNotification, object: "probe")

        let started = Date()
        let first = try await provider.search(SearchRequest(text: "alpha", limit: 10, isBound: true))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "a cold query must not wait for the walk")
        XCTAssertEqual(first.map(\.title), ["Indexing files…"])

        await gate.release()
        await fulfillment(of: [updated], timeout: 5)
        let items = try await provider.search(SearchRequest(text: "alpha", limit: 10, isBound: true))
        XCTAssertEqual(items.map(\.title), ["alpha.md"], "the finished walk re-runs the query")
    }

    func testStaleSnapshotIsServedWithoutWaiting() async throws {
        guard ToolLocator.shared.path(for: "fd") != nil else {
            throw XCTSkip("fd is required for the paths engine")
        }
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("palette-stale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let gate = GateEnumerator(entries: [
            PathEntry(path: "/tmp/alpha.md", isDirectory: false),
        ], open: true)
        // Zero TTL: every query is stale, so a refresh always starts.
        let provider = await makeProbeProvider(enumerator: gate, cacheDir: cacheDir, refreshInterval: 0)
        _ = try await itemsWhenIndexed(provider, text: "alpha")
        await gate.close()

        let started = Date()
        let items = try await provider.search(SearchRequest(text: "alpha", limit: 10, isBound: true))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(items.map(\.title), ["alpha.md"], "the old snapshot is served while the refresh runs")
        XCTAssertLessThan(elapsed, 0.2, "a stale snapshot must not wait on fd")
        try await waitUntil { await gate.walkCount() == 2 }
        await gate.release()
    }

    func testSnapshotUnderThresholdSkipsFzf() async throws {
        guard ToolLocator.shared.path(for: "fd") != nil else {
            throw XCTSkip("fd is required for the paths engine")
        }
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("palette-inprocess-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let gate = GateEnumerator(entries: [
            PathEntry(path: "/tmp/alpha.md", isDirectory: false),
            PathEntry(path: "/tmp/beta.md", isDirectory: false),
        ], open: true)
        let provider = await makeProbeProvider(enumerator: gate, cacheDir: cacheDir, ranker: FailingRanker())

        let items = try await itemsWhenIndexed(provider, text: "alpha")
        XCTAssertEqual(items.first?.title, "alpha.md", "a small snapshot ranks in-process, no fzf")
    }

    /// `PALETTE_BENCH=1 swift test --filter HomeQueryLatency` measures the real
    /// home walk against the real tools; the numbers go to the test log.
    func testHomeQueryLatencyBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["PALETTE_BENCH"] == "1" else {
            throw XCTSkip("set PALETTE_BENCH=1 to run the home-walk benchmark")
        }
        guard ToolLocator.shared.path(for: "fd") != nil else { throw XCTSkip("fd is required") }
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("palette-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let launcher = await MainActor.run { LauncherService() }
        let provider = PathsProvider(
            configuration: PathsProviderConfiguration(
                id: "bench", name: "Bench", trigger: "bench", kind: .any, scopeName: "home",
                maxResults: 50, homeIndexingAllowed: true
            ),
            scope: .home,
            launcher: launcher,
            cacheDirectory: cacheDir
        )
        let updated = expectation(forNotification: PathsProvider.indexUpdatedNotification, object: "bench")

        let coldStart = Date()
        let cold = try await provider.search(SearchRequest(text: "", limit: 50, isBound: true))
        let coldLatency = Date().timeIntervalSince(coldStart)
        XCTAssertEqual(cold.map(\.title), ["Indexing files…"])

        await fulfillment(of: [updated], timeout: 300)
        let warmStart = Date()
        let warm = try await provider.search(SearchRequest(text: "", limit: 50, isBound: true))
        let warmLatency = Date().timeIntervalSince(warmStart)
        print("PALETTE-BENCH cold=\(String(format: "%.3f", coldLatency))s warm=\(String(format: "%.3f", warmLatency))s rows=\(warm.count)")
        XCTAssertFalse(warm.isEmpty)
    }

    private func itemsWhenIndexed(
        _ provider: PathsProvider,
        text: String = "",
        limit: Int = 10,
        timeout: TimeInterval = 5
    ) async throws -> [PaletteItem] {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: [PaletteItem] = []
        while Date() < deadline {
            latest = try await provider.search(SearchRequest(text: text, limit: limit, isBound: true))
            if !latest.contains(where: { $0.id.hasSuffix(":indexing") }) { return latest }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("index did not finish within \(timeout)s; last rows: \(latest.map(\.title))")
        return latest
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    private func makeProbeProvider(
        enumerator: any PathEnumerating,
        cacheDir: URL,
        ranker: any FuzzyPathRanking = PrefixRanker(),
        refreshInterval: TimeInterval = 300
    ) async -> PathsProvider {
        let launcher = await MainActor.run { LauncherService() }
        return PathsProvider(
            configuration: PathsProviderConfiguration(
                id: "probe", name: "Probe", trigger: "probe", kind: .any, scopeName: "probe",
                refreshInterval: refreshInterval
            ),
            scope: Scope(roots: ["/tmp"]),
            launcher: launcher,
            cacheDirectory: cacheDir,
            enumerator: enumerator,
            ranker: ranker
        )
    }
}

/// Blocks the walk until `release()`, so a test can observe the indexing row
/// and the stale snapshot while the refresh is in flight.
private actor GateEnumerator: PathEnumerating {
    private let entries: [PathEntry]
    private var open: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var walks = 0

    init(entries: [PathEntry], open: Bool = false) {
        self.entries = entries
        self.open = open
    }

    func release() {
        open = true
        let waiters = self.waiters
        self.waiters = []
        for waiter in waiters { waiter.resume() }
    }

    func close() {
        open = false
    }

    func walkCount() -> Int {
        walks
    }

    private func waitForRelease() async {
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func enumerate(scope: Scope, kind: PathKind) async throws -> [String] {
        entries.map(\.path)
    }

    func enumerateEntries(scope: Scope, kind: PathKind, maxEntries: Int) async throws -> [PathEntry] {
        walks += 1
        await waitForRelease()
        return Array(entries.prefix(maxEntries))
    }
}

private struct FailingRanker: FuzzyPathRanking {
    func rank(paths: [String], query: String, limit: Int) async throws -> [String] {
        throw ProviderError.failed("fzf must not run for a small snapshot")
    }
}

private final class CountingEnumerator: PathEnumerating, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let entries: [PathEntry]

    var walks: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    init(entries: [PathEntry]) {
        self.entries = entries
    }

    func enumerate(scope: Scope, kind: PathKind) async throws -> [String] {
        entries.map(\.path)
    }

    func enumerateEntries(scope: Scope, kind: PathKind) async throws -> [PathEntry] {
        lock.withLock { count += 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        return entries
    }
}

private struct PrefixRanker: FuzzyPathRanking {
    func rank(paths: [String], query: String, limit: Int) async throws -> [String] {
        Array(paths.prefix(limit))
    }
}

/// Returns the walks in order, so a test can follow a good build with a
/// timed-out one.
private actor ScriptedEnumerator: PathEnumerating {
    private let results: [PathWalk]
    private var walks = 0

    init(results: [PathWalk]) {
        self.results = results
    }

    func walkCount() -> Int { walks }

    func enumerate(scope: Scope, kind: PathKind) async throws -> [String] {
        results.first?.entries.map(\.path) ?? []
    }

    func walk(scope: Scope, kind: PathKind, maxEntries: Int) async throws -> PathWalk {
        let index = min(walks, results.count - 1)
        walks += 1
        return results[index]
    }
}
