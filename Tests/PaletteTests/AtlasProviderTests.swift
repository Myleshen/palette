import XCTest
@testable import PaletteCore
@testable import PalettePlatform
@testable import PaletteProviders

private actor AtlasBridge: HostBridge {
    private var notes: [String] = []

    func lastNotification() -> String? { notes.last }

    func prompt(kind: PromptKind, title: String, placeholder: String?) async -> String? { nil }

    func notify(_ message: String) async {
        notes.append(message)
    }

    func copyToClipboard(_ text: String, concealed: Bool, clearAfterMs: Int?) async {}
}

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

        // Markdown is previewed as its own source: the generated HTML page renders
        // at a fraction of its size in the pane and is unreadable there.
        guard case .text(let body)? = byTitle["Marked"]?.preview else {
            return XCTFail("Marked should preview its markdown source")
        }
        XCTAssertTrue(body.contains("# Marked"), body)
        // HTML artifacts still use the document renderer.
        XCTAssertEqual(byTitle["Page"]?.preview, .document(url: page.path, kind: "html"))
        guard case .text(let editedBody)? = byTitle["Edited"]?.preview else {
            return XCTFail("Edited should preview its markdown source")
        }
        XCTAssertTrue(editedBody.contains("# Edited"), editedBody)
        guard case .text(let reviewedBody)? = byTitle["Reviewed"]?.preview else {
            return XCTFail("Reviewed should preview its markdown source")
        }
        XCTAssertTrue(reviewedBody.contains("# Reviewed"), reviewedBody)
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
        // Only inbox artifacts (review: true) can be marked reviewed.
        let file = try write("note.md", "---\nreview: true\n---\n# Note\n")
        try writeState([file.path: ["title": "Note", "kind": "artifact"]])
        let provider = AtlasProvider(bridge: nil, stateFile: stateFile, previewDirectory: previewDir, home: home.path)
        let rows = try await provider.search(SearchRequest(text: "", isBound: true))
        let review = try XCTUnwrap(rows.first?.actions.first { $0.id == "review" })
        XCTAssertEqual(review.kind, .custom)
        XCTAssertEqual(review.value.text, "review:\(file.path)")
        XCTAssertEqual(rows.first?.actions.first?.kind, .openPath)
    }

    func testReviewedArtifactsDropTheReviewAction() async throws {
        let file = try write("plain.md", "# Plain\n")
        try writeState([file.path: ["title": "Plain", "kind": "artifact"]])
        let provider = AtlasProvider(bridge: nil, stateFile: stateFile, previewDirectory: previewDir, home: home.path)
        let rows = try await provider.search(SearchRequest(text: "", isBound: true))
        XCTAssertNil(rows.first?.actions.first { $0.id == "review" })
    }

    // MARK: - Tool resolution

    func testReviewResolvesAtlasThroughToolLocator() async throws {
        let file = try write("note.md", "---\nreview: true\n---\n# Note\n")
        try writeState([file.path: ["title": "Note", "kind": "artifact"]])

        // atlas may exist in /opt/homebrew/bin, which ToolLocator probes after
        // PATH, so shadow PATH with the directory holding the fake binary.
        let tools = home.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let log = home.appendingPathComponent("review.log")
        let fake = tools.appendingPathComponent("atlas")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(log.path)'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let originalPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", tools.path, 1)
        ToolLocator.shared.configure(extraPaths: [tools.path])
        defer {
            setenv("PATH", originalPath ?? "/usr/bin:/bin", 1)
            ToolLocator.shared.configure(extraPaths: [])
        }
        XCTAssertEqual(ToolLocator.shared.path(for: "atlas"), fake.path)

        let bridge = AtlasBridge()
        let provider = AtlasProvider(bridge: bridge, stateFile: stateFile, previewDirectory: previewDir, home: home.path)
        let rows = try await provider.search(SearchRequest(text: "", isBound: true))
        let item = try XCTUnwrap(rows.first)
        let review = try XCTUnwrap(item.actions.first { $0.id == "review" })
        try await provider.activate(item, action: review)

        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "review\n\(file.path)\n")
        let note = await bridge.lastNotification()
        XCTAssertEqual(note, "Reviewed Note")
    }

    func testReviewWithoutAtlasNotifies() async throws {
        let file = try write("note.md", "---\nreview: true\n---\n# Note\n")
        try writeState([file.path: ["title": "Note", "kind": "artifact"]])
        let bridge = AtlasBridge()
        // The binary cannot be removed from this machine, so the lookup is
        // stubbed empty instead of relying on atlas being absent.
        let provider = AtlasProvider(
            bridge: bridge,
            stateFile: stateFile,
            previewDirectory: previewDir,
            home: home.path,
            toolPath: { nil }
        )
        let rows = try await provider.search(SearchRequest(text: "", isBound: true))
        let item = try XCTUnwrap(rows.first)
        let review = try XCTUnwrap(item.actions.first { $0.id == "review" })
        do {
            try await provider.activate(item, action: review)
            XCTFail("review should fail without atlas")
        } catch {
            XCTAssertEqual(error as? ProviderError, .toolMissing("atlas"))
        }
        let note = await bridge.lastNotification()
        XCTAssertEqual(note, "atlas is not installed")
    }

    func testSetupRowSaysInstallWhenAtlasIsMissing() async throws {
        let missing = AtlasProvider(
            bridge: nil,
            stateFile: stateFile,
            previewDirectory: previewDir,
            home: home.path,
            toolPath: { nil }
        )
        let missingRow = try await missing.search(SearchRequest(text: "", isBound: true)).first
        XCTAssertEqual(missingRow?.title, "Install atlas")
        XCTAssertEqual(missingRow?.badge, "SETUP")

        let present = AtlasProvider(
            bridge: nil,
            stateFile: stateFile,
            previewDirectory: previewDir,
            home: home.path,
            toolPath: { "/opt/homebrew/bin/atlas" }
        )
        let presentRow = try await present.search(SearchRequest(text: "", isBound: true)).first
        XCTAssertEqual(presentRow?.title, "Atlas state not found — run `atlas`")
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
