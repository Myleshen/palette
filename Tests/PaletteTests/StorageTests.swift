import XCTest
import AppKit
import Foundation
import PaletteCore
import PalettePlatform
import PaletteProviders

private actor SilentBridge: HostBridge {
    func prompt(kind: PromptKind, title: String, placeholder: String?) async -> String? { nil }
    func notify(_ message: String) async {}
    func copyToClipboard(_ text: String, concealed: Bool, clearAfterMs: Int?) async {}
}

final class StorageTests: XCTestCase {
    private func makeStore() throws -> (PaletteStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("palette.sqlite")
        let store = try PaletteStore(
            path: url.path,
            imagesDirectory: root.appendingPathComponent("clipboard")
        )
        return (store, root)
    }

    func testFrecencyAndMetadata() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try await store.recordUse(stableID: "apps:/Applications/Zed.app", provider: "apps")
        try await store.recordUse(stableID: "apps:/Applications/Zed.app", provider: "apps")
        let boosts = try await store.frecencyBoosts(for: ["apps:/Applications/Zed.app"])
        XCTAssertNotNil(boosts["apps:/Applications/Zed.app"])
        XCTAssertGreaterThan(boosts["apps:/Applications/Zed.app"] ?? 0, 0)

        try await store.setMeta("theme.override", value: "nord")
        let saved = try await store.metaValue("theme.override")
        XCTAssertEqual(saved, "nord")
        try await store.setMeta("theme.override", value: nil)
        let cleared = try await store.metaValue("theme.override")
        XCTAssertNil(cleared)
    }

    func testClipboardDedupeAndLimit() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try await store.insertClipboard(text: "one", maxEntries: 10)
        XCTAssertTrue(first)
        let duplicate = try await store.insertClipboard(text: "one", maxEntries: 10)
        XCTAssertFalse(duplicate)
        let second = try await store.insertClipboard(text: "two", maxEntries: 10)
        XCTAssertTrue(second)
        let entries = try await store.clipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.text, "two")

        let count = try await store.clipboardCount()
        XCTAssertEqual(count, 2)
        try await store.clearClipboard()
        let cleared = try await store.clipboardCount()
        XCTAssertEqual(cleared, 0)
    }

    func testPinnedClipboardRowsDoNotConsumeTheUnpinnedBudget() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        for index in 0..<3 {
            _ = try await store.insertClipboard(
                text: "pinned \(index)",
                maxEntries: 2,
                at: Date(timeIntervalSince1970: Double(index))
            )
            let entries = try await store.clipboardEntries(limit: 10)
            let id = try XCTUnwrap(entries.first { $0.text == "pinned \(index)" }?.id)
            try await store.setClipboardPinned(id: id, pinned: true)
        }
        for index in 0..<4 {
            _ = try await store.insertClipboard(
                text: "copy \(index)",
                maxEntries: 2,
                at: Date(timeIntervalSince1970: 100 + Double(index))
            )
        }

        let entries = try await store.clipboardEntries(limit: 10)
        XCTAssertEqual(entries.filter(\.pinned).count, 3)
        XCTAssertEqual(entries.filter { !$0.pinned }.map(\.text), ["copy 3", "copy 2"])
    }

    /// The store writes bytes it is given: no decode, no re-read. These bytes
    /// are not a PNG, so any decode here would reject the copy.
    func testPaletteCopyUsesPrebuiltBytesAndThumbnailWithoutDecoding() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("not-a-png".utf8)
        let thumbnail = Data("prebuilt-thumb".utf8)
        let copy = PaletteClipboardCopy.image(PaletteClipboardImage(
            png: bytes,
            thumbnail: thumbnail,
            width: 320,
            height: 200
        ))

        let inserted = try await store.insertPaletteCopy(copy, maxImages: 5, maxFiles: 5)
        XCTAssertTrue(inserted)
        let entries = try await store.clipboardEntries(limit: 10)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.imageWidth, 320)
        XCTAssertEqual(entry.imageHeight, 200)
        XCTAssertEqual(entry.thumbnailPNG, thumbnail)
        let loaded = try await store.clipboardImage(id: entry.id)
        XCTAssertEqual(loaded, bytes)

        let duplicate = try await store.insertPaletteCopy(copy, maxImages: 5, maxFiles: 5)
        XCTAssertFalse(duplicate, "dedupe stays by hash of the bytes")
        let count = try await store.clipboardCount()
        XCTAssertEqual(count, 1)
    }

    /// A recording row is a path list plus a thumbnail. The path does not
    /// exist, so a store that reads the file would fail or log a miss.
    func testPaletteFileCopyDoesNotReadTheFile() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let missing = "/tmp/palette-missing-recording-\(UUID().uuidString).mov"
        let thumbnail = Data("movie-icon".utf8)
        let copy = PaletteClipboardCopy.files([missing], thumbnail: thumbnail)

        let inserted = try await store.insertPaletteCopy(copy, maxImages: 5, maxFiles: 5)
        XCTAssertTrue(inserted)
        let files = try await store.clipboardEntries(limit: 10, kind: .files)
        let entry = try XCTUnwrap(files.first)
        XCTAssertEqual(entry.paths, [missing])
        XCTAssertEqual(entry.thumbnailPNG, thumbnail)
        let duplicate = try await store.insertPaletteCopy(copy, maxImages: 5, maxFiles: 5)
        XCTAssertFalse(duplicate)
    }

    func testPreparedCopyFillsSizeAndThumbnailOnce() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        guard case .image(let filled) = PaletteClipboardCopy.image(
            PaletteClipboardImage(png: png)
        ).prepared() else { return XCTFail("expected an image copy") }
        XCTAssertEqual(filled.width, 8)
        XCTAssertEqual(filled.height, 4)
        XCTAssertNotNil(filled.thumbnail)

        // Supplied values survive; preparing again must not redraw anything.
        let kept = PaletteClipboardCopy.image(PaletteClipboardImage(
            png: png,
            thumbnail: Data("keep".utf8),
            width: 1,
            height: 2
        )).prepared()
        guard case .image(let untouched) = kept else { return XCTFail("expected an image copy") }
        XCTAssertEqual(untouched.thumbnail, Data("keep".utf8))
        XCTAssertEqual(untouched.width, 1)
        XCTAssertEqual(untouched.height, 2)
    }

    func testClipboardFilesAndKindFilter() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let paths = ["/tmp/palette-one.txt", "/tmp/palette-two.png"]
        let thumbnail = Data("icon".utf8)
        let first = try await store.insertClipboardFiles(paths: paths, thumbnail: thumbnail, maxEntries: 10)
        XCTAssertTrue(first)
        let duplicate = try await store.insertClipboardFiles(paths: paths, thumbnail: thumbnail, maxEntries: 10)
        XCTAssertFalse(duplicate)
        _ = try await store.insertClipboard(text: "hello", maxEntries: 10)

        let files = try await store.clipboardEntries(limit: 10, kind: .files)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.kind, .files)
        XCTAssertEqual(files.first?.paths, paths)
        XCTAssertEqual(files.first?.thumbnailPNG, thumbnail)
        let texts = try await store.clipboardEntries(limit: 10, kind: .text)
        XCTAssertEqual(texts.count, 1)
        XCTAssertEqual(texts.first?.text, "hello")
    }

    func testPinnedItemsRoundTrip() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let item = PaletteItem(
            id: "/Applications/Safari.app",
            title: "Safari",
            subtitle: "com.apple.Safari",
            icon: .symbol("safari"),
            badge: "app",
            score: 12,
            actions: [
                PaletteAction(id: "open", title: "Open", kind: .openPath, value: .text("/Applications/Safari.app")),
                PaletteAction(id: "copy-id", title: "Copy Bundle ID", kind: .copyText, value: .text("com.apple.Safari")),
            ],
            providerID: "apps",
            providerName: "Applications"
        )
        try await store.pinItem(item)
        try await store.pinItem(item)
        let pinned = try await store.pinnedItems()
        XCTAssertEqual(pinned.count, 1)
        XCTAssertEqual(pinned.first?.stableID, "apps:/Applications/Safari.app")
        XCTAssertEqual(pinned.first?.actions.count, 2)

        try await store.unpinItem(id: item.stableID)
        let empty = try await store.pinnedItems()
        XCTAssertTrue(empty.isEmpty)
    }

    func testAskHistoryTrimsAndDeletes() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.insertAsk(
            question: "one", answer: "first", model: "glm", provider: "opencode-go",
            durationMs: 10, maxHistory: 2, retentionDays: 30
        )
        _ = try await store.insertAsk(
            question: "two", answer: "second", model: "glm", provider: "opencode-go",
            durationMs: 20, maxHistory: 2, retentionDays: 30
        )
        _ = try await store.insertAsk(
            question: "three", answer: "third", model: "gpt-4o-mini", provider: "openai",
            durationMs: 30, promptTokens: 4, completionTokens: 5, maxHistory: 2, retentionDays: 30
        )
        var records = try await store.askHistory(limit: 10)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.question, "three")
        XCTAssertEqual(records.first?.promptTokens, 4)

        let old = Date(timeIntervalSinceNow: -40 * 24 * 60 * 60)
        _ = try await store.insertAsk(
            question: "old", answer: "expired", model: "glm", provider: "opencode-go",
            durationMs: 1, maxHistory: 10, retentionDays: 30, at: old
        )
        records = try await store.askHistory(limit: 10)
        XCTAssertFalse(records.contains { $0.question == "old" })

        try await store.deleteAsk(id: records[0].id)
        let after = try await store.askHistory(limit: 10)
        XCTAssertEqual(after.count, 1)
    }

    func testUseCountsForFrequentOrdering() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        for _ in 0..<3 { try await store.recordUse(stableID: "apps:Zed", provider: "apps") }
        try await store.recordUse(stableID: "apps:Safari", provider: "apps")
        let counts = try await store.useCounts(for: ["apps:Zed", "apps:Safari", "apps:Missing"])
        XCTAssertEqual(counts["apps:Zed"], 3)
        XCTAssertEqual(counts["apps:Safari"], 1)
        XCTAssertNil(counts["apps:Missing"])
    }

    func testLearnedRankingCapsPrunesAndForgets() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let hash = QueryMemory.digest("chr")
        // The most picked row survives the four-row cap; the rest are pruned.
        for _ in 0..<3 {
            try await store.recordLearnedChoice(prefixHash: hash, itemKey: "apps:keeper")
        }
        for index in 0..<5 {
            try await store.recordLearnedChoice(prefixHash: hash, itemKey: "apps:item\(index)")
        }
        let boosts = try await store.learnedBoosts(
            prefixHash: hash,
            itemKeys: ["apps:keeper"] + (0..<5).map { "apps:item\($0)" }
        )
        XCTAssertEqual(boosts.count, 4)
        XCTAssertNotNil(boosts["apps:keeper"])
        XCTAssertGreaterThan(boosts["apps:keeper"]!, boosts.values.min()!)

        // A different prefix sees none of it.
        let other = try await store.learnedBoosts(prefixHash: QueryMemory.digest("xyz"), itemKeys: ["apps:keeper"])
        XCTAssertTrue(other.isEmpty)

        try await store.clearLearnedRanking()
        let afterClear = try await store.learnedRankingCount()
        XCTAssertEqual(afterClear, 0)
        let clearedBoosts = try await store.learnedBoosts(prefixHash: hash, itemKeys: ["apps:keeper"])
        XCTAssertTrue(clearedBoosts.isEmpty)

        // 401 prefixes: the least recently used one falls off.
        var firstHash = ""
        for index in 0...400 {
            let prefixHash = QueryMemory.digest("q\(index)")
            if index == 0 { firstHash = prefixHash }
            try await store.recordLearnedChoice(
                prefixHash: prefixHash,
                itemKey: "apps:item",
                at: Date(timeIntervalSince1970: 1_000 + Double(index))
            )
        }
        let prunedCount = try await store.learnedRankingCount()
        XCTAssertEqual(prunedCount, 400)
        let oldest = try await store.learnedBoosts(prefixHash: firstHash, itemKeys: ["apps:item"])
        XCTAssertTrue(oldest.isEmpty)
        let newest = try await store.learnedBoosts(
            prefixHash: QueryMemory.digest("q400"),
            itemKeys: ["apps:item"]
        )
        XCTAssertFalse(newest.isEmpty)
    }

    func testScratchNotesAndRecentUses() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try await store.saveScratchNote(title: "", text: "First line\nbody")
        XCTAssertEqual(first.title, "First line")
        let updated = try await store.saveScratchNote(id: first.id, title: "Renamed", text: "changed")
        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(updated.title, "Renamed")
        let notes = try await store.scratchNotes()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.text, "changed")

        try await store.recordUse(stableID: "neo:/tmp/a", provider: "neo")
        try await store.recordUse(stableID: "proj:proj:/tmp/b", provider: "proj")
        let recent = try await store.recentUses(providers: ["neo", "proj"], limit: 10)
        XCTAssertEqual(recent.count, 2)
        XCTAssertTrue(recent.contains { $0.itemID == "/tmp/a" })
        XCTAssertTrue(recent.contains { $0.itemID == "proj:/tmp/b" })

        try await store.deleteScratchNote(id: first.id)
        let after = try await store.scratchNotes()
        XCTAssertTrue(after.isEmpty)
    }

    func testScratchpadAndRecentProviders() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let launcher = await MainActor.run { LauncherService() }
        let scratch = ScratchpadProvider(store: store, bridge: SilentBridge())
        _ = try await store.saveScratchNote(title: "Build notes", text: "gradle build")
        let scratchRows = try await scratch.search(SearchRequest(text: "", limit: 20, isBound: true))
        XCTAssertTrue(scratchRows.contains { $0.title == "New Scratch Note" })
        XCTAssertTrue(scratchRows.contains { $0.title == "Build notes" })
        let matched = try await scratch.search(SearchRequest(text: "gradle", limit: 20, isBound: true))
        XCTAssertTrue(matched.contains { $0.title == "Build notes" })

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("palette-recent-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: file) }
        try "let x = 1".write(to: file, atomically: true, encoding: .utf8)
        try await store.recordUse(stableID: "neo:\(file.path)", provider: "neo")
        let recent = RecentProvider(store: store, launcher: launcher, editor: "neovide")
        let rows = try await recent.search(SearchRequest(text: "", limit: 20, isBound: true))
        XCTAssertTrue(rows.contains { $0.title == file.lastPathComponent })
        XCTAssertTrue(rows.first?.preview != nil)
    }
}
