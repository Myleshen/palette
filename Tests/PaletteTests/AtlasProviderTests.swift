import XCTest
@testable import PaletteCore
@testable import PaletteProviders

final class AtlasProviderTests: XCTestCase {
    private var home: URL!
    private var stateFile: URL!
    private var previewDir: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-atlas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        stateFile = home.appendingPathComponent(".config/atlas/state.json")
        previewDir = home.appendingPathComponent(".cache/atlas/preview", isDirectory: true)
        try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Atlas compatibility

    func testFrontMatterAndMarkerMatchAtlas() {
        // Expected values come from atlas's own strip_front_matter/has_marker.
        let cases: [(String, Bool, String)] = [
            ("---\nreview: true\n---\n# Title\n\nBody\n", true, "# Title\n\nBody"),
            ("---\nreview: false\n---\n# T\n", false, "# T"),
            ("---\nreview: 1\n...\nbody\n", true, "body"),
            ("---\nreview: \"yes\"\n---\nbody\n", true, "body"),
            ("# T\n---\nreview: true\n---\n", false, "# T\n---\nreview: true\n---\n"),
            ("# Title\n\nreview: true\n", false, "# Title\n\nreview: true\n"),
            // CRLF closing fences do not match atlas's `^---[ \t]*$`.
            ("---\r\nreview: 1\r\n---\r\nbody\r\n", false, "body"),
        ]
        for (text, marked, stripped) in cases {
            XCTAssertEqual(AtlasProvider.hasMarker(text, isMarkdown: true), marked, text)
            XCTAssertEqual(AtlasProvider.stripFrontMatter(text), stripped, text)
        }

        XCTAssertTrue(AtlasProvider.hasMarker("<p>a</p>\n<meta name=\"atlas-review\" content=\"1\">\n", isMarkdown: false))
        XCTAssertTrue(AtlasProvider.hasMarker("<meta content=\"1\" name=\"ATLAS-REVIEW\">", isMarkdown: false))
        XCTAssertTrue(AtlasProvider.hasMarker("<meta name='atlas-review' content='x'>", isMarkdown: false))
        XCTAssertFalse(AtlasProvider.hasMarker("<meta name=\"other\" content=\"1\">", isMarkdown: false))
    }

    func testPreviewDigestMatchesAtlasRecipe() {
        XCTAssertEqual(AtlasProvider.previewDigest(path: "/tmp/a.md", text: "hello"), "0f13fb1db42251c7")
        XCTAssertEqual(
            AtlasProvider.previewDigest(
                path: "/Users/myleshen/dev/x.md",
                text: "---\nreview: true\n---\n# T\n"
            ),
            "d9c52868b021274b"
        )
    }

    // MARK: - Rows

    func testRowsPreviewAndInboxRule() async throws {
        let marked = try write("marked.md", "---\nreview: true\n---\n# Marked\n")
        let edited = try write("edited.md", "# Edited\n")
        let reviewed = try write("reviewed.md", "# Reviewed\n")
        let page = try write("page.html", "<meta name=\"atlas-review\" content=\"1\">")
        let doc = try write("README.md", "# Readme\n")

        // Atlas queues only files that carry the marker; acked files have it
        // stripped, so `reviewed` and `edited` stay out of the inbox.
        try writeState([
            marked.path: ["title": "Marked", "kind": "artifact"],
            edited.path: ["title": "Edited", "kind": "artifact"],
            reviewed.path: ["title": "Reviewed", "kind": "artifact"],
            page.path: ["title": "Page", "kind": "artifact"],
            doc.path: ["title": "Readme", "kind": "doc"],
        ])
        // Atlas writes a wrapped GitHub-rendered preview next to the digest hash.
        try writePreview(for: marked)
        try writePreview(for: reviewed)

        let provider = AtlasProvider(bridge: nil, stateFile: stateFile, previewDirectory: previewDir, home: home.path)
        let rows = try await provider.search(SearchRequest(text: "", isBound: true))
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(Set(rows.map(\.id)), [marked.path, edited.path, reviewed.path, page.path, doc.path])
        let byTitle = Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0) })

        // Inbox: only the two files that still carry the marker.
        XCTAssertEqual(byTitle["Marked"]?.badge, "review")
        XCTAssertEqual(byTitle["Page"]?.badge, "review")
        // Acked files and repo docs are not in the inbox.
        XCTAssertNil(byTitle["Edited"]?.badge)
        XCTAssertNil(byTitle["Reviewed"]?.badge)
        XCTAssertNil(byTitle["Readme"]?.badge)
        // Inbox rows sort first.
        XCTAssertEqual(rows.prefix(2).compactMap(\.badge), ["review", "review"])

        XCTAssertEqual(byTitle["Marked"]?.subtitle, "proj · proj/marked.md")
        XCTAssertEqual(byTitle["Marked"]?.group, "proj")
        XCTAssertEqual(byTitle["Marked"]?.icon, .file(marked.path))

        // .md with a rendered preview and .html use the document renderer;
        // a .md without one falls back to QuickLook on the file itself.
        guard case .document(let url, let kind)? = byTitle["Marked"]?.preview else {
            return XCTFail("Marked should preview its atlas HTML")
        }
        XCTAssertEqual(url, previewPath(for: marked))
        XCTAssertEqual(kind, "html")
        XCTAssertEqual(byTitle["Page"]?.preview, .document(url: page.path, kind: "html"))
        XCTAssertEqual(byTitle["Edited"]?.preview, .files(paths: [edited.path]))
        XCTAssertEqual(byTitle["Reviewed"]?.preview, .document(url: previewPath(for: reviewed), kind: "html"))
    }

    func testSearchRanksAndFilters() async throws {
        let goroutines = try write("goroutines.md", "# Goroutines\n", in: "learning/go")
        let rust = try write("ownership.md", "# Ownership\n", in: "learning/go")
        try writeState([
            goroutines.path: ["title": "Goroutines", "summary": "channels and scheduling", "kind": "artifact"],
            rust.path: ["title": "Ownership", "summary": "borrow checker", "kind": "artifact"],
        ])
        let provider = AtlasProvider(bridge: nil, stateFile: stateFile, previewDirectory: previewDir, home: home.path)

        let filtered = try await provider.search(SearchRequest(text: "borrow", isBound: false))
        XCTAssertEqual(filtered.map(\.title), ["Ownership"])
        let bound = try await provider.search(SearchRequest(text: "borrow", isBound: true))
        XCTAssertEqual(bound.map(\.title), ["Ownership"])
        let byPath = try await provider.search(SearchRequest(text: "go/goroutines", isBound: false))
        XCTAssertEqual(byPath.map(\.title), ["Goroutines"])
        XCTAssertEqual(byPath.first?.subtitle, "go · go/goroutines.md")
        let none = try await provider.search(SearchRequest(text: "nomatch", isBound: false))
        XCTAssertTrue(none.isEmpty)
    }

    func testSetupRowOnlyWhenBound() async throws {
        let provider = AtlasProvider(bridge: nil, stateFile: stateFile, previewDirectory: previewDir, home: home.path)
        let global = try await provider.search(SearchRequest(text: "", isBound: false))
        XCTAssertTrue(global.isEmpty)
        let bound = try await provider.search(SearchRequest(text: "", isBound: true))
        XCTAssertEqual(bound.first?.badge, "SETUP")
        XCTAssertEqual(bound.first?.id, "atlas:setup")
    }

    func testReviewActionValue() async throws {
        let file = try write("note.md", "# Note\n")
        try writeState([file.path: ["title": "Note", "kind": "artifact"]])
        let provider = AtlasProvider(bridge: nil, stateFile: stateFile, previewDirectory: previewDir, home: home.path)
        let rows = try await provider.search(SearchRequest(text: "", isBound: true))
        let review = try XCTUnwrap(rows.first?.actions.first { $0.id == "review" })
        XCTAssertEqual(review.kind, .custom)
        XCTAssertEqual(review.value.text, "review:\(file.path)")
        XCTAssertEqual(rows.first?.actions.first?.kind, .openPath)
    }

    // MARK: - Fixtures

    /// The state key is the real, absolute path atlas would store.
    private func write(_ name: String, _ contents: String, in subdir: String = "dev/proj") throws -> URL {
        let url = home.appendingPathComponent("\(subdir)/\(name)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return URL(fileURLWithPath: (url.path as NSString).standardizingPath)
    }

    private func previewPath(for url: URL) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return previewDir.appendingPathComponent(AtlasProvider.previewDigest(path: url.path, text: text) + ".html").path
    }

    private func writePreview(for url: URL) throws {
        try "<p>rendered</p>".write(to: URL(fileURLWithPath: previewPath(for: url)), atomically: true, encoding: .utf8)
    }

    private func writeState(_ files: [String: [String: Any]]) throws {
        try FileManager.default.createDirectory(
            at: stateFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: ["version": 2, "files": files])
        try data.write(to: stateFile)
    }
}
