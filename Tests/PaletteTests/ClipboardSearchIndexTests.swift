import XCTest
import Foundation
import PaletteCore
import PalettePlatform
@testable import PaletteProviders

private actor ClipboardSearchBridge: HostBridge {
    func prompt(kind: PromptKind, title: String, placeholder: String?) async -> String? { nil }
    func notify(_ message: String) async {}
    func copyToClipboard(_ text: String, concealed: Bool, clearAfterMs: Int?) async {}
}

final class ClipboardSearchIndexTests: XCTestCase {
    private func makeStore() throws -> (PaletteStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-index-\(UUID().uuidString).sqlite")
        return (try PaletteStore(path: url.path), url)
    }

    func testSnapshotPicksUpNewCopiesWithoutARestart() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.insertClipboard(text: "first note", maxEntries: 50)
        let provider = ClipboardProvider(store: store, bridge: ClipboardSearchBridge())
        let before = try await provider.search(SearchRequest(text: "note", limit: 20, isBound: true))
        XCTAssertEqual(before.count, 1)

        _ = try await store.insertClipboard(text: "second note", maxEntries: 50)
        let after = try await provider.search(SearchRequest(text: "note", limit: 20, isBound: true))
        XCTAssertEqual(after.count, 2)
        let fresh = try await provider.search(SearchRequest(text: "second", limit: 20, isBound: true))
        XCTAssertEqual(fresh.first?.title, "second note")
    }

    func testPinnedRowsRankAboveNewerMatches() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.insertClipboard(text: "zebra older", maxEntries: 50)
        let entries = try await store.clipboardEntries(limit: 1)
        let old = try XCTUnwrap(entries.first)
        try await store.setClipboardPinned(id: old.id, pinned: true)
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = try await store.insertClipboard(text: "zebra newer", maxEntries: 50)

        let provider = ClipboardProvider(store: store, bridge: ClipboardSearchBridge())
        let results = try await provider.search(SearchRequest(text: "zebra", limit: 20, isBound: true))
        XCTAssertEqual(results.first?.title, "zebra older")
    }

    /// Pinned keeps its badge and its pinned search boost, but browse order
    /// stays chronological instead of moving it to the top.
    func testPinnedEntryKeepsItsBadgeWithoutForcedPosition() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let base = Date(timeIntervalSince1970: 3_000)

        _ = try await store.insertClipboard(text: "older pinned", maxEntries: 50, at: base)
        let stored = try await store.clipboardEntries(limit: 20)
        let pinnedID = try XCTUnwrap(stored.first { $0.text == "older pinned" }?.id)
        try await store.setClipboardPinned(id: pinnedID, pinned: true)
        _ = try await store.insertClipboard(
            text: "newer plain", maxEntries: 50, at: base.addingTimeInterval(10)
        )

        let provider = ClipboardProvider(store: store, bridge: ClipboardSearchBridge())
        let items = try await provider.search(SearchRequest(text: "", limit: 20, isBound: true))
        XCTAssertEqual(items.map(\.title), ["newer plain", "older pinned"])
        XCTAssertEqual(items[1].badge, "pinned")
        XCTAssertNil(items[0].badge)
    }

    /// A leading kind word is ordinary search text: `/clip images` searches
    /// for "images" instead of switching to an image-only view.
    func testKindWordsAreSearchText() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let base = Date(timeIntervalSince1970: 4_000)

        _ = try await store.insertClipboard(text: "images of cats", maxEntries: 50, at: base)
        _ = try await store.insertClipboard(
            text: "plain note", maxEntries: 50, at: base.addingTimeInterval(1)
        )
        _ = try await store.insertClipboardImage(
            png: Data("filter-image".utf8), thumbnail: nil, width: 6, height: 5,
            maxEntries: 50, at: base.addingTimeInterval(2)
        )
        _ = try await store.insertClipboardFiles(
            paths: ["/tmp/filter.txt"], thumbnail: nil, maxEntries: 50,
            at: base.addingTimeInterval(3)
        )

        let provider = ClipboardProvider(store: store, bridge: ClipboardSearchBridge())
        let images = try await provider.search(SearchRequest(text: "images", limit: 20, isBound: true))
        XCTAssertEqual(images.map(\.title), ["images of cats"])
        let all = try await provider.search(SearchRequest(text: "", limit: 20, isBound: true))
        XCTAssertEqual(all.count, 4)
    }

    func testFoldedScoringMatchesTheUncachedRanking() {
        let query = "zebra"
        let terms = query.split(whereSeparator: \.isWhitespace).map { Ranking.normalize(String($0)) }
        let candidate = "The zebra crossing"
        XCTAssertEqual(
            Ranking.score(foldedTerms: terms, foldedCandidate: Ranking.normalize(candidate)),
            Ranking.score(query: query, candidate: candidate)
        )
    }

    func testSnapshotBuildsOncePerHistoryChange() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let index = ClipboardSearchIndex()
        _ = try await store.insertClipboard(text: "alpha", maxEntries: 50)
        _ = await index.entries(for: store)
        _ = await index.entries(for: store)
        let afterTwoQueries = await index.buildCount
        XCTAssertEqual(afterTwoQueries, 1, "keystrokes reuse the snapshot")

        _ = try await store.insertClipboard(text: "beta", maxEntries: 50)
        _ = await index.entries(for: store)
        let afterCopy = await index.buildCount
        XCTAssertEqual(afterCopy, 2, "a new copy rebuilds the snapshot")
    }

}
