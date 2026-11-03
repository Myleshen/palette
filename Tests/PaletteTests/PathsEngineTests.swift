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
        let provider = PathsProvider(
            configuration: PathsProviderConfiguration(
                id: "browse", name: "Browse", trigger: "browse", kind: .any,
                scopeName: "test", maxResults: 50, freeform: true
            ),
            scope: Scope(roots: [root.path], exclude: [], maxDepth: 8),
            launcher: launcher
        )
        let items = try await provider.search(SearchRequest(text: root.path + "/", limit: 50, isBound: true))
        let names = items.map(\.title)
        let alpha = try XCTUnwrap(names.firstIndex(of: "Alpha"))
        let deep = try XCTUnwrap(names.firstIndex(of: "Deep"))
        XCTAssertLessThan(alpha, deep, "Direct children must come before grandchildren")
        XCTAssertTrue(names.contains("Beta"))
        XCTAssertTrue(names.contains("note.txt"))
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
}
