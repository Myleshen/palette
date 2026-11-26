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

    /// The browser is one flat list: newest capture first, whatever its kind.
    func testBrowseInterleavesKindsInCreationOrder() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let base = Date(timeIntervalSince1970: 1_000)

        _ = try await store.insertClipboard(text: "older text", maxEntries: 50, at: base)
        _ = try await store.insertClipboardImage(
            png: Data("interleaved-image".utf8), thumbnail: nil, width: 2, height: 2,
            maxEntries: 50, at: base.addingTimeInterval(1)
        )
        _ = try await store.insertClipboardFiles(
            paths: ["/tmp/report.pdf"], thumbnail: nil, maxEntries: 50,
            at: base.addingTimeInterval(2)
        )
        _ = try await store.insertClipboard(
            text: "newest text", maxEntries: 50, at: base.addingTimeInterval(3)
        )

        let provider = ClipboardProvider(store: store, bridge: ClipboardSearchBridge())
        let items = try await provider.search(SearchRequest(text: "", limit: 20, isBound: true))
        XCTAssertEqual(items.map(\.title), ["newest text", "report.pdf", "Image 2×2", "older text"])
        XCTAssertTrue(items.allSatisfy { $0.group == nil }, "the browser is not grouped")
    }

    /// A thumbnail file can be missing after a cache sweep or a restored
    /// database; the row must still be listed, with a placeholder icon.
    func testMissingThumbnailRowsStillAppearInTheBrowser() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let base = Date(timeIntervalSince1970: 2_000)

        _ = try await store.insertClipboardImage(
            png: Data("thumbless-image".utf8), thumbnail: nil, width: 4, height: 3,
            maxEntries: 50, at: base
        )
        _ = try await store.insertClipboardFiles(
            paths: ["/tmp/thumbless.txt"], thumbnail: nil, maxEntries: 50,
            at: base.addingTimeInterval(1)
        )

        let provider = ClipboardProvider(store: store, bridge: ClipboardSearchBridge())
        let items = try await provider.search(SearchRequest(text: "", limit: 20, isBound: true))
        XCTAssertEqual(items.map(\.title), ["thumbless.txt", "Image 4×3"])
        XCTAssertEqual(items.first?.icon, .symbol("doc"))
        XCTAssertEqual(items.last?.icon, .symbol("photo"))
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

    /// Before: every keystroke re-read 5k rows and re-folded each candidate.
    /// After: one snapshot, folded once, scored in memory; only the rows shown
    /// are fetched. The fuzzy scorer itself is unchanged and dominates the
    /// remaining time, so the gap is widest on short clips where the fetch and
    /// fold are the whole per-keystroke cost.
    func testCachedSnapshotIsFasterThanAPerKeystrokeScanAtFiveThousandEntries() async throws {
        let short = try await measurePerKeystroke(body: "the quick brown fox", label: "short")
        XCTAssertLessThan(short.after, short.before, "short clips: cached snapshot beats a full re-scan")
        // Long clips are dominated by the fuzzy scorer itself (unchanged by
        // this cache); the numbers are printed as evidence, not asserted.
        _ = try await measurePerKeystroke(
            body: String(repeating: "the quick brown fox jumps over the lazy dog ", count: 40),
            label: "paragraph"
        )
    }

    private func measurePerKeystroke(
        body: String,
        label: String
    ) async throws -> (before: Double, after: Double) {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        for index in 0..<5_000 {
            _ = try await store.insertClipboard(text: "note \(index) \(body)", maxEntries: 10_000)
        }
        let provider = ClipboardProvider(store: store, bridge: ClipboardSearchBridge())
        // Unique rows: a keystroke matches a handful, like real typing, and a
        // mix of queries keeps one query from warming a cache of its own.
        let queries = (0..<10).map { "note \($0 * 431)" }

        // Warm the snapshot: its build is the one-off cost this change pays
        // instead of every keystroke.
        _ = try await provider.search(SearchRequest(text: queries[0], limit: 20, isBound: true))

        var newTotal: UInt64 = 0
        for query in queries {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await provider.search(SearchRequest(text: query, limit: 20, isBound: true))
            newTotal += DispatchTime.now().uptimeNanoseconds - start
        }

        var legacyTotal: UInt64 = 0
        for query in queries {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await Self.legacyKeystroke(store: store, query: query)
            legacyTotal += DispatchTime.now().uptimeNanoseconds - start
        }

        let count = Double(queries.count)
        let after = Double(newTotal) / count / 1_000_000
        let before = Double(legacyTotal) / count / 1_000_000
        print(String(
            format: "clipboard search @5k %@ (%d chars): before %.2f ms, after %.2f ms per keystroke",
            label, body.count, before, after
        ))
        return (before, after)
    }

    /// The shape of the replaced search path: fetch the whole history, fold and
    /// score every candidate, then sort the matches.
    private static func legacyKeystroke(store: PaletteStore, query: String) async throws -> Int {
        let total = try await store.clipboardCount()
        let entries = try await store.clipboardEntries(limit: max(20, total), includeThumbnails: false)
        var matches: [(score: Double, createdAt: Date)] = []
        for entry in entries {
            let candidate: String
            switch entry.kind {
            case .text, .files: candidate = String(entry.text.prefix(4_000))
            case .image: candidate = "Image \(entry.imageWidth)×\(entry.imageHeight) PNG image"
            }
            if let score = Ranking.score(query: query, candidate: candidate) {
                matches.append((score + (entry.pinned ? 25 : 0), entry.createdAt))
            }
        }
        matches.sort { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.0001 { return lhs.score > rhs.score }
            return lhs.createdAt > rhs.createdAt
        }
        return min(20, matches.count)
    }
}
