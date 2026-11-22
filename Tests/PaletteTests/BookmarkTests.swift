import XCTest
@testable import PaletteCore
@testable import PalettePlatform
@testable import PaletteProviders

final class BookmarkTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-bookmarks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLoadParsesBlocks() throws {
        let file = directory.appendingPathComponent("bookmarks.toml")
        try """
        [[bookmark]]
        name = "GitHub"
        url = "https://github.com"
        browser = "Safari"
        keywords = ["code", "repos"]

        [[bookmark]]
        name = "Docs"
        url = "https://example.com/docs"
        """.write(to: file, atomically: true, encoding: .utf8)

        let bookmarks = try BookmarkStore.load(from: file)
        XCTAssertEqual(bookmarks.count, 2)
        XCTAssertEqual(bookmarks[0].name, "GitHub")
        XCTAssertEqual(bookmarks[0].url, "https://github.com")
        XCTAssertEqual(bookmarks[0].browser, "Safari")
        XCTAssertEqual(bookmarks[0].keywords, ["code", "repos"])
        XCTAssertEqual(bookmarks[1].browser, "")
        XCTAssertEqual(bookmarks[1].keywords, [])
    }

    func testRoundTrip() throws {
        let file = directory.appendingPathComponent("nested/bookmarks.toml")
        let original = [
            Bookmark(name: "GitHub", url: "https://github.com", browser: "Firefox", keywords: ["code"]),
            Bookmark(name: "Quoted \"name\"", url: "https://example.com/a?b=1&c=2", browser: ""),
        ]
        try BookmarkStore.save(original, to: file)
        let loaded = try BookmarkStore.load(from: file)
        XCTAssertEqual(loaded.map(\.name), original.map(\.name))
        XCTAssertEqual(loaded.map(\.url), original.map(\.url))
        XCTAssertEqual(loaded.map(\.browser), original.map(\.browser))
        XCTAssertEqual(loaded.map(\.keywords), original.map(\.keywords))
    }

    func testProviderActionOpensNormalWindow() {
        let action = BookmarkProvider.openAction(for: Bookmark(
            name: "GitHub",
            url: "https://github.com",
            browser: "Safari"
        ))
        XCTAssertEqual(action.kind, .openURL)
        XCTAssertEqual(action.value.object?["url"], "https://github.com")
        XCTAssertEqual(action.value.object?["browser"], "Safari")
        // No app mode: a bookmark is a normal browser window, not a web app.
        XCTAssertNil(action.value.object?["mode"])

        let fallback = BookmarkProvider.openAction(for: Bookmark(name: "Docs", url: "https://example.com"))
        XCTAssertNil(fallback.value.object?["browser"])
    }

    func testProviderFiltersGloballyAndListsWhenBound() async throws {
        let file = directory.appendingPathComponent("bookmarks.toml")
        try BookmarkStore.save([
            Bookmark(name: "GitHub", url: "https://github.com", keywords: ["code"]),
            Bookmark(name: "News", url: "https://news.example.com"),
        ], to: file)
        let provider = BookmarkProvider(fileURL: file)

        let bound = try await provider.search(SearchRequest(text: "", isBound: true))
        XCTAssertEqual(bound.map(\.title), ["GitHub", "News"])
        XCTAssertEqual(bound[0].actions.first?.kind, .openURL)

        let filtered = try await provider.search(SearchRequest(text: "code", isBound: false))
        XCTAssertEqual(filtered.map(\.title), ["GitHub"])

        let boundFiltered = try await provider.search(SearchRequest(text: "code", isBound: true))
        XCTAssertEqual(boundFiltered.map(\.title), ["GitHub"])
    }

    func testProviderSetupRowOnlyWhenEmptyAndBound() async throws {
        let provider = BookmarkProvider(fileURL: directory.appendingPathComponent("missing.toml"))
        let global = try await provider.search(SearchRequest(text: "", isBound: false))
        XCTAssertTrue(global.isEmpty)
        let bound = try await provider.search(SearchRequest(text: "", isBound: true))
        XCTAssertEqual(bound.first?.badge, "SETUP")
    }

    func testMissingAndMalformedFilesLoadNothing() throws {
        XCTAssertTrue(try BookmarkStore.load(from: directory.appendingPathComponent("missing.toml")).isEmpty)

        let malformed = directory.appendingPathComponent("malformed.toml")
        try "[[bookmark]\nname = \"Broken\"".write(to: malformed, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try BookmarkStore.load(from: malformed)) { error in
            guard case BookmarkStore.StoreError.malformed = error else {
                return XCTFail("expected a malformed-file error, got \(error)")
            }
        }

        let missingFields = directory.appendingPathComponent("nofields.toml")
        try "[[bookmark]]\nname = \"Only a name\"".write(to: missingFields, atomically: true, encoding: .utf8)
        XCTAssertTrue(try BookmarkStore.load(from: missingFields).isEmpty)
    }

    func testControlCharactersRoundTrip() throws {
        let file = directory.appendingPathComponent("bookmarks.toml")
        let original = [
            Bookmark(
                name: "Line\rBreak",
                url: "https://example.com",
                keywords: ["a\rb", "tab\there"]
            ),
        ]
        try BookmarkStore.save(original, to: file)
        let loaded = try BookmarkStore.load(from: file)
        XCTAssertEqual(loaded.map(\.name), original.map(\.name))
        XCTAssertEqual(loaded.map(\.keywords), original.map(\.keywords))
    }

    func testCorruptFileIsPreservedAndReported() throws {
        let file = directory.appendingPathComponent("bookmarks.toml")
        let corrupt = "[[bookmark]\nname = \"Broken\""
        try corrupt.write(to: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try BookmarkStore.load(from: file))

        try BookmarkStore.save([Bookmark(name: "New", url: "https://new.example.com")], to: file)
        let backup = try String(contentsOf: file.appendingPathExtension("bak"), encoding: .utf8)
        XCTAssertEqual(backup, corrupt, "the unparseable file survives in bookmarks.toml.bak")
    }
}
