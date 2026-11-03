import XCTest
import Foundation
import PaletteCore
import PalettePlatform
import PaletteProviders

private actor FuzzyBridge: HostBridge {
    func prompt(kind: PromptKind, title: String, placeholder: String?) async -> String? { nil }
    func notify(_ message: String) async {}
    func copyToClipboard(_ text: String, concealed: Bool, clearAfterMs: Int?) async {}
}

final class FuzzySearchTests: XCTestCase {
    private func makeStore() throws -> (PaletteStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-fuzzy-\(UUID().uuidString).sqlite")
        return (try PaletteStore(path: url.path), url)
    }

    func testRankingAcceptsAbbreviationsAndNonContiguousTerms() {
        XCTAssertNotNil(Ranking.score(query: "vsc", candidate: "Visual Studio Code"))
        XCTAssertNotNil(Ranking.score(query: "actmon", candidate: "Activity Monitor"))
        XCTAssertNotNil(Ranking.score(query: "qbf", candidate: "The quick brown fox"))
        XCTAssertNotNil(Ranking.score(query: "ng", candidate: "navigator"))
        XCTAssertNil(Ranking.score(query: "vsc", candidate: "Safari"))
    }

    func testRankingPrefersBoundaryAbbreviations() {
        let boundary = Ranking.score(query: "vsc", candidate: "Visual Studio Code")!
        let scattered = Ranking.score(query: "vsc", candidate: "Vaseline Scented Candle")!
        XCTAssertGreaterThan(boundary, scattered)
    }

    func testClipboardSearchIsFuzzy() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.insertClipboard(text: "The quick brown fox jumps over the lazy dog", maxEntries: 20)
        _ = try await store.insertClipboard(text: "unrelated note", maxEntries: 20)
        _ = try await store.insertClipboardFiles(
            paths: ["/tmp/Quarterly-Budget-Final.xlsx"],
            thumbnail: nil,
            maxEntries: 20
        )

        let provider = ClipboardProvider(store: store, bridge: FuzzyBridge())
        let text = try await provider.search(SearchRequest(text: "qbf", limit: 20, isBound: true))
        XCTAssertEqual(text.first?.title, "The quick brown fox jumps over the lazy dog")
        XCTAssertFalse(text.contains { $0.title == "unrelated note" })

        let files = try await provider.search(SearchRequest(text: "qbf", limit: 20, isBound: true))
        XCTAssertTrue(files.contains { $0.title == "Quarterly-Budget-Final.xlsx" })

        let file = try await provider.search(SearchRequest(text: "qbfinal", limit: 20, isBound: true))
        XCTAssertTrue(file.contains { $0.title == "Quarterly-Budget-Final.xlsx" })
    }

    func testClipboardPrefixFiltersBeforeFuzzySearch() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.insertClipboard(text: "quick brown fox", maxEntries: 20)
        _ = try await store.insertClipboardFiles(paths: ["/tmp/fox.txt"], thumbnail: nil, maxEntries: 20)
        let provider = ClipboardProvider(store: store, bridge: FuzzyBridge())

        let textOnly = try await provider.search(SearchRequest(text: "text fox", limit: 20, isBound: true))
        XCTAssertEqual(textOnly.count, 1)
        XCTAssertEqual(textOnly.first?.title, "quick brown fox")

        let filesOnly = try await provider.search(SearchRequest(text: "files fox", limit: 20, isBound: true))
        XCTAssertEqual(filesOnly.count, 1)
        XCTAssertEqual(filesOnly.first?.title, "fox.txt")
    }

    func testClipboardSearchScansPastTheOldFiveThousandCap() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        // The needle is the oldest row. A 5,000-entry cap would only see the
        // 5,000 newest fillers and never return it.
        _ = try await store.insertClipboard(text: "buried zebra needle", maxEntries: 10_000)
        for index in 0..<5_001 {
            _ = try await store.insertClipboard(text: "filler entry \(index)", maxEntries: 10_000)
        }

        let provider = ClipboardProvider(store: store, bridge: FuzzyBridge())
        let results = try await provider.search(SearchRequest(text: "buried zebra", limit: 20, isBound: true))
        XCTAssertTrue(results.contains { $0.title == "buried zebra needle" })
    }

    func testEmojiAcceptsAbbreviationsWithoutNoise() async throws {
        let provider = EmojiProvider()
        let abbreviations = try await provider.search(SearchRequest(text: "drgn", limit: 20, isBound: true))
        XCTAssertTrue(abbreviations.contains { $0.title.contains("Dragon") })

        let literal = try await provider.search(SearchRequest(text: "dragon", limit: 20, isBound: true))
        XCTAssertTrue(literal.contains { $0.title.contains("Dragon") })
        XCTAssertFalse(literal.contains { $0.title.contains("Triangle") })
    }

    func testAppAbbreviationsRankActivityMonitor() async throws {
        guard FileManager.default.fileExists(atPath: "/System/Applications/Utilities/Activity Monitor.app") else {
            throw XCTSkip("Activity Monitor is not installed")
        }
        let launcher = await MainActor.run { LauncherService() }
        let provider = AppProvider(index: AppIndex(), launcher: launcher)
        let items = try await provider.search(SearchRequest(text: "actmon", limit: 10, isBound: false))
        XCTAssertEqual(items.first?.title, "Activity Monitor")
    }
}
