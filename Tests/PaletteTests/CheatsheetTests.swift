import XCTest
import TOMLKit
@testable import PaletteCore
@testable import PaletteProviders

final class CheatsheetTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-cheatsheets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# Shortcuts\n".write(to: folder.appendingPathComponent("vim.md"), atomically: true, encoding: .utf8)
        try "PDF".write(to: folder.appendingPathComponent("git.pdf"), atomically: true, encoding: .utf8)
        try "ignored".write(to: folder.appendingPathComponent("draft.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testListsAllowedExtensionsWithDocumentPreviews() async throws {
        let provider = CheatsheetProvider(config: CheatsheetConfig(folders: [folder.path], extensions: ["md", "pdf"]))
        let items = try await provider.search(SearchRequest(text: "", isBound: true))

        XCTAssertEqual(items.map(\.title).sorted(), ["git.pdf", "vim.md"])
        XCTAssertFalse(items.contains { $0.title == "draft.swift" })
        for item in items {
            guard case .document(let url, let kind)? = item.preview else {
                return XCTFail("\(item.title) has no document preview")
            }
            XCTAssertTrue(url.hasSuffix("/\(item.title)"), "unexpected path \(url)")
            XCTAssertTrue(url.contains(folder.lastPathComponent), "unexpected folder \(url)")
            XCTAssertEqual(kind, item.title == "vim.md" ? "markdown" : "pdf")
        }
    }

    func testFiltersByQueryAndShowsSetupRowWithoutFolders() async throws {
        let provider = CheatsheetProvider(config: CheatsheetConfig(folders: [folder.path], extensions: ["md", "pdf"]))
        let matches = try await provider.search(SearchRequest(text: "vim", isBound: true))
        XCTAssertEqual(matches.map(\.title), ["vim.md"])

        let unconfigured = CheatsheetProvider(config: CheatsheetConfig())
        let setup = try await unconfigured.search(SearchRequest(text: "", isBound: true))
        XCTAssertEqual(setup.map(\.title), ["Set up cheatsheets"])
    }

    func testSetupAndEmptyRowsOnlyShowInProviderScope() async throws {
        let unconfigured = CheatsheetProvider(config: CheatsheetConfig())
        let globalWithoutFolders = try await unconfigured.search(SearchRequest(text: "settings", isBound: false))
        XCTAssertTrue(globalWithoutFolders.isEmpty)
        let boundWithoutFolders = try await unconfigured.search(SearchRequest(text: "settings", isBound: true))
        XCTAssertEqual(boundWithoutFolders.map(\.id), ["cheat:setup"])

        let configured = CheatsheetProvider(config: CheatsheetConfig(folders: [folder.path], extensions: ["md"]))
        let globalMatches = try await configured.search(SearchRequest(text: "vim", isBound: false))
        XCTAssertEqual(globalMatches.map(\.title), ["vim.md"])

        let globalMiss = try await configured.search(SearchRequest(text: "zebra", isBound: false))
        XCTAssertTrue(globalMiss.isEmpty)
        let boundMiss = try await configured.search(SearchRequest(text: "zebra", isBound: true))
        XCTAssertEqual(boundMiss.map(\.id), ["cheat:empty"])
    }

    /// The folder the user writes into `config.toml` has to survive the real
    /// loader and reach the provider the app builds from it; a test that hands
    /// the provider a folder directly never touches that path.
    func testConfigFileFolderReachesTheProvider() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-cheatsheet-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PalettePaths(
            home: root.path,
            configDir: root.appendingPathComponent("config", isDirectory: true),
            stateDir: root.appendingPathComponent("state", isDirectory: true),
            cacheDir: root.appendingPathComponent("cache", isDirectory: true)
        )
        try paths.createDirectories()
        try "[cheatsheets]\nfolders = [\"\(folder.path)\"]\n"
            .write(to: paths.configFile, atomically: true, encoding: .utf8)

        let loaded = ConfigLoader.load(paths: paths)
        XCTAssertTrue(loaded.config.cheatsheets.folders.contains(folder.path))

        let provider = CheatsheetProvider(config: loaded.config.cheatsheets)
        let items = try await provider.search(SearchRequest(text: "", isBound: true))
        XCTAssertEqual(items.map(\.title).sorted(), ["git.pdf", "vim.md"])
    }

    func testConfigRoundTripsThroughRender() throws {
        var config = PaletteConfig()
        config.cheatsheets.folders = ["~/docs/cheats"]
        config.cheatsheets.extensions = ["pdf", "md"]

        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(
            TOMLTable(string: ConfigWriter.render(config)),
            diagnostics: &diagnostics
        )
        XCTAssertEqual(parsed.cheatsheets.folders, [(("~/docs/cheats") as NSString).expandingTildeInPath])
        XCTAssertEqual(parsed.cheatsheets.extensions, ["pdf", "md"])

        let dotted = try ConfigLoader.parse(
            TOMLTable(string: "[cheatsheets]\nextensions = [\".PDF\", \".Md\", \"txt\"]\n"),
            diagnostics: &diagnostics
        )
        XCTAssertEqual(dotted.cheatsheets.extensions, ["pdf", "md", "txt"])
        XCTAssertTrue(ConfigLoader.defaultTOML().contains("[cheatsheets]"))
    }
}
