import XCTest
import Foundation
import AppKit
import PalettePlatform
@testable import PaletteProviders
@testable import PaletteCore

/// Hard budgets for the paths users feel as lag. They are deliberately loose
/// enough for a loaded laptop at background QoS and still far below the
/// regression they exist to catch. Every failure prints the measured value.
@MainActor
final class PerformanceTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("palette-perf-\(UUID().uuidString)", isDirectory: true)

    private var bundledThemes: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Themes", isDirectory: true)
    }

    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func milliseconds(since start: Date) -> Double {
        Date().timeIntervalSince(start) * 1_000
    }

    // MARK: - Theme menu

    /// Opening `/theme` is a full-catalogue list, but only the visible rows
    /// draw. The drawing half is asserted by `theme-menu-lazy` in
    /// Scripts/e2e.sh, because PaletteTests does not link the app target that
    /// owns the view.
    func testThemeMenuOpensUnderBudget() async throws {
        guard FileManager.default.fileExists(atPath: bundledThemes.path) else {
            throw XCTSkip("bundled themes are missing")
        }
        let userThemes = root.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: userThemes, withIntermediateDirectories: true)
        let launcher = LauncherService()
        let provider = ThemeProvider(themesDirectory: userThemes, launcher: launcher)

        // First search populates the provider's catalog cache (the one-off
        // parse); the budget is what a second open costs.
        _ = try await provider.search(SearchRequest(text: "", limit: 5_000, isBound: true))
        let start = Date()
        let items = try await provider.search(SearchRequest(text: "", limit: 5_000, isBound: true))
        let measured = milliseconds(since: start)
        print("PALETTE-BENCH theme-menu-open rows=\(items.count) \(String(format: "%.1f", measured))ms")
        let catalogue = ThemeLoader.catalog(themesDirectory: userThemes, bundledThemesDirectory: bundledThemes)
        XCTAssertEqual(
            items.count, catalogue.count + 1,
            "the theme menu holds the whole catalogue plus the cards row"
        )
        XCTAssertLessThan(
            measured, 250,
            "theme menu open measured \(String(format: "%.1f", measured)) ms; budget 250 ms"
        )
    }

    func testThemeCatalogWarmUnderBudget() throws {
        guard FileManager.default.fileExists(atPath: bundledThemes.path) else {
            throw XCTSkip("bundled themes are missing")
        }
        let userThemes = root.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: userThemes, withIntermediateDirectories: true)

        _ = ThemeLoader.catalog(themesDirectory: userThemes, bundledThemesDirectory: bundledThemes)
        let start = Date()
        let catalog = ThemeLoader.catalog(themesDirectory: userThemes, bundledThemesDirectory: bundledThemes)
        let measured = milliseconds(since: start)
        print("PALETTE-BENCH theme-catalog-warm rows=\(catalog.count) \(String(format: "%.1f", measured))ms")
        XCTAssertEqual(
            catalog.count,
            ThemeLoader.builtinNames.count + ThemeLoader.bundledThemeNames(themesDirectory: bundledThemes).count,
            "the catalogue holds every built-in plus every bundled file"
        )
        XCTAssertLessThan(
            measured, 400,
            "warm theme catalog measured \(String(format: "%.1f", measured)) ms; budget 400 ms"
        )
    }

    // MARK: - Clipboard

    /// The one-off rebuild after a new copy: read 5k rows, fold them once, and
    /// hand the snapshot to the actor. The per-keystroke path then scores this
    /// snapshot without touching SQLite.
    func testClipboardSnapshotRebuildUnderBudget() async throws {
        let url = root.appendingPathComponent("clipboard.sqlite")
        let store = try PaletteStore(path: url.path)
        let body = "the quick brown fox jumps over the lazy dog"
        for index in 0..<5_000 {
            _ = try await store.insertClipboard(text: "note \(index) \(body)", maxEntries: 10_000)
        }
        let index = ClipboardSearchIndex()

        let start = Date()
        let entries = await index.entries(for: store)
        let measured = milliseconds(since: start)
        print("PALETTE-BENCH clipboard-snapshot-5k \(String(format: "%.1f", measured))ms")
        XCTAssertEqual(entries.count, 5_000)
        XCTAssertLessThan(
            measured, 100,
            "5k-entry snapshot rebuild measured \(String(format: "%.1f", measured)) ms; budget 100 ms"
        )
    }

    // MARK: - Paths

    /// A bound `/neo` query served from the warm snapshot. The fake enumerator
    /// and prefix ranker keep this about the provider's own overhead; `fd` and
    /// `fzf` have their own tests.
    func testNeoCachedQueryUnderBudget() async throws {
        guard ToolLocator.shared.path(for: "fd") != nil,
              ToolLocator.shared.path(for: "fzf") != nil else {
            throw XCTSkip("fd and fzf are required for the paths engine")
        }
        // Above the 20k threshold the provider ranks through fzf, the path a
        // large /neo cache actually takes. 20k rows clears the fzf threshold the way a real home walk does.
        let entries = (0..<20_100).map { index in
            PathEntry(path: "/tmp/perf/project-\(index)/file-\(index).swift", isDirectory: false)
        }
        let cacheDir = root.appendingPathComponent("paths-cache", isDirectory: true)
        let provider = PathsProvider(
            configuration: PathsProviderConfiguration(
                id: "neo", name: "Neovim", trigger: "neo", kind: .any,
                scopeName: "perf", maxResults: 50, refreshInterval: 300
            ),
            scope: Scope(roots: ["/tmp/perf"]),
            launcher: LauncherService(),
            cacheDirectory: cacheDir,
            enumerator: FixedEnumerator(entries: entries)
        )

        // Wait for the background walk so the next query reads the snapshot
        // instead of the indexing row.
        let deadline = Date().addingTimeInterval(10)
        var loaded = false
        while Date() < deadline {
            let items = try await provider.search(SearchRequest(text: "", limit: 50, isBound: true))
            if items.first?.title != "Indexing files…", items.first?.title != "Index files in your home folder" {
                loaded = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(loaded, "the snapshot never finished building")

        // Opening /neo on a warm snapshot: the cached paths are ordered, no
        // walk and no fzf process. Typed queries pay fzf on every keystroke.
        _ = try await provider.search(SearchRequest(text: "", limit: 50, isBound: true))
        let start = Date()
        let items = try await provider.search(SearchRequest(text: "", limit: 50, isBound: true))
        let measured = milliseconds(since: start)
        print("PALETTE-BENCH neo-cached-open rows=\(items.count) \(String(format: "%.1f", measured))ms")
        XCTAssertFalse(items.isEmpty)
        XCTAssertLessThan(
            measured, 200,
            "cached /neo query measured \(String(format: "%.1f", measured)) ms; budget 200 ms"
        )
    }

    // MARK: - Cross-app theme apply

    /// File generation only: a sandbox HOME, no app reloads, no managed
    /// policies. This is the "Apply finished but nothing changed" path.
    func testThemeApplyGenerationUnderBudget() async throws {
        guard FileManager.default.fileExists(atPath: bundledThemes.path) else {
            throw XCTSkip("bundled themes are missing")
        }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let config = home.appendingPathComponent(".config/palette", isDirectory: true)
        for app in ["kitty", "ghostty", "zellij", "nvim", "fish"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".config/\(app)"),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let paths = PalettePaths(
            home: home.path,
            configDir: config,
            stateDir: root.appendingPathComponent("state", isDirectory: true),
            cacheDir: root.appendingPathComponent("cache", isDirectory: true)
        )
        let engine = ThemingEngine(
            paths: paths,
            themesDirectory: bundledThemes,
            chromiumProbe: ThemingEngine.ChromiumProbe(
                installed: { [] },
                isRunning: { _ in false },
                silentActive: { _ in false },
                legacyProfile: { _ in false }
            ),
            reloadsEnabled: false
        )
        var theming = ThemingConfig()
        theming.enabled = true
        theming.source = .theme
        theming.targets = ["kitty", "ghostty", "zellij", "nvim", "fish", "starship"]

        let start = Date()
        let result = await engine.applyTheme(named: "catppuccin-mocha", config: theming)
        let measured = milliseconds(since: start)
        print("PALETTE-BENCH theme-apply files=\(result.written.count) \(String(format: "%.1f", measured))ms")
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertTrue(result.written.contains("kitty.conf"))
        XCTAssertLessThan(
            measured, 300,
            "theme apply file generation measured \(String(format: "%.1f", measured)) ms; budget 300 ms"
        )
    }
}

private struct FixedEnumerator: PathEnumerating {
    let entries: [PathEntry]

    func enumerate(scope: Scope, kind: PathKind) async throws -> [String] {
        entries.map(\.path)
    }

    func enumerateEntries(scope: Scope, kind: PathKind) async throws -> [PathEntry] {
        entries
    }

    func enumerateEntries(scope: Scope, kind: PathKind, maxEntries: Int) async throws -> [PathEntry] {
        Array(entries.prefix(maxEntries))
    }
}
