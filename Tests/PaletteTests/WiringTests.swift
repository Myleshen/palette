import AppKit
import XCTest
import Foundation
import PaletteCore
import PalettePlatform
import PaletteProviders

/// Store-level wiring: the real `PaletteStore` APIs and a fake `HostBridge`, so
/// the tests exercise the paths the app actually calls instead of pure helpers.
final class WiringTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let store: PaletteStore

        var databasePath: String { root.appendingPathComponent("palette.sqlite").path }
        var imagesDir: URL { root.appendingPathComponent("clipboard/images", isDirectory: true) }
        var thumbsDir: URL { root.appendingPathComponent("clipboard/thumbs", isDirectory: true) }
    }

    /// Records what the host would show or copy. When a store is attached it
    /// also records copied text the way `SearchController.copyToClipboard` does.
    private actor RecordingBridge: HostBridge {
        private let store: PaletteStore?
        private(set) var copied: [String] = []
        private(set) var notifications: [String] = []

        init(store: PaletteStore? = nil) {
            self.store = store
        }

        func prompt(kind: PromptKind, title: String, placeholder: String?) async -> String? { nil }

        func notify(_ message: String) async {
            notifications.append(message)
        }

        func copyToClipboard(_ text: String, concealed: Bool, clearAfterMs: Int?) async {
            copied.append(text)
            guard !concealed,
                  let store,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            _ = try? await store.insertClipboard(text: text, maxEntries: 100)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try PaletteStore(
            path: root.appendingPathComponent("palette.sqlite").path,
            imagesDirectory: root.appendingPathComponent("clipboard", isDirectory: true)
        )
        return Fixture(root: root, store: store)
    }

    private func files(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return enumerator.compactMap { element in
            guard let url = element as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                return nil
            }
            return url
        }
    }

    private func sqlite(_ database: String, _ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database, sql]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )
            throw NSError(
                domain: "WiringTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message ?? "sqlite3 failed"]
            )
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func count(_ fixture: Fixture, _ sql: String) throws -> Int {
        let value = try sqlite(fixture.databasePath, sql)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(value) ?? -1
    }

    /// A bitmap-backed PNG keeps the pixel size exact; `lockFocus` would double
    /// it on a 2x display. Text is drawn large so Vision reads it reliably.
    @MainActor
    private func imagePNG(width: Int = 480, height: Int = 160, text: String?) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        if let text {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            (text as NSString).draw(
                in: NSRect(x: 0, y: 20, width: width, height: height - 40),
                withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 96),
                    .foregroundColor: NSColor.black,
                    .paragraphStyle: paragraph,
                ]
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    // MARK: - Palette copy callback

    @MainActor
    func testPaletteCopyCallbackRecordsOneImageRowAndFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let png = try imagePNG(text: nil)

        let first = try await fixture.store.insertPaletteCopy(
            .image(png), maxImages: 10, maxFiles: 10
        )
        XCTAssertTrue(first)
        XCTAssertEqual(try count(fixture, "SELECT COUNT(*) FROM clipboard_images;"), 1)
        XCTAssertEqual(files(in: fixture.imagesDir).count, 1)
        XCTAssertEqual(files(in: fixture.thumbsDir).count, 1)

        let second = try await fixture.store.insertPaletteCopy(
            .image(png), maxImages: 10, maxFiles: 10
        )
        XCTAssertFalse(second, "an identical copy must not add a row")
        XCTAssertEqual(try count(fixture, "SELECT COUNT(*) FROM clipboard_images;"), 1)
        XCTAssertEqual(files(in: fixture.imagesDir).count, 1)
        XCTAssertEqual(files(in: fixture.thumbsDir).count, 1)
        let entries = try await fixture.store.clipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
    }

    // MARK: - OCR action

    @MainActor
    func testOCRCopyPutsRecognizedTextOnTheBridgeAndInHistory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let png = try imagePNG(text: "HELLO")
        _ = try await fixture.store.insertClipboardImage(
            png: png, thumbnail: nil, width: 480, height: 160, maxEntries: 10
        )
        let stored = try await fixture.store.clipboardEntries(limit: 1)
        let entry = try XCTUnwrap(stored.first)

        let bridge = RecordingBridge(store: fixture.store)
        let provider = ClipboardProvider(store: fixture.store, bridge: bridge)
        try await provider.activate(
            PaletteItem(id: entry.id, title: "Image", providerID: "clip"),
            action: PaletteAction(
                id: "ocr-copy", title: "Copy Text (OCR)", kind: .custom, value: .text(entry.id)
            )
        )

        let copiedValues = await bridge.copied
        let copied = try XCTUnwrap(copiedValues.first)
        XCTAssertTrue(
            copied.uppercased().contains("HELLO"),
            "Vision read \(copied.debugDescription) instead of HELLO"
        )
        let texts = try await fixture.store.clipboardEntries(limit: 10, kind: .text)
        XCTAssertEqual(texts.count, 1)
        XCTAssertTrue(texts.first?.text.uppercased().contains("HELLO") == true)
    }

    @MainActor
    func testOCRCopyOnABlankImageReportsNoText() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let png = try imagePNG(text: nil)
        _ = try await fixture.store.insertClipboardImage(
            png: png, thumbnail: nil, width: 480, height: 160, maxEntries: 10
        )
        let stored = try await fixture.store.clipboardEntries(limit: 1)
        let entry = try XCTUnwrap(stored.first)

        let bridge = RecordingBridge(store: fixture.store)
        let provider = ClipboardProvider(store: fixture.store, bridge: bridge)
        try await provider.activate(
            PaletteItem(id: entry.id, title: "Image", providerID: "clip"),
            action: PaletteAction(
                id: "ocr-copy", title: "Copy Text (OCR)", kind: .custom, value: .text(entry.id)
            )
        )

        let copied = await bridge.copied
        let notifications = await bridge.notifications
        XCTAssertTrue(copied.isEmpty)
        XCTAssertTrue(notifications.contains("No text found"))
        let texts = try await fixture.store.clipboardEntries(limit: 10, kind: .text)
        XCTAssertEqual(texts.count, 0)
    }

    // MARK: - Browser order and missing files

    func testBrowserOrdersMixedKindsStrictlyNewestFirst() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let base = Date(timeIntervalSince1970: 10_000)

        _ = try await fixture.store.insertClipboard(text: "first", maxEntries: 50, at: base)
        _ = try await fixture.store.insertClipboardImage(
            png: Data("second-image".utf8), thumbnail: nil, width: 3, height: 2,
            maxEntries: 50, at: base.addingTimeInterval(1)
        )
        _ = try await fixture.store.insertClipboard(
            text: "third", maxEntries: 50, at: base.addingTimeInterval(2)
        )
        _ = try await fixture.store.insertClipboardFiles(
            paths: ["/tmp/fourth.txt"], thumbnail: nil, maxEntries: 50,
            at: base.addingTimeInterval(3)
        )

        let provider = ClipboardProvider(store: fixture.store, bridge: RecordingBridge())
        let items = try await provider.search(SearchRequest(text: "", limit: 20))
        XCTAssertEqual(items.map(\.title), ["fourth.txt", "third", "Image 3×2", "first"])
        XCTAssertTrue(items.allSatisfy { $0.group == nil }, "the browser is not grouped")
    }

    func testMissingThumbnailFileStillReturnsTheImageRow() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.store.insertClipboardImage(
            png: Data("missing-thumb-image".utf8), thumbnail: Data("thumb".utf8),
            width: 5, height: 4, maxEntries: 10
        )
        let stored = try await fixture.store.clipboardEntries(limit: 1)
        let entry = try XCTUnwrap(stored.first)
        XCTAssertNotNil(entry.thumbnailPNG)

        for url in files(in: fixture.thumbsDir) {
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertTrue(files(in: fixture.thumbsDir).isEmpty)

        let afterDeletion = try await fixture.store.clipboardEntries(limit: 10)
        XCTAssertEqual(afterDeletion.count, 1)
        XCTAssertEqual(afterDeletion.first?.id, entry.id)
        XCTAssertNil(afterDeletion.first?.thumbnailPNG)

        let provider = ClipboardProvider(store: fixture.store, bridge: RecordingBridge())
        let items = try await provider.search(SearchRequest(text: "", limit: 20))
        XCTAssertEqual(items.map(\.id), [entry.id])
        XCTAssertEqual(items.first?.icon, .symbol("photo"))
    }

    // MARK: - Per-kind trim

    func testPerKindTrimKeepsNewestBudgetsAndPinnedRows() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let base = Date(timeIntervalSince1970: 20_000)

        _ = try await fixture.store.insertClipboard(text: "text 0", maxEntries: 10, at: base)
        let storedText = try await fixture.store.clipboardEntries(limit: 1)
        let firstText = try XCTUnwrap(storedText.first)
        try await fixture.store.setClipboardPinned(id: firstText.id, pinned: true)
        for index in 1...30 {
            _ = try await fixture.store.insertClipboard(
                text: "text \(index)", maxEntries: 10,
                at: base.addingTimeInterval(Double(index))
            )
        }

        _ = try await fixture.store.insertClipboardImage(
            png: Data("image-0".utf8), thumbnail: nil, width: 1, height: 1,
            maxEntries: 5, at: base
        )
        let storedImage = try await fixture.store.clipboardEntries(limit: 1, kind: .image)
        let firstImage = try XCTUnwrap(storedImage.first)
        try await fixture.store.setClipboardPinned(id: firstImage.id, pinned: true)
        for index in 1...30 {
            _ = try await fixture.store.insertClipboardImage(
                png: Data("image-\(index)".utf8), thumbnail: nil,
                width: index + 1, height: 1,
                maxEntries: 5, at: base.addingTimeInterval(Double(index))
            )
        }

        let texts = try await fixture.store.clipboardEntries(limit: 100, kind: .text)
        XCTAssertEqual(texts.filter(\.pinned).map(\.text), ["text 0"])
        XCTAssertEqual(
            texts.filter { !$0.pinned }.map(\.text),
            (21...30).reversed().map { "text \($0)" }
        )
        XCTAssertEqual(texts.count, 11)

        let images = try await fixture.store.clipboardEntries(limit: 100, kind: .image)
        XCTAssertEqual(images.filter(\.pinned).map(\.imageWidth), [1])
        XCTAssertEqual(
            images.filter { !$0.pinned }.map(\.imageWidth),
            [31, 30, 29, 28, 27]
        )
        XCTAssertEqual(images.count, 6)
    }

    // MARK: - Setup helper and bound query

    func testEnsureFileExistsCreatesTheFileAndItsParents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-ensure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("nested/deeper/snippets.toml")

        PathExpansion.ensureFileExists(at: file.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), Data())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: file.deletingLastPathComponent().path
        ))
    }

    func testBoundQueryKeepsRowsOnlyWhileTheProviderIsUnchanged() {
        let triggers = [
            TriggerEntry(trigger: "bw", providerID: "bw"),
            TriggerEntry(trigger: "snip", providerID: "snip"),
        ]
        let parser = QueryParser(triggers: triggers)

        let same = parser.parse("/bw more typing")
        XCTAssertTrue(same.keepsPreviousRows(previousProviderID: "bw"))
        let switched = parser.parse("/snip note")
        XCTAssertFalse(switched.keepsPreviousRows(previousProviderID: "bw"))
        let first = parser.parse("/bw ")
        XCTAssertFalse(first.keepsPreviousRows(previousProviderID: nil))
    }
}
