import XCTest
import Foundation
import PaletteCore
import PalettePlatform

final class StorageTests: XCTestCase {
    private func makeStore() throws -> (PaletteStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("palette-store-\(UUID().uuidString).sqlite")
        let store = try PaletteStore(path: url.path)
        return (store, url)
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

    func testClipboardImages() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let image = Data("not-a-real-png-but-stored-as-blob".utf8)
        let thumbnail = Data("thumb".utf8)
        let first = try await store.insertClipboardImage(
            png: image, thumbnail: thumbnail, width: 320, height: 200, maxEntries: 10
        )
        XCTAssertTrue(first)
        let duplicate = try await store.insertClipboardImage(
            png: image, thumbnail: thumbnail, width: 320, height: 200, maxEntries: 10
        )
        XCTAssertFalse(duplicate)

        let entries = try await store.clipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.kind, .image)
        XCTAssertEqual(entries.first?.imageWidth, 320)
        XCTAssertEqual(entries.first?.imageHeight, 200)
        XCTAssertEqual(entries.first?.thumbnailPNG, thumbnail)
        let loaded = try await store.clipboardImage(id: entries[0].id)
        XCTAssertEqual(loaded, image)

        let withoutThumbnails = try await store.clipboardEntries(limit: 10, includeThumbnails: false)
        XCTAssertNil(withoutThumbnails.first?.thumbnailPNG)
        let fetchedThumbnail = try await store.clipboardThumbnail(id: entries[0].id)
        XCTAssertEqual(fetchedThumbnail, thumbnail)
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
}
