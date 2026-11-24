import XCTest
import Foundation
import PaletteCore
import PalettePlatform

/// Clipboard image bytes live in files beside the database. These tests cover
/// the old-BLOB migration, content addressing, file lifecycle and the backup.
final class ClipboardImageStorageTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let store: PaletteStore

        var databasePath: String { root.appendingPathComponent("palette.sqlite").path }
        var clipboardDir: URL { root.appendingPathComponent("clipboard", isDirectory: true) }
        var imagesDir: URL { clipboardDir.appendingPathComponent("images", isDirectory: true) }
        var thumbsDir: URL { clipboardDir.appendingPathComponent("thumbs", isDirectory: true) }
    }

    private func makeStore() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-images-\(UUID().uuidString)")
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

    @discardableResult
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
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            throw NSError(
                domain: "ClipboardImageStorageTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message ?? "sqlite3 failed"]
            )
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func columnNames(of database: String, table: String) throws -> Set<String> {
        let output = try sqlite(database, "PRAGMA table_info(\(table));")
        return Set(output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            return parts.count > 1 ? String(parts[1]) : nil
        })
    }

    private func count(_ database: String, _ sql: String) throws -> String {
        try sqlite(database, sql).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - File store lifecycle

    func testInsertReadsBackFilesAndDeletesThem() async throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03])
        let thumbnail = Data([0x89, 0x50, 0x4E, 0x47, 0xFF])
        _ = try await fixture.store.insertClipboardImage(
            png: image, thumbnail: thumbnail, width: 640, height: 480, maxEntries: 100
        )

        let entries = try await fixture.store.clipboardEntries(limit: 10)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.kind, .image)
        XCTAssertEqual(entry.thumbnailPNG, thumbnail)
        let loadedImage = try await fixture.store.clipboardImage(id: entry.id)
        let loadedThumbnail = try await fixture.store.clipboardThumbnail(id: entry.id)
        XCTAssertEqual(loadedImage, image)
        XCTAssertEqual(loadedThumbnail, thumbnail)
        XCTAssertEqual(files(in: fixture.imagesDir).count, 1)
        XCTAssertEqual(files(in: fixture.thumbsDir).count, 1)

        let sha = ClipboardImageFiles.sha256(image)
        let imageFile = try XCTUnwrap(files(in: fixture.imagesDir).first)
        XCTAssertEqual(imageFile.lastPathComponent, "\(sha).png")
        XCTAssertEqual(imageFile.deletingLastPathComponent().lastPathComponent, String(sha.prefix(2)))

        try await fixture.store.deleteClipboard(id: entry.id)
        XCTAssertTrue(files(in: fixture.imagesDir).isEmpty)
        XCTAssertTrue(files(in: fixture.thumbsDir).isEmpty)
        let deleted = try await fixture.store.clipboardImage(id: entry.id)
        XCTAssertNil(deleted)
    }

    func testSharedThumbnailSurvivesUntilTheLastReferenceIsDeleted() async throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let icon = Data("shared-icon-bytes".utf8)
        _ = try await fixture.store.insertClipboardFiles(
            paths: ["/tmp/one.txt"], thumbnail: icon, maxEntries: 100
        )
        _ = try await fixture.store.insertClipboardFiles(
            paths: ["/tmp/two.txt"], thumbnail: icon, maxEntries: 100
        )
        XCTAssertEqual(files(in: fixture.thumbsDir).count, 1, "identical icons share one file")

        let entries = try await fixture.store.clipboardEntries(limit: 10, kind: .files)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.thumbnailPNG == icon })

        try await fixture.store.deleteClipboard(id: entries[0].id)
        XCTAssertEqual(files(in: fixture.thumbsDir).count, 1, "the other row still points at it")
        let survivingThumbnail = try await fixture.store.clipboardThumbnail(id: entries[1].id)
        XCTAssertEqual(survivingThumbnail, icon)

        try await fixture.store.deleteClipboard(id: entries[1].id)
        XCTAssertTrue(files(in: fixture.thumbsDir).isEmpty)
    }

    func testOrphanSweepKeepsReferencedFiles() async throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try await fixture.store.insertClipboardImage(
            png: Data("kept".utf8), thumbnail: Data("kept-thumb".utf8),
            width: 4, height: 4, maxEntries: 100
        )
        let orphanImage = fixture.imagesDir.appendingPathComponent("ff/deadbeef.png")
        let orphanThumb = fixture.thumbsDir.appendingPathComponent("ee/cafebabe.png")
        for url in [orphanImage, orphanThumb] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("orphan".utf8).write(to: url)
        }

        let removed = try await fixture.store.sweepClipboardImages()
        XCTAssertEqual(removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanImage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanThumb.path))
        XCTAssertEqual(files(in: fixture.imagesDir).count, 1)
        let keptEntries = try await fixture.store.clipboardEntries(limit: 1)
        let entry = try XCTUnwrap(keptEntries.first)
        let stillThere = try await fixture.store.clipboardImage(id: entry.id)
        XCTAssertEqual(stillThere, Data("kept".utf8))
    }

    func testImageCapEvictsOldestAndDeletesFiles() async throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let now = Date()
        for index in 0..<3 {
            _ = try await fixture.store.insertClipboardImage(
                png: Data(repeating: UInt8(10 + index), count: 10),
                thumbnail: Data(repeating: UInt8(20 + index), count: 4),
                width: 2, height: 2, maxEntries: 100,
                at: now.addingTimeInterval(TimeInterval(index))
            )
        }
        let report = try await fixture.store.maintain(
            clipboardRetentionDays: 30, maxImageBytes: 15, askRetentionDays: 30, now: now
        )
        XCTAssertEqual(report.clipboardRemoved, 2)
        let entries = try await fixture.store.clipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(files(in: fixture.imagesDir).count, 1)
        XCTAssertEqual(files(in: fixture.thumbsDir).count, 1)
    }

    func testMissingFilesDegradeToNilInsteadOfThrowing() async throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let image = Data("full-image".utf8)
        let thumbnail = Data("thumb-image".utf8)
        _ = try await fixture.store.insertClipboardImage(
            png: image, thumbnail: thumbnail, width: 3, height: 3, maxEntries: 100
        )
        let entries = try await fixture.store.clipboardEntries(limit: 1)
        let id = try XCTUnwrap(entries.first).id

        let imageFile = try XCTUnwrap(files(in: fixture.imagesDir).first)
        try FileManager.default.removeItem(at: imageFile)
        // A fresh store starts with a cold cache, like a relaunch.
        let reopened = try PaletteStore(
            path: fixture.databasePath,
            imagesDirectory: fixture.clipboardDir
        )
        let missingImage = try await reopened.clipboardImage(id: id)
        XCTAssertNil(missingImage)
        let reloadedEntry = try await reopened.clipboardEntry(id: id)
        let entry = try XCTUnwrap(reloadedEntry)
        XCTAssertEqual(entry.text, "")
        XCTAssertEqual(entry.thumbnailPNG, thumbnail, "the thumbnail has its own file")

        let thumbFile = try XCTUnwrap(files(in: fixture.thumbsDir).first)
        try FileManager.default.removeItem(at: thumbFile)
        let missingThumbnail = try await reopened.clipboardThumbnail(id: id)
        XCTAssertNil(missingThumbnail)
        let reloaded = try await reopened.clipboardEntry(id: id)
        XCTAssertNil(reloaded?.thumbnailPNG)
    }

    // MARK: - Old BLOB migration

    func testLegacyBlobMigrationMovesBytesAndDropsTheColumns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("palette.sqlite")
        let clipboardDir = root.appendingPathComponent("clipboard")

        let image = Data([0x89, 0x50, 0x4E, 0x47, 0xDE, 0xAD])
        let thumbnail = Data([0x89, 0x50, 0x4E, 0x47, 0xBE, 0xEF])
        let fileIcon = Data([0x49, 0x43, 0x4F, 0x4E])
        func hex(_ data: Data) -> String {
            data.map { String(format: "%02x", $0) }.joined()
        }
        // The store's migration is what this test exercises; build the old file
        // with the system sqlite3 before opening it.
        try sqlite(database.path, """
        CREATE TABLE clipboard (
            id TEXT PRIMARY KEY,
            hash TEXT NOT NULL UNIQUE,
            text TEXT NOT NULL,
            created REAL NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            kind TEXT NOT NULL DEFAULT 'text',
            image BLOB,
            thumbnail BLOB,
            width INTEGER NOT NULL DEFAULT 0,
            height INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO clipboard (id, hash, text, created, pinned, kind, image, thumbnail, width, height)
            VALUES ('img-1', 'hash-image', '', 1000.0, 1, 'image', X'\(hex(image))', X'\(hex(thumbnail))', 640, 480);
        INSERT INTO clipboard (id, hash, text, created, pinned, kind, image, thumbnail, width, height)
            VALUES ('files-1', 'hash-files', 'a.txt,b.txt', 1001.0, 0, 'files', NULL, X'\(hex(fileIcon))', 0, 0);
        INSERT INTO clipboard (id, hash, text, created, pinned, kind, image, thumbnail, width, height)
            VALUES ('text-1', 'hash-text', 'hello', 1002.0, 0, 'text', NULL, NULL, 0, 0);
        """)

        let store = try PaletteStore(
            path: database.path,
            imagesDirectory: clipboardDir
        )

        let migratedImage = try await store.clipboardImage(id: "img-1")
        let migratedThumbnail = try await store.clipboardThumbnail(id: "img-1")
        let migratedFileIcon = try await store.clipboardThumbnail(id: "files-1")
        XCTAssertEqual(migratedImage, image)
        XCTAssertEqual(migratedThumbnail, thumbnail)
        XCTAssertEqual(migratedFileIcon, fileIcon)

        let entries = try await store.clipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first { $0.id == "img-1" }?.pinned, true)
        XCTAssertEqual(entries.first { $0.id == "img-1" }?.imageWidth, 640)
        XCTAssertEqual(entries.first { $0.id == "img-1" }?.thumbnailPNG, thumbnail)

        var columns = try columnNames(of: database.path, table: "clipboard")
        XCTAssertFalse(columns.contains("image"))
        XCTAssertFalse(columns.contains("thumbnail"))
        XCTAssertTrue(columns.contains("kind"))
        let imageRows = try count(database.path, "SELECT COUNT(*) FROM clipboard_images;")
        XCTAssertEqual(imageRows, "2")

        let sha = ClipboardImageFiles.sha256(image)
        let expectedImage = clipboardDir
            .appendingPathComponent("images")
            .appendingPathComponent(String(sha.prefix(2)))
            .appendingPathComponent("\(sha).png")
        let storedImage = try Data(contentsOf: expectedImage)
        XCTAssertEqual(storedImage, image)

        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("palette.sqlite.bak-") }
        XCTAssertEqual(backups.count, 1, "one snapshot before the first migration run")
        let backupColumns = try columnNames(
            of: root.appendingPathComponent(backups[0]).path,
            table: "clipboard"
        )
        XCTAssertTrue(backupColumns.contains("image"), "the backup still has the original BLOBs")

        let pending = try await store.metaValue("clipboard_vacuum_pending")
        XCTAssertEqual(pending, "1")
        try await store.vacuumAfterClipboardMigration()
        let cleared = try await store.metaValue("clipboard_vacuum_pending")
        XCTAssertNil(cleared)
        let freelist = try count(database.path, "PRAGMA freelist_count;")
        XCTAssertEqual(freelist, "0")
        let total = try await store.clipboardCount()
        XCTAssertEqual(total, 3)

        // Reopening the migrated file must not migrate or back up again.
        _ = try PaletteStore(path: database.path, imagesDirectory: clipboardDir)
        let backupsAfter = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("palette.sqlite.bak-") }
        XCTAssertEqual(backupsAfter.count, 1)
        columns = try columnNames(of: database.path, table: "clipboard")
        XCTAssertFalse(columns.contains("image"))
    }

    // MARK: - Indexes

    func testClipboardIndexesCoverBrowsePinnedAndKindQueries() async throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let now = Date()
        _ = try await fixture.store.insertClipboard(text: "older", maxEntries: 100, at: now.addingTimeInterval(-10))
        _ = try await fixture.store.insertClipboard(text: "newer", maxEntries: 100, at: now)
        _ = try await fixture.store.insertClipboardImage(
            png: Data("img".utf8), thumbnail: nil, width: 2, height: 2,
            maxEntries: 100, at: now.addingTimeInterval(-5)
        )
        let browse = try await fixture.store.clipboardEntries(limit: 10)
        let newerID = try XCTUnwrap(browse.first { $0.text == "newer" }).id
        try await fixture.store.setClipboardPinned(id: newerID, pinned: true)

        let indexes = try sqlite(fixture.databasePath, "PRAGMA index_list(clipboard);")
        for name in ["clipboard_created", "clipboard_pinned_created", "clipboard_kind_created"] {
            XCTAssertTrue(indexes.contains(name), "missing index \(name): \(indexes)")
        }

        let created = try sqlite(
            fixture.databasePath,
            "EXPLAIN QUERY PLAN SELECT id FROM clipboard ORDER BY created DESC LIMIT 10;"
        )
        XCTAssertTrue(created.contains("clipboard_created"), created)
        let pinned = try sqlite(
            fixture.databasePath,
            "EXPLAIN QUERY PLAN SELECT id FROM clipboard ORDER BY pinned DESC, created DESC LIMIT 10;"
        )
        XCTAssertTrue(pinned.contains("clipboard_pinned_created"), pinned)
        XCTAssertFalse(pinned.contains("TEMP B-TREE"), pinned)
        let kind = try sqlite(
            fixture.databasePath,
            "EXPLAIN QUERY PLAN SELECT id FROM clipboard WHERE kind = 'image' ORDER BY created DESC LIMIT 10;"
        )
        XCTAssertTrue(kind.contains("clipboard_kind_created"), kind)
        let kindBrowse = try sqlite(
            fixture.databasePath,
            "EXPLAIN QUERY PLAN SELECT id FROM clipboard WHERE kind = 'image' ORDER BY pinned DESC, created DESC LIMIT 10;"
        )
        XCTAssertTrue(kindBrowse.contains("clipboard_kind_created"), kindBrowse)

        // Functional order is unchanged: pinned first, then newest.
        let ordered = try await fixture.store.clipboardEntries(limit: 10)
        XCTAssertEqual(ordered.map(\.text), ["newer", "", "older"])
        let images = try await fixture.store.clipboardEntries(limit: 10, kind: .image)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.kind, .image)
    }

    // MARK: - Backup

    func testBackupIncludesClipboardImagesAndStripsText() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PalettePaths(
            home: root.path,
            configDir: root.appendingPathComponent("config"),
            stateDir: root.appendingPathComponent("state"),
            cacheDir: root.appendingPathComponent("cache")
        )
        try FileManager.default.createDirectory(
            at: paths.stateDir, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: paths.configDir, withIntermediateDirectories: true
        )
        try "hotkey = \"opt+space\"\n".write(to: paths.configFile, atomically: true, encoding: .utf8)

        let store = try PaletteStore(
            path: paths.databaseFile.path,
            imagesDirectory: paths.clipboardImagesDir
        )
        _ = try await store.insertClipboard(text: "secret pasted text", maxEntries: 100)
        let image = Data("backup-image".utf8)
        let thumbnail = Data("backup-thumb".utf8)
        _ = try await store.insertClipboardImage(
            png: image, thumbnail: thumbnail, width: 8, height: 6, maxEntries: 100
        )

        let staged = root.appendingPathComponent("staged")
        let included = try BackupExporter.stage(paths: paths, into: staged)

        XCTAssertTrue(included.contains("clipboard"), "\(included)")
        let stagedClipboard = staged.appendingPathComponent("clipboard")
        XCTAssertEqual(files(in: stagedClipboard).count, 2, "image and thumbnail copied")
        let readme = try String(
            contentsOf: staged.appendingPathComponent("README.txt"), encoding: .utf8
        )
        XCTAssertTrue(readme.contains("clipboard/"), readme)

        let stagedDatabase = staged.appendingPathComponent("palette.sqlite").path
        let textRows = try count(
            stagedDatabase, "SELECT COUNT(*) FROM clipboard WHERE kind = 'text';"
        )
        XCTAssertEqual(textRows, "0")
        let imageRows = try count(stagedDatabase, "SELECT COUNT(*) FROM clipboard_images;")
        XCTAssertEqual(imageRows, "1")
        XCTAssertTrue(included.contains("config.toml"))
    }
}
