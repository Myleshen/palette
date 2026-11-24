import Foundation
import CryptoKit
import SQLite3
import PaletteCore

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct ScratchNote: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, title: String, text: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RecentUse: Identifiable, Equatable, Sendable {
    public var stableID: String
    public var provider: String
    public var itemID: String
    public var lastUsed: Date
    public var uses: Int
    public var id: String { stableID }
}

public struct AskChat: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// Model id, e.g. `muse-spark-1.3-contributor`.
    public var model: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, title: String, model: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// One line for the sidebar, cut at ~48 characters.
    public static func title(from question: String, limit: Int = 48) -> String {
        let single = question
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard single.count > limit else { return single }
        return String(single.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

public struct AskChatMessage: Identifiable, Equatable, Sendable {
    public var id: String
    public var chatID: String
    public var role: AskMessage.Role
    public var content: String
    public var createdAt: Date
    public var durationMs: Int
    public var promptTokens: Int
    public var completionTokens: Int
    public var sources: [AskSource]

    public init(
        id: String,
        chatID: String,
        role: AskMessage.Role,
        content: String,
        createdAt: Date,
        durationMs: Int = 0,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        sources: [AskSource] = []
    ) {
        self.id = id
        self.chatID = chatID
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.durationMs = durationMs
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.sources = sources
    }
}

public struct MaintenanceReport: Sendable, Equatable {
    public var clipboardRemoved: Int
    public var chatsRemoved: Int
    public var bytesBefore: Int64
    public var bytesAfter: Int64
    public var vacuumed: Bool

    public init(
        clipboardRemoved: Int = 0,
        chatsRemoved: Int = 0,
        bytesBefore: Int64 = 0,
        bytesAfter: Int64 = 0,
        vacuumed: Bool = false
    ) {
        self.clipboardRemoved = clipboardRemoved
        self.chatsRemoved = chatsRemoved
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.vacuumed = vacuumed
    }
}

public actor PaletteStore {
    private var database: OpaquePointer?
    private let filePath: String
    private let imageFiles: ClipboardImageFiles
    /// True only when moving old image BLOBs out of the table failed; reads
    /// then fall back to the columns so a full disk never hides history.
    private var hasLegacyBlobColumns = false
    /// VACUUM rewrites the whole file, so at most once per launch.
    private var hasVacuumed = false
    /// Bumped by every clipboard write so the provider's search snapshot knows
    /// when its copy is stale without polling the table.
    private var clipboardRevisionValue = 0

    private static let imageCacheLimit = 64 << 20
    private static let thumbnailCacheLimit = 16 << 20
    private var imageCache: [String: Data] = [:]
    private var imageCacheBytes = 0
    private var thumbnailCache: [String: Data] = [:]
    private var thumbnailCacheBytes = 0
    private var loggedMissingFiles: Set<String> = []

    public init(path: String, imagesDirectory: URL? = nil) throws {
        self.filePath = path
        self.imageFiles = ClipboardImageFiles(
            directory: imagesDirectory ?? ClipboardImageFiles.defaultDirectory(forDatabase: path)
        )
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            throw ProviderError.failed("Could not open the Palette database")
        }
        database = handle
        try Self.execute("PRAGMA journal_mode=WAL;", on: handle)
        try Self.execute("PRAGMA synchronous=NORMAL;", on: handle)
        try Self.execute("PRAGMA busy_timeout=3000;", on: handle)
        try Self.execute("PRAGMA foreign_keys=ON;", on: handle)
        hasLegacyBlobColumns = try Self.migrate(
            handle,
            imageFiles: imageFiles,
            databasePath: path
        )
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    private static func migrate(
        _ database: OpaquePointer?,
        imageFiles: ClipboardImageFiles,
        databasePath: String
    ) throws -> Bool {
        try execute("""
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            uses INTEGER NOT NULL DEFAULT 0,
            last_used REAL
        );
        CREATE INDEX IF NOT EXISTS items_provider ON items(provider);

        CREATE TABLE IF NOT EXISTS clipboard (
            id TEXT PRIMARY KEY,
            hash TEXT NOT NULL UNIQUE,
            text TEXT NOT NULL,
            created REAL NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            kind TEXT NOT NULL DEFAULT 'text',
            width INTEGER NOT NULL DEFAULT 0,
            height INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT
        );

        CREATE TABLE IF NOT EXISTS webapps (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            url TEXT NOT NULL UNIQUE,
            created REAL NOT NULL,
            shortcut TEXT
        );
        CREATE INDEX IF NOT EXISTS webapps_created ON webapps(created DESC);

        CREATE TABLE IF NOT EXISTS pins (
            id TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            payload TEXT NOT NULL,
            created REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS pins_created ON pins(created DESC);

        CREATE TABLE IF NOT EXISTS ask_history (
            id TEXT PRIMARY KEY,
            question TEXT NOT NULL,
            answer TEXT NOT NULL,
            model TEXT NOT NULL,
            provider TEXT NOT NULL,
            created REAL NOT NULL,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            prompt_tokens INTEGER NOT NULL DEFAULT 0,
            completion_tokens INTEGER NOT NULL DEFAULT 0,
            error TEXT
        );
        CREATE INDEX IF NOT EXISTS ask_history_created ON ask_history(created DESC);

        CREATE TABLE IF NOT EXISTS ask_chats (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            model TEXT NOT NULL,
            created REAL NOT NULL,
            updated REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS ask_chats_updated ON ask_chats(updated DESC);

        CREATE TABLE IF NOT EXISTS ask_chat_messages (
            id TEXT PRIMARY KEY,
            chat_id TEXT NOT NULL REFERENCES ask_chats(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created REAL NOT NULL,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            prompt_tokens INTEGER NOT NULL DEFAULT 0,
            completion_tokens INTEGER NOT NULL DEFAULT 0,
            sources TEXT
        );
        CREATE INDEX IF NOT EXISTS ask_chat_messages_chat
            ON ask_chat_messages(chat_id, created);

        CREATE TABLE IF NOT EXISTS scratch_notes (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            text TEXT NOT NULL,
            created REAL NOT NULL,
            updated REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS scratch_notes_updated ON scratch_notes(updated DESC);

        -- Learned ranking: a digest of the query prefix, never the text.
        CREATE TABLE IF NOT EXISTS query_memory (
            prefix_hash TEXT NOT NULL,
            item_key TEXT NOT NULL,
            count INTEGER NOT NULL DEFAULT 0,
            last_used REAL NOT NULL,
            PRIMARY KEY (prefix_hash, item_key)
        );
        CREATE INDEX IF NOT EXISTS query_memory_last_used ON query_memory(last_used DESC);
        """, on: database)

        if try !hasColumn("webapps", "shortcut", on: database) {
            try execute("ALTER TABLE webapps ADD COLUMN shortcut TEXT;", on: database)
        }
        if try !hasColumn("clipboard", "kind", on: database) {
            try execute("ALTER TABLE clipboard ADD COLUMN kind TEXT NOT NULL DEFAULT 'text';", on: database)
        }
        if try !hasColumn("clipboard", "width", on: database) {
            try execute("ALTER TABLE clipboard ADD COLUMN width INTEGER NOT NULL DEFAULT 0;", on: database)
        }
        if try !hasColumn("clipboard", "height", on: database) {
            try execute("ALTER TABLE clipboard ADD COLUMN height INTEGER NOT NULL DEFAULT 0;", on: database)
        }
        if try !hasColumn("ask_chat_messages", "sources", on: database) {
            try execute("ALTER TABLE ask_chat_messages ADD COLUMN sources TEXT;", on: database)
        }

        // Image bytes live in content-addressed files, never in the table.
        try execute("""
        CREATE TABLE IF NOT EXISTS clipboard_images (
            clipboard_id TEXT PRIMARY KEY REFERENCES clipboard(id) ON DELETE CASCADE,
            sha256 TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            thumb_relative_path TEXT,
            byte_count INTEGER NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS clipboard_images_sha ON clipboard_images(sha256);
        """, on: database)

        var legacyBlobsRemain = false
        let hasImage = try hasColumn("clipboard", "image", on: database)
        let hasThumbnail = try hasColumn("clipboard", "thumbnail", on: database)
        if hasImage || hasThumbnail {
            do {
                try migrateImageBlobs(
                    database,
                    imageFiles: imageFiles,
                    databasePath: databasePath
                )
                try rebuildClipboardTable(database)
                try run(database, """
                INSERT INTO meta (key, value) VALUES ('clipboard_vacuum_pending', '1')
                ON CONFLICT(key) DO UPDATE SET value = '1';
                """, [])
            } catch {
                // Keep the old columns and history; the next launch retries.
                legacyBlobsRemain = true
                Log.shared.warn(
                    "Clipboard image migration deferred: \(error.localizedDescription)",
                    source: "storage"
                )
            }
        }

        try execute("""
        CREATE INDEX IF NOT EXISTS clipboard_created ON clipboard(created DESC);
        CREATE INDEX IF NOT EXISTS clipboard_pinned_created ON clipboard(pinned DESC, created DESC);
        CREATE INDEX IF NOT EXISTS clipboard_kind_created ON clipboard(kind, created DESC);
        """, on: database)
        return legacyBlobsRemain
    }

    private struct LegacyImageRow {
        var id: String
        var image: Data?
        var thumbnail: Data?
        var width: Int
        var height: Int
    }

    /// Copies every legacy image/thumbnail BLOB to the files store, verifies the
    /// bytes, then records the file in `clipboard_images`. The table rebuild is
    /// a separate step, so a failure here leaves the original rows intact.
    private static func migrateImageBlobs(
        _ database: OpaquePointer?,
        imageFiles: ClipboardImageFiles,
        databasePath: String
    ) throws {
        _ = try backupDatabase(database, path: databasePath)
        let batchSize = 32
        var offset = 0
        var migrated = 0
        while true {
            let rows = try legacyImageBatch(database, offset: offset, limit: batchSize)
            if rows.isEmpty { break }
            var metadata: [(id: String, stored: ClipboardImageFiles.Stored, thumb: ClipboardImageFiles.Stored?, row: LegacyImageRow)] = []
            for row in rows {
                let stored: ClipboardImageFiles.Stored
                let thumb: ClipboardImageFiles.Stored?
                if let image = row.image, !image.isEmpty {
                    stored = try imageFiles.store(image, in: .images)
                    if let thumbnail = row.thumbnail, !thumbnail.isEmpty {
                        thumb = try imageFiles.store(thumbnail, in: .thumbs)
                    } else {
                        thumb = nil
                    }
                } else if let thumbnail = row.thumbnail, !thumbnail.isEmpty {
                    stored = try imageFiles.store(thumbnail, in: .thumbs)
                    thumb = nil
                } else {
                    continue
                }
                metadata.append((row.id, stored, thumb, row))
            }

            try execute("BEGIN IMMEDIATE;", on: database)
            do {
                for entry in metadata {
                    try run(database, """
                    INSERT INTO clipboard_images
                        (clipboard_id, sha256, relative_path, thumb_relative_path, byte_count, width, height)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(clipboard_id) DO UPDATE SET
                        sha256 = excluded.sha256,
                        relative_path = excluded.relative_path,
                        thumb_relative_path = excluded.thumb_relative_path,
                        byte_count = excluded.byte_count,
                        width = excluded.width,
                        height = excluded.height;
                    """, [
                        entry.id,
                        entry.stored.sha256,
                        entry.stored.relativePath,
                        entry.thumb?.relativePath,
                        String(entry.stored.byteCount),
                        String(entry.row.width),
                        String(entry.row.height),
                    ])
                }
                try execute("COMMIT;", on: database)
            } catch {
                try? execute("ROLLBACK;", on: database)
                throw error
            }

            migrated += rows.count
            offset += rows.count
            if migrated % 256 == 0 {
                Log.shared.info("Clipboard image migration: \(migrated) rows moved", source: "storage")
            }
        }
        if migrated > 0 {
            Log.shared.info(
                "Clipboard image migration moved \(migrated) rows to \(imageFiles.directory.path)",
                source: "storage"
            )
        }
    }

    private static func legacyImageBatch(
        _ database: OpaquePointer?,
        offset: Int,
        limit: Int
    ) throws -> [LegacyImageRow] {
        var statement: OpaquePointer?
        let sql = """
        SELECT id, image, thumbnail, width, height FROM clipboard
        WHERE image IS NOT NULL OR thumbnail IS NOT NULL
        ORDER BY rowid LIMIT ? OFFSET ?;
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProviderError.failed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        sqlite3_bind_int(statement, 2, Int32(offset))
        var rows: [LegacyImageRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            rows.append(LegacyImageRow(
                id: String(cString: idText),
                image: dataColumn(statement, 1),
                thumbnail: dataColumn(statement, 2),
                width: Int(sqlite3_column_int(statement, 3)),
                height: Int(sqlite3_column_int(statement, 4))
            ))
        }
        return rows
    }

    private static func dataColumn(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return count > 0 ? Data(bytes: bytes, count: count) : nil
    }

    /// Rebuilds `clipboard` without the two BLOB columns in one transaction.
    /// `clipboard_images` keeps its rows: foreign keys are off for the swap and
    /// the renamed table takes the old name, so the references resolve again.
    private static func rebuildClipboardTable(_ database: OpaquePointer?) throws {
        let before = try intValue(database, "SELECT COUNT(*) FROM clipboard;")
        try execute("PRAGMA foreign_keys=OFF;", on: database)
        defer { try? execute("PRAGMA foreign_keys=ON;", on: database) }
        try execute("BEGIN IMMEDIATE;", on: database)
        do {
            try execute("""
            CREATE TABLE clipboard_new (
                id TEXT PRIMARY KEY,
                hash TEXT NOT NULL UNIQUE,
                text TEXT NOT NULL,
                created REAL NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                kind TEXT NOT NULL DEFAULT 'text',
                width INTEGER NOT NULL DEFAULT 0,
                height INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO clipboard_new (id, hash, text, created, pinned, kind, width, height)
                SELECT id, hash, text, created, pinned, kind, width, height FROM clipboard;
            """, on: database)
            let after = try intValue(database, "SELECT COUNT(*) FROM clipboard_new;")
            guard after == before else {
                throw ProviderError.failed("Clipboard rebuild would lose rows")
            }
            try execute("DROP TABLE clipboard;", on: database)
            try execute("ALTER TABLE clipboard_new RENAME TO clipboard;", on: database)
            let orphans = try intValue(database, "SELECT COUNT(*) FROM pragma_foreign_key_check;")
            guard orphans == 0 else {
                throw ProviderError.failed("Clipboard rebuild would orphan image metadata")
            }
            try execute("COMMIT;", on: database)
        } catch {
            try? execute("ROLLBACK;", on: database)
            throw error
        }
    }

    /// A one-file snapshot before the first image migration. Uses SQLite's
    /// backup API so the copy is consistent even with an active WAL.
    @discardableResult
    private static func backupDatabase(_ database: OpaquePointer?, path: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var candidate = URL(fileURLWithPath: "\(path).bak-\(stamp)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = URL(fileURLWithPath: "\(path).bak-\(stamp)-\(suffix)")
            suffix += 1
        }
        var destination: OpaquePointer?
        guard sqlite3_open(candidate.path, &destination) == SQLITE_OK else {
            throw ProviderError.failed("Could not create the clipboard migration backup")
        }
        defer {
            sqlite3_close(destination)
            // The copy inherited WAL mode; leave one self-contained file.
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: candidate.path + suffix)
            }
        }
        guard let backup = sqlite3_backup_init(destination, "main", database, "main") else {
            throw ProviderError.failed(String(cString: sqlite3_errmsg(destination)))
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw ProviderError.failed("Could not copy the database for the migration backup")
        }
        // The source is in WAL mode, so the copy inherits that mode. Fold and
        // remove the side files: the backup is one self-contained database.
        try? execute("PRAGMA wal_checkpoint(TRUNCATE);", on: destination)
        try? execute("PRAGMA journal_mode=DELETE;", on: destination)
        Log.shared.info("Clipboard migration backup kept at \(candidate.path)", source: "storage")
        return candidate
    }

    private static func run(
        _ database: OpaquePointer?,
        _ sql: String,
        _ values: [String?]
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProviderError.failed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            if let value {
                sqlite3_bind_text(statement, Int32(offset + 1), value, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(statement, Int32(offset + 1))
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ProviderError.failed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func intValue(_ database: OpaquePointer?, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProviderError.failed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func hasColumn(_ table: String, _ column: String, on database: OpaquePointer?) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            throw ProviderError.failed("Could not inspect the \(table) table")
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column {
                return true
            }
        }
        return false
    }

    // MARK: - Frecency

    public func recordUse(stableID: String, provider: String, at date: Date = Date()) throws {
        let statement = try prepare("""
        INSERT INTO items (id, provider, uses, last_used) VALUES (?, ?, 1, ?)
        ON CONFLICT(id) DO UPDATE SET uses = uses + 1, last_used = excluded.last_used;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, stableID)
        bind(statement, 2, provider)
        sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
        try step(statement)
    }

    /// Raw launch counts, used by the "most used" app ordering.
    public func useCounts(for stableIDs: [String]) throws -> [String: Int] {
        guard !stableIDs.isEmpty else { return [:] }
        let wanted = Set(stableIDs)
        let statement = try prepare("SELECT id, uses FROM items WHERE uses > 0;")
        defer { sqlite3_finalize(statement) }
        var result: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: text)
            guard wanted.contains(id) else { continue }
            result[id] = Int(sqlite3_column_int(statement, 1))
        }
        return result
    }

    public func recentUses(providers: [String], limit: Int = 50) throws -> [RecentUse] {
        guard !providers.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: providers.count).joined(separator: ",")
        let statement = try prepare("""
        SELECT id, provider, uses, last_used FROM items
        WHERE provider IN (\(placeholders)) AND last_used IS NOT NULL
        ORDER BY last_used DESC LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        for (index, provider) in providers.enumerated() {
            bind(statement, Int32(index + 1), provider)
        }
        sqlite3_bind_int(statement, Int32(providers.count + 1), Int32(max(1, limit)))
        var uses: [RecentUse] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let providerText = sqlite3_column_text(statement, 1) else { continue }
            let stableID = String(cString: idText)
            let provider = String(cString: providerText)
            let prefix = provider + ":"
            let itemID = stableID.hasPrefix(prefix)
                ? String(stableID.dropFirst(prefix.count))
                : stableID
            uses.append(RecentUse(
                stableID: stableID,
                provider: provider,
                itemID: itemID,
                lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                uses: Int(sqlite3_column_int(statement, 2))
            ))
        }
        return uses
    }

    public func frecencyBoosts(for stableIDs: [String], now: Date = Date()) throws -> [String: Double] {
        guard !stableIDs.isEmpty else { return [:] }
        let wanted = Set(stableIDs)
        let statement = try prepare("SELECT id, uses, last_used FROM items WHERE uses > 0;")
        defer { sqlite3_finalize(statement) }
        var result: [String: Double] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: text)
            guard wanted.contains(id) else { continue }
            let uses = Int(sqlite3_column_int(statement, 1))
            let lastUsed = sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            result[id] = Ranking.frecencyBoost(uses: uses, lastUsed: lastUsed, now: now)
        }
        return result
    }

    // MARK: - Learned ranking

    /// Four item keys per prefix, 400 prefixes; the oldest rows fall off first.
    public func recordLearnedChoice(prefixHash: String, itemKey: String, at date: Date = Date()) throws {
        let statement = try prepare("""
        INSERT INTO query_memory (prefix_hash, item_key, count, last_used) VALUES (?, ?, 1, ?)
        ON CONFLICT(prefix_hash, item_key) DO UPDATE SET count = count + 1,
            last_used = excluded.last_used;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, prefixHash)
        bind(statement, 2, itemKey)
        sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
        try step(statement)

        let trimItems = try prepare("""
        DELETE FROM query_memory WHERE prefix_hash = ? AND item_key NOT IN (
            SELECT item_key FROM query_memory WHERE prefix_hash = ?
            ORDER BY count DESC, last_used DESC LIMIT 4
        );
        """)
        defer { sqlite3_finalize(trimItems) }
        bind(trimItems, 1, prefixHash)
        bind(trimItems, 2, prefixHash)
        try step(trimItems)

        try execute("""
        DELETE FROM query_memory WHERE prefix_hash NOT IN (
            SELECT prefix_hash FROM query_memory GROUP BY prefix_hash
            ORDER BY MAX(last_used) DESC LIMIT 400
        );
        """)
    }

    public func learnedBoosts(prefixHash: String, itemKeys: [String]) throws -> [String: Double] {
        guard !itemKeys.isEmpty else { return [:] }
        let wanted = Set(itemKeys)
        let statement = try prepare("SELECT item_key, count FROM query_memory WHERE prefix_hash = ?;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, prefixHash)
        var result: [String: Double] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            let key = String(cString: text)
            guard wanted.contains(key) else { continue }
            result[key] = Ranking.learnedBoost(count: Int(sqlite3_column_int(statement, 1)))
        }
        return result
    }

    /// Forgets every learned prefix; returns the rows removed.
    @discardableResult
    public func clearLearnedRanking() throws -> Int {
        try execute("DELETE FROM query_memory;")
        return Int(sqlite3_changes(database))
    }

    public func learnedRankingCount() throws -> Int {
        try intValue("SELECT COUNT(*) FROM query_memory;")
    }

    // MARK: - Clipboard

    public func insertClipboard(text: String, maxEntries: Int, at date: Date = Date()) throws -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200_000 else { return false }
        let hash = SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined()
        let existing = try clipboardContains(hash: hash)

        let statement = try prepare("""
        INSERT INTO clipboard (id, hash, text, created, pinned) VALUES (?, ?, ?, ?, 0)
        ON CONFLICT(hash) DO UPDATE SET created = excluded.created;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, UUID().uuidString)
        bind(statement, 2, hash)
        bind(statement, 3, trimmed)
        sqlite3_bind_double(statement, 4, date.timeIntervalSince1970)
        try step(statement)
        try trimClipboard(maxEntries: maxEntries)
        clipboardRevisionValue += 1
        return !existing
    }

    private func clipboardContains(hash: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM clipboard WHERE hash = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, hash)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    public func insertClipboardImage(
        png: Data,
        thumbnail: Data?,
        width: Int,
        height: Int,
        maxEntries: Int,
        at date: Date = Date()
    ) throws -> Bool {
        guard !png.isEmpty, png.count <= 20_000_000, width > 0, height > 0 else { return false }
        let hash = ClipboardImageFiles.sha256(png)
        let existing = try clipboardContains(hash: hash)
        let stored = try imageFiles.store(png, in: .images)
        let thumb = try thumbnail.map { try imageFiles.store($0, in: .thumbs) }
        let id = UUID().uuidString

        try transaction {
            let statement = try prepare("""
            INSERT INTO clipboard (id, hash, text, created, pinned, kind, width, height)
            VALUES (?, ?, '', ?, 0, 'image', ?, ?)
            ON CONFLICT(hash) DO UPDATE SET created = excluded.created;
            """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, id)
            bind(statement, 2, hash)
            sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
            sqlite3_bind_int(statement, 4, Int32(width))
            sqlite3_bind_int(statement, 5, Int32(height))
            try step(statement)

            let rowID: String
            if existing {
                rowID = try clipboardID(hash: hash) ?? id
            } else {
                rowID = id
            }
            let metadata = try prepare("""
            INSERT INTO clipboard_images
                (clipboard_id, sha256, relative_path, thumb_relative_path, byte_count, width, height)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(clipboard_id) DO UPDATE SET
                sha256 = excluded.sha256,
                relative_path = excluded.relative_path,
                thumb_relative_path = excluded.thumb_relative_path,
                byte_count = excluded.byte_count,
                width = excluded.width,
                height = excluded.height;
            """)
            defer { sqlite3_finalize(metadata) }
            bind(metadata, 1, rowID)
            bind(metadata, 2, stored.sha256)
            bind(metadata, 3, stored.relativePath)
            bind(metadata, 4, thumb?.relativePath)
            sqlite3_bind_int(metadata, 5, Int32(stored.byteCount))
            sqlite3_bind_int(metadata, 6, Int32(width))
            sqlite3_bind_int(metadata, 7, Int32(height))
            try step(metadata)
        }

        try trimClipboard(maxEntries: maxEntries)
        clipboardRevisionValue += 1
        return !existing
    }

    public func clipboardImage(id: String) throws -> Data? {
        let statement = try prepare("""
        SELECT ci.relative_path FROM clipboard c
        JOIN clipboard_images ci ON ci.clipboard_id = c.id
        WHERE c.id = ? AND c.kind = 'image' LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        if sqlite3_step(statement) == SQLITE_ROW,
           let text = sqlite3_column_text(statement, 0),
           let data = imageData(relativePath: String(cString: text)) {
            return data
        }
        return try legacyImage(id: id)
    }

    public func clipboardThumbnail(id: String) throws -> Data? {
        let statement = try prepare("""
        SELECT c.kind, ci.relative_path, ci.thumb_relative_path FROM clipboard c
        LEFT JOIN clipboard_images ci ON ci.clipboard_id = c.id
        WHERE c.id = ? LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let kind = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "text"
        let relative = sqlite3_column_text(statement, 1).map { String(cString: $0) }
        let thumb = sqlite3_column_text(statement, 2).map { String(cString: $0) }
        if let path = thumbnailRelativePath(
            kind: ClipboardKind(rawValue: kind) ?? .text,
            relative: relative,
            thumb: thumb
        ), let data = thumbnailData(relativePath: path) {
            return data
        }
        return try legacyThumbnail(id: id)
    }

    /// Finder copies are stored once per selection, with the paths joined by
    /// newlines in `text` and the lead item's icon as the thumbnail.
    public func insertClipboardFiles(
        paths: [String],
        thumbnail: Data?,
        maxEntries: Int,
        at date: Date = Date()
    ) throws -> Bool {
        let cleaned = paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return false }
        let text = cleaned.joined(separator: "\n")
        guard text.count <= 50_000 else { return false }
        let hash = ClipboardImageFiles.sha256(Data(text.utf8))
        let existing = try clipboardContains(hash: hash)
        let thumb = try thumbnail.map { try imageFiles.store($0, in: .thumbs) }
        let id = UUID().uuidString

        try transaction {
            let statement = try prepare("""
            INSERT INTO clipboard (id, hash, text, created, pinned, kind)
            VALUES (?, ?, ?, ?, 0, 'files')
            ON CONFLICT(hash) DO UPDATE SET created = excluded.created;
            """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, id)
            bind(statement, 2, hash)
            bind(statement, 3, text)
            sqlite3_bind_double(statement, 4, date.timeIntervalSince1970)
            try step(statement)

            guard let thumb else { return }
            let rowID: String
            if existing {
                rowID = try clipboardID(hash: hash) ?? id
            } else {
                rowID = id
            }
            let metadata = try prepare("""
            INSERT INTO clipboard_images
                (clipboard_id, sha256, relative_path, thumb_relative_path, byte_count, width, height)
            VALUES (?, ?, ?, NULL, ?, 0, 0)
            ON CONFLICT(clipboard_id) DO UPDATE SET
                sha256 = excluded.sha256,
                relative_path = excluded.relative_path,
                thumb_relative_path = NULL,
                byte_count = excluded.byte_count,
                width = 0,
                height = 0;
            """)
            defer { sqlite3_finalize(metadata) }
            bind(metadata, 1, rowID)
            bind(metadata, 2, thumb.sha256)
            bind(metadata, 3, thumb.relativePath)
            sqlite3_bind_int(metadata, 4, Int32(thumb.byteCount))
            try step(metadata)
        }

        try trimClipboard(maxEntries: maxEntries)
        clipboardRevisionValue += 1
        return !existing
    }

    public func clipboardEntries(
        limit: Int = 100,
        query: String? = nil,
        kind: ClipboardKind? = nil,
        includeThumbnails: Bool = true
    ) throws -> [ClipboardEntry] {
        var conditions: [String] = []
        let search = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let search, !search.isEmpty {
            conditions.append("c.text LIKE ? ESCAPE '\\'")
        }
        if kind != nil {
            conditions.append("c.kind = ?")
        }
        var sql = Self.clipboardSelect
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY c.pinned DESC, c.created DESC LIMIT ?;"

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let search, !search.isEmpty {
            let escaped = search
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            bind(statement, index, "%\(escaped)%")
            index += 1
        }
        if let kind {
            bind(statement, index, kind.rawValue)
            index += 1
        }
        sqlite3_bind_int(statement, index, Int32(max(1, limit)))

        var entries: [ClipboardEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let entry = try makeEntry(from: statement, includeThumbnails: includeThumbnails) {
                entries.append(entry)
            }
        }
        return entries
    }

    public func clipboardEntry(id: String) throws -> ClipboardEntry? {
        let statement = try prepare("\(Self.clipboardSelect) WHERE c.id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try makeEntry(from: statement, includeThumbnails: true)
    }

    public func deleteClipboard(id: String) throws {
        let paths = try imageRelativePaths(forIDs: [id])
        let statement = try prepare("DELETE FROM clipboard WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        try step(statement)
        try releaseImageFiles(paths)
        clipboardRevisionValue += 1
    }

    public func setClipboardPinned(id: String, pinned: Bool) throws {
        let statement = try prepare("UPDATE clipboard SET pinned = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, pinned ? 1 : 0)
        bind(statement, 2, id)
        try step(statement)
        clipboardRevisionValue += 1
    }

    public func clearClipboard() throws {
        let ids = try stringValues("SELECT id FROM clipboard WHERE pinned = 0;")
        let paths = try imageRelativePaths(forIDs: ids)
        try deleteClipboardRows(ids: ids)
        try releaseImageFiles(paths)
        clipboardRevisionValue += 1
    }

    /// Changes whenever a clipboard row is inserted, removed or re-pinned. The
    /// provider compares it to know when its folded search snapshot is stale.
    public func clipboardRevision() -> Int {
        clipboardRevisionValue
    }

    /// The rows a search snapshot needs, already in display order. The text is
    /// capped in SQL so a 1 MB clipboard costs one prefix, not one megabyte.
    public func clipboardSearchRows(limit: Int) throws -> [ClipboardSearchRow] {
        let statement = try prepare("""
        SELECT id, substr(text, 1, 4096), kind, pinned, created, width, height
        FROM clipboard
        ORDER BY pinned DESC,
                 CASE kind WHEN 'text' THEN 0 WHEN 'image' THEN 1 ELSE 2 END,
                 created DESC
        LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, limit)))

        var rows: [ClipboardSearchRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let text = sqlite3_column_text(statement, 1) else { continue }
            let kind = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "text"
            rows.append(ClipboardSearchRow(
                id: String(cString: idText),
                textPrefix: String(cString: text),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                pinned: sqlite3_column_int(statement, 3) != 0,
                kind: ClipboardKind(rawValue: kind) ?? .text,
                imageWidth: Int(sqlite3_column_int(statement, 5)),
                imageHeight: Int(sqlite3_column_int(statement, 6))
            ))
        }
        return rows
    }

    /// Full rows for the handful of ids a search is about to show.
    public func clipboardEntries(ids: [String], includeThumbnails: Bool = true) throws -> [ClipboardEntry] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let statement = try prepare("\(Self.clipboardSelect) WHERE c.id IN (\(placeholders));")
        defer { sqlite3_finalize(statement) }
        for (offset, id) in ids.enumerated() {
            bind(statement, Int32(offset + 1), id)
        }

        var entries: [ClipboardEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let entry = try makeEntry(from: statement, includeThumbnails: includeThumbnails) {
                entries.append(entry)
            }
        }
        return entries
    }

    // MARK: - Clipboard image files

    private static let clipboardSelect = """
    SELECT c.id, c.text, c.created, c.pinned, c.kind, c.width, c.height,
           ci.relative_path, ci.thumb_relative_path
    FROM clipboard c
    LEFT JOIN clipboard_images ci ON ci.clipboard_id = c.id
    """

    private func makeEntry(from statement: OpaquePointer?, includeThumbnails: Bool) throws -> ClipboardEntry? {
        guard let idText = sqlite3_column_text(statement, 0),
              let bodyText = sqlite3_column_text(statement, 1) else { return nil }
        let id = String(cString: idText)
        let kindText = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "text"
        let kind = ClipboardKind(rawValue: kindText) ?? .text
        var thumbnail: Data?
        if includeThumbnails {
            let relative = sqlite3_column_text(statement, 7).map { String(cString: $0) }
            let thumb = sqlite3_column_text(statement, 8).map { String(cString: $0) }
            if let path = thumbnailRelativePath(kind: kind, relative: relative, thumb: thumb) {
                thumbnail = thumbnailData(relativePath: path)
            }
            if thumbnail == nil, hasLegacyBlobColumns {
                thumbnail = try legacyThumbnail(id: id)
            }
        }
        return ClipboardEntry(
            id: id,
            text: String(cString: bodyText),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            pinned: sqlite3_column_int(statement, 3) != 0,
            kind: kind,
            imageWidth: Int(sqlite3_column_int(statement, 5)),
            imageHeight: Int(sqlite3_column_int(statement, 6)),
            thumbnailPNG: thumbnail
        )
    }

    /// File entries have no full image, only the lead item's icon, so their
    /// primary file is the thumbnail.
    private func thumbnailRelativePath(
        kind: ClipboardKind,
        relative: String?,
        thumb: String?
    ) -> String? {
        kind == .files ? relative : thumb
    }

    private func imageData(relativePath: String) -> Data? {
        if let hit = imageCache[relativePath] {
            if imageFiles.exists(relativePath: relativePath) { return hit }
            imageCache.removeValue(forKey: relativePath)
            imageCacheBytes -= hit.count
            logMissing(relativePath)
            return nil
        }
        guard let data = imageFiles.read(relativePath: relativePath), !data.isEmpty else {
            logMissing(relativePath)
            return nil
        }
        if imageCacheBytes + data.count > Self.imageCacheLimit {
            imageCache.removeAll(keepingCapacity: true)
            imageCacheBytes = 0
        }
        imageCache[relativePath] = data
        imageCacheBytes += data.count
        return data
    }

    private func thumbnailData(relativePath: String) -> Data? {
        if let hit = thumbnailCache[relativePath] {
            if imageFiles.exists(relativePath: relativePath) { return hit }
            thumbnailCache.removeValue(forKey: relativePath)
            thumbnailCacheBytes -= hit.count
            logMissing(relativePath)
            return nil
        }
        guard let data = imageFiles.read(relativePath: relativePath), !data.isEmpty else {
            logMissing(relativePath)
            return nil
        }
        if thumbnailCacheBytes + data.count > Self.thumbnailCacheLimit {
            thumbnailCache.removeAll(keepingCapacity: true)
            thumbnailCacheBytes = 0
        }
        thumbnailCache[relativePath] = data
        thumbnailCacheBytes += data.count
        return data
    }

    /// A missing file is data loss, but it must not spam the log on every
    /// keystroke; the UI already falls back to a placeholder icon.
    private func logMissing(_ relativePath: String) {
        guard loggedMissingFiles.insert(relativePath).inserted else { return }
        Log.shared.warn("Clipboard image file is missing: \(relativePath)", source: "storage")
    }

    private func legacyImage(id: String) throws -> Data? {
        guard hasLegacyBlobColumns else { return nil }
        let statement = try prepare("SELECT image FROM clipboard WHERE id = ? AND kind = 'image' LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.dataColumn(statement, 0)
    }

    private func legacyThumbnail(id: String) throws -> Data? {
        guard hasLegacyBlobColumns else { return nil }
        let statement = try prepare("SELECT thumbnail FROM clipboard WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.dataColumn(statement, 0)
    }

    private func clipboardID(hash: String) throws -> String? {
        let statement = try prepare("SELECT id FROM clipboard WHERE hash = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, hash)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private func imageRelativePaths(forIDs ids: [String]) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let statement = try prepare("""
        SELECT relative_path, thumb_relative_path FROM clipboard_images
        WHERE clipboard_id IN (\(placeholders));
        """)
        defer { sqlite3_finalize(statement) }
        for (offset, id) in ids.enumerated() {
            bind(statement, Int32(offset + 1), id)
        }
        var paths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) {
                paths.append(path)
            }
            if let thumb = sqlite3_column_text(statement, 1).map({ String(cString: $0) }) {
                paths.append(thumb)
            }
        }
        return paths
    }

    /// Removes a file only once no clipboard row references it; identical
    /// images and identical file icons share one file.
    private func releaseImageFiles(_ paths: [String]) throws {
        for relativePath in Set(paths) {
            guard try referenceCount(forFile: relativePath) == 0 else { continue }
            try? imageFiles.delete(relativePath: relativePath)
            if let cached = imageCache.removeValue(forKey: relativePath) {
                imageCacheBytes -= cached.count
            }
            if let cached = thumbnailCache.removeValue(forKey: relativePath) {
                thumbnailCacheBytes -= cached.count
            }
            loggedMissingFiles.remove(relativePath)
        }
    }

    private func referenceCount(forFile relativePath: String) throws -> Int {
        let statement = try prepare("""
        SELECT (SELECT COUNT(*) FROM clipboard_images WHERE relative_path = ?1)
             + (SELECT COUNT(*) FROM clipboard_images WHERE thumb_relative_path = ?1);
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, relativePath)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func deleteClipboardRows(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let statement = try prepare("DELETE FROM clipboard WHERE id IN (\(placeholders));")
        defer { sqlite3_finalize(statement) }
        for (offset, id) in ids.enumerated() {
            bind(statement, Int32(offset + 1), id)
        }
        try step(statement)
    }

    private func stringValues(_ sql: String) throws -> [String] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
        }
        return values
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Deletes files no `clipboard_images` row points at: leftovers from a
    /// failed migration, a crash between file write and row insert, or a
    /// manual database edit. Run once per launch.
    @discardableResult
    public func sweepClipboardImages() throws -> Int {
        let referenced = Set(try stringValues("""
        SELECT relative_path FROM clipboard_images
        UNION
        SELECT thumb_relative_path FROM clipboard_images WHERE thumb_relative_path IS NOT NULL;
        """))
        var removed = 0
        for relativePath in imageFiles.allRelativePaths() where !referenced.contains(relativePath) {
            guard (try? imageFiles.delete(relativePath: relativePath)) != nil else { continue }
            if let cached = imageCache.removeValue(forKey: relativePath) {
                imageCacheBytes -= cached.count
            }
            if let cached = thumbnailCache.removeValue(forKey: relativePath) {
                thumbnailCacheBytes -= cached.count
            }
            removed += 1
        }
        if removed > 0 {
            Log.shared.info("Clipboard image sweep removed \(removed) orphan file(s)", source: "storage")
        }
        return removed
    }

    /// One VACUUM after the BLOB migration, requested by the migrator so it can
    /// run off the main thread instead of blocking launch.
    public func vacuumAfterClipboardMigration() throws {
        guard try metaValue("clipboard_vacuum_pending") == "1" else { return }
        hasVacuumed = true
        try execute("VACUUM;")
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
        try setMeta("clipboard_vacuum_pending", value: nil)
    }

    public func clipboardCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM clipboard;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    // MARK: - Web apps

    public func webApps() throws -> [WebApp] {
        let statement = try prepare("SELECT id, name, url, created, shortcut FROM webapps ORDER BY created DESC;")
        defer { sqlite3_finalize(statement) }
        var result: [WebApp] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0),
                  let name = sqlite3_column_text(statement, 1),
                  let url = sqlite3_column_text(statement, 2) else { continue }
            let shortcut = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            result.append(WebApp(
                id: String(cString: id),
                name: String(cString: name),
                url: String(cString: url),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                shortcut: shortcut
            ))
        }
        return result
    }

    @discardableResult
    public func addWebApp(name: String, url: String, shortcut: String? = nil, at date: Date = Date()) throws -> WebApp {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
        let finalName = trimmedName.isEmpty ? fallback : trimmedName
        let id = UUID().uuidString

        let statement = try prepare("""
        INSERT INTO webapps (id, name, url, created, shortcut) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(url) DO UPDATE SET name = excluded.name, shortcut = COALESCE(excluded.shortcut, webapps.shortcut);
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        bind(statement, 2, finalName)
        bind(statement, 3, url)
        sqlite3_bind_double(statement, 4, date.timeIntervalSince1970)
        bind(statement, 5, shortcut)
        try step(statement)

        let lookup = try prepare("SELECT id, name, url, created, shortcut FROM webapps WHERE url = ?;")
        defer { sqlite3_finalize(lookup) }
        bind(lookup, 1, url)
        guard sqlite3_step(lookup) == SQLITE_ROW,
              let storedID = sqlite3_column_text(lookup, 0),
              let storedName = sqlite3_column_text(lookup, 1),
              let storedURL = sqlite3_column_text(lookup, 2) else {
            throw ProviderError.failed("Could not save the web app")
        }
        return WebApp(
            id: String(cString: storedID),
            name: String(cString: storedName),
            url: String(cString: storedURL),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(lookup, 3)),
            shortcut: sqlite3_column_text(lookup, 4).map { String(cString: $0) }
        )
    }

    public func updateWebAppShortcut(id: String, shortcut: String?) throws {
        let statement = try prepare("UPDATE webapps SET shortcut = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, shortcut)
        bind(statement, 2, id)
        try step(statement)
    }

    public func deleteWebApp(id: String) throws {
        let statement = try prepare("DELETE FROM webapps WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        try step(statement)

        let usage = try prepare("DELETE FROM items WHERE id = ?;")
        defer { sqlite3_finalize(usage) }
        bind(usage, 1, "web:\(id)")
        try step(usage)
    }

    // MARK: - Pins

    @discardableResult
    public func pinItem(_ item: PaletteItem, at date: Date = Date()) throws -> Bool {
        let payload = try JSONEncoder().encode(item)
        guard let text = String(data: payload, encoding: .utf8) else { return false }
        let statement = try prepare("""
        INSERT INTO pins (id, provider, payload, created) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET provider = excluded.provider,
            payload = excluded.payload, created = excluded.created;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, item.stableID)
        bind(statement, 2, item.providerID)
        bind(statement, 3, text)
        sqlite3_bind_double(statement, 4, date.timeIntervalSince1970)
        try step(statement)
        return true
    }

    public func unpinItem(id: String) throws {
        let statement = try prepare("DELETE FROM pins WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        try step(statement)
    }

    public func pinnedItems() throws -> [PaletteItem] {
        let statement = try prepare("SELECT payload FROM pins ORDER BY created DESC;")
        defer { sqlite3_finalize(statement) }
        var items: [PaletteItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let data = Data(String(cString: raw).utf8)
            if let item = try? JSONDecoder().decode(PaletteItem.self, from: data) {
                items.append(item)
            }
        }
        return items
    }

    // MARK: - Ask history

    @discardableResult
    public func insertAsk(
        question: String,
        answer: String,
        model: String,
        provider: String,
        durationMs: Int,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        error: String? = nil,
        maxHistory: Int,
        retentionDays: Int,
        at date: Date = Date()
    ) throws -> AskRecord {
        let record = AskRecord(
            id: UUID().uuidString,
            question: question,
            answer: answer,
            model: model,
            provider: provider,
            createdAt: date,
            durationMs: max(0, durationMs),
            promptTokens: max(0, promptTokens),
            completionTokens: max(0, completionTokens),
            error: error
        )
        let statement = try prepare("""
        INSERT INTO ask_history
            (id, question, answer, model, provider, created, duration_ms,
             prompt_tokens, completion_tokens, error)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, record.id)
        bind(statement, 2, record.question)
        bind(statement, 3, record.answer)
        bind(statement, 4, record.model)
        bind(statement, 5, record.provider)
        sqlite3_bind_double(statement, 6, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 7, Int64(record.durationMs))
        sqlite3_bind_int64(statement, 8, Int64(record.promptTokens))
        sqlite3_bind_int64(statement, 9, Int64(record.completionTokens))
        bind(statement, 10, record.error)
        try step(statement)
        try trimAskHistory(maxHistory: maxHistory, retentionDays: retentionDays)
        return record
    }

    public func askHistory(limit: Int = 200) throws -> [AskRecord] {
        let statement = try prepare("""
        SELECT id, question, answer, model, provider, created, duration_ms,
               prompt_tokens, completion_tokens, error
        FROM ask_history ORDER BY created DESC LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
        var records: [AskRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0),
                  let question = sqlite3_column_text(statement, 1),
                  let answer = sqlite3_column_text(statement, 2),
                  let model = sqlite3_column_text(statement, 3),
                  let provider = sqlite3_column_text(statement, 4) else { continue }
            records.append(AskRecord(
                id: String(cString: id),
                question: String(cString: question),
                answer: String(cString: answer),
                model: String(cString: model),
                provider: String(cString: provider),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                durationMs: Int(sqlite3_column_int64(statement, 6)),
                promptTokens: Int(sqlite3_column_int64(statement, 7)),
                completionTokens: Int(sqlite3_column_int64(statement, 8)),
                error: sqlite3_column_text(statement, 9).map { String(cString: $0) }
            ))
        }
        return records
    }

    public func deleteAsk(id: String) throws {
        let statement = try prepare("DELETE FROM ask_history WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        try step(statement)
    }

    public func trimAskHistory(maxHistory: Int, retentionDays: Int, now: Date = Date()) throws {
        let cutoff = now.timeIntervalSince1970 - TimeInterval(max(1, retentionDays) * 24 * 60 * 60)
        let expired = try prepare("DELETE FROM ask_history WHERE created < ?;")
        defer { sqlite3_finalize(expired) }
        sqlite3_bind_double(expired, 1, cutoff)
        try step(expired)

        let overflow = try prepare("""
        DELETE FROM ask_history WHERE id NOT IN (
            SELECT id FROM ask_history ORDER BY created DESC LIMIT ?
        );
        """)
        defer { sqlite3_finalize(overflow) }
        sqlite3_bind_int(overflow, 1, Int32(max(1, maxHistory)))
        try step(overflow)
    }

    // MARK: - Saved ask chats

    @discardableResult
    public func createAskChat(
        title: String,
        model: String,
        at date: Date = Date()
    ) throws -> AskChat {
        let chat = AskChat(
            id: UUID().uuidString,
            title: title,
            model: model,
            createdAt: date,
            updatedAt: date
        )
        let statement = try prepare("""
        INSERT INTO ask_chats (id, title, model, created, updated)
        VALUES (?, ?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, chat.id)
        bind(statement, 2, chat.title)
        bind(statement, 3, chat.model)
        sqlite3_bind_double(statement, 4, chat.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, chat.updatedAt.timeIntervalSince1970)
        try step(statement)
        return chat
    }

    public func askChats(limit: Int = 200) throws -> [AskChat] {
        let statement = try prepare("""
        SELECT id, title, model, created, updated
        FROM ask_chats ORDER BY updated DESC LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
        var chats: [AskChat] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0),
                  let title = sqlite3_column_text(statement, 1),
                  let model = sqlite3_column_text(statement, 2) else { continue }
            chats.append(AskChat(
                id: String(cString: id),
                title: String(cString: title),
                model: String(cString: model),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            ))
        }
        return chats
    }

    @discardableResult
    public func appendAskChatMessage(
        chatID: String,
        role: AskMessage.Role,
        content: String,
        durationMs: Int = 0,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        sources: [AskSource] = [],
        at date: Date = Date()
    ) throws -> AskChatMessage {
        let message = AskChatMessage(
            id: UUID().uuidString,
            chatID: chatID,
            role: role,
            content: content,
            createdAt: date,
            durationMs: max(0, durationMs),
            promptTokens: max(0, promptTokens),
            completionTokens: max(0, completionTokens),
            sources: sources
        )
        let statement = try prepare("""
        INSERT INTO ask_chat_messages
            (id, chat_id, role, content, created, duration_ms,
             prompt_tokens, completion_tokens, sources)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, message.id)
        bind(statement, 2, message.chatID)
        bind(statement, 3, message.role.rawValue)
        bind(statement, 4, message.content)
        sqlite3_bind_double(statement, 5, message.createdAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 6, Int64(message.durationMs))
        sqlite3_bind_int64(statement, 7, Int64(message.promptTokens))
        sqlite3_bind_int64(statement, 8, Int64(message.completionTokens))
        let sourcesText = message.sources.isEmpty
            ? nil
            : (try? JSONEncoder().encode(message.sources))
                .flatMap { String(data: $0, encoding: .utf8) }
        bind(statement, 9, sourcesText)
        try step(statement)

        // Each turn moves its chat to the top of the sidebar.
        let touch = try prepare("UPDATE ask_chats SET updated = ? WHERE id = ?;")
        defer { sqlite3_finalize(touch) }
        sqlite3_bind_double(touch, 1, date.timeIntervalSince1970)
        bind(touch, 2, chatID)
        try step(touch)
        return message
    }

    public func askChatMessages(chatID: String) throws -> [AskChatMessage] {
        let statement = try prepare("""
        SELECT id, chat_id, role, content, created, duration_ms,
               prompt_tokens, completion_tokens, sources
        FROM ask_chat_messages WHERE chat_id = ? ORDER BY created ASC;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, chatID)
        var messages: [AskChatMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0),
                  let chat = sqlite3_column_text(statement, 1),
                  let role = sqlite3_column_text(statement, 2),
                  let content = sqlite3_column_text(statement, 3) else { continue }
            let sources = sqlite3_column_text(statement, 8)
                .flatMap { String(cString: $0).data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([AskSource].self, from: $0) } ?? []
            messages.append(AskChatMessage(
                id: String(cString: id),
                chatID: String(cString: chat),
                role: AskMessage.Role(rawValue: String(cString: role)) ?? .assistant,
                content: String(cString: content),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                durationMs: Int(sqlite3_column_int64(statement, 5)),
                promptTokens: Int(sqlite3_column_int64(statement, 6)),
                completionTokens: Int(sqlite3_column_int64(statement, 7)),
                sources: sources
            ))
        }
        return messages
    }

    public func updateAskChat(
        id: String,
        model: String? = nil,
        at date: Date = Date()
    ) throws {
        let statement = try prepare("""
        UPDATE ask_chats
        SET model = COALESCE(?, model), updated = ?
        WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, model)
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        bind(statement, 3, id)
        try step(statement)
    }

    public func deleteAskChat(id: String) throws {
        let statement = try prepare("DELETE FROM ask_chats WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        try step(statement)
    }

    // MARK: - Scratch notes

    @discardableResult
    public func saveScratchNote(
        id: String? = nil,
        title: String,
        text: String,
        at date: Date = Date()
    ) throws -> ScratchNote {
        let noteID = id ?? UUID().uuidString
        let existing = try scratchNote(id: noteID)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedTitle = String((trimmedTitle.isEmpty ? fallback : trimmedTitle).prefix(80))
        let finalTitle = resolvedTitle.isEmpty ? "Untitled note" : resolvedTitle
        let created = existing?.createdAt ?? date

        let statement = try prepare("""
        INSERT INTO scratch_notes (id, title, text, created, updated) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET title = excluded.title,
            text = excluded.text, updated = excluded.updated;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, noteID)
        bind(statement, 2, finalTitle)
        bind(statement, 3, text)
        sqlite3_bind_double(statement, 4, created.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, date.timeIntervalSince1970)
        try step(statement)

        return ScratchNote(id: noteID, title: finalTitle, text: text, createdAt: created, updatedAt: date)
    }

    public func scratchNote(id: String) throws -> ScratchNote? {
        let statement = try prepare("""
        SELECT id, title, text, created, updated FROM scratch_notes WHERE id = ? LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let idText = sqlite3_column_text(statement, 0),
              let titleText = sqlite3_column_text(statement, 1),
              let bodyText = sqlite3_column_text(statement, 2) else { return nil }
        return ScratchNote(
            id: String(cString: idText),
            title: String(cString: titleText),
            text: String(cString: bodyText),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        )
    }

    public func scratchNotes(limit: Int = 200) throws -> [ScratchNote] {
        let statement = try prepare("""
        SELECT id, title, text, created, updated FROM scratch_notes
        ORDER BY updated DESC LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
        var notes: [ScratchNote] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let titleText = sqlite3_column_text(statement, 1),
                  let bodyText = sqlite3_column_text(statement, 2) else { continue }
            notes.append(ScratchNote(
                id: String(cString: idText),
                title: String(cString: titleText),
                text: String(cString: bodyText),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            ))
        }
        return notes
    }

    public func deleteScratchNote(id: String) throws {
        let statement = try prepare("DELETE FROM scratch_notes WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        try step(statement)
    }

    // MARK: - Metadata

    public func metaValue(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM meta WHERE key = ?;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    public func setMeta(_ key: String, value: String?) throws {
        if let value {
            let statement = try prepare("""
            INSERT INTO meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, key)
            bind(statement, 2, value)
            try step(statement)
        } else {
            let statement = try prepare("DELETE FROM meta WHERE key = ?;")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, key)
            try step(statement)
        }
    }

    private func trimClipboard(maxEntries: Int) throws {
        let doomed = try stringValues("""
        SELECT id FROM clipboard
        WHERE pinned = 0 AND id NOT IN (
            SELECT id FROM clipboard WHERE pinned = 0 ORDER BY created DESC LIMIT \(max(1, maxEntries))
        );
        """)
        guard !doomed.isEmpty else { return }
        let paths = try imageRelativePaths(forIDs: doomed)
        try deleteClipboardRows(ids: doomed)
        try releaseImageFiles(paths)
    }

    // MARK: - Retention

    /// Age-based clipboard retention, an image byte cap (oldest first) and the
    /// same `[ask] retention_days` applied to saved chats. Safe to call on
    /// launch and periodically; a large trim checkpoints the WAL, and a file
    /// that shrank by more than 20% is vacuumed once per launch.
    @discardableResult
    public func maintain(
        clipboardRetentionDays: Int,
        maxImageBytes: Int,
        askRetentionDays: Int,
        now: Date = Date()
    ) throws -> MaintenanceReport {
        let before = Self.totalBytes(of: filePath)
        var report = MaintenanceReport(bytesBefore: before)

        if clipboardRetentionDays > 0 {
            let cutoff = now.timeIntervalSince1970 - TimeInterval(clipboardRetentionDays * 24 * 60 * 60)
            let expired = try prepare("SELECT id FROM clipboard WHERE pinned = 0 AND created < ?;")
            sqlite3_bind_double(expired, 1, cutoff)
            var doomed: [String] = []
            while sqlite3_step(expired) == SQLITE_ROW {
                if let idText = sqlite3_column_text(expired, 0) {
                    doomed.append(String(cString: idText))
                }
            }
            sqlite3_finalize(expired)
            if !doomed.isEmpty {
                let paths = try imageRelativePaths(forIDs: doomed)
                try deleteClipboardRows(ids: doomed)
                try releaseImageFiles(paths)
                report.clipboardRemoved += doomed.count
            }
        }

        if maxImageBytes >= 0 {
            let total = try intValue("""
            SELECT COALESCE(SUM(ci.byte_count), 0) FROM clipboard c
            JOIN clipboard_images ci ON ci.clipboard_id = c.id
            WHERE c.kind = 'image';
            """)
            if total > maxImageBytes {
                let statement = try prepare("""
                SELECT c.id, ci.byte_count FROM clipboard c
                JOIN clipboard_images ci ON ci.clipboard_id = c.id
                WHERE c.kind = 'image' AND c.pinned = 0 ORDER BY c.created ASC;
                """)
                var excess = total - maxImageBytes
                var doomed: [String] = []
                while sqlite3_step(statement) == SQLITE_ROW, excess > 0 {
                    if let idText = sqlite3_column_text(statement, 0) {
                        doomed.append(String(cString: idText))
                    }
                    excess -= Int(sqlite3_column_int64(statement, 1))
                }
                sqlite3_finalize(statement)
                if !doomed.isEmpty {
                    let paths = try imageRelativePaths(forIDs: doomed)
                    try deleteClipboardRows(ids: doomed)
                    try releaseImageFiles(paths)
                    report.clipboardRemoved += doomed.count
                }
            }
        }

        if askRetentionDays > 0 {
            let cutoff = now.timeIntervalSince1970 - TimeInterval(askRetentionDays * 24 * 60 * 60)
            // Deleting a chat cascades its messages (foreign_keys=ON).
            let expired = try prepare("DELETE FROM ask_chats WHERE updated < ?;")
            sqlite3_bind_double(expired, 1, cutoff)
            try step(expired)
            sqlite3_finalize(expired)
            report.chatsRemoved = Int(sqlite3_changes(database))
        }

        if report.clipboardRemoved > 0 || report.chatsRemoved > 0 {
            try execute("PRAGMA wal_checkpoint(TRUNCATE);")
        }
        if report.clipboardRemoved > 0 {
            clipboardRevisionValue += 1
        }

        var after = Self.totalBytes(of: filePath)
        // Deleted pages go on SQLite's freelist, so the file itself does not
        // shrink until VACUUM. Treat >20% free pages (or an actual shrink) as
        // "large enough to rewrite", at most once per launch.
        let pageSize = try intValue("PRAGMA page_size;")
        let freeBytes = Int64(try intValue("PRAGMA freelist_count;") * max(1, pageSize))
        let shrank = before > 0 && Double(before - after) / Double(before) > 0.2
        if !hasVacuumed, before > 0, shrank || Double(freeBytes) / Double(before) > 0.2 {
            hasVacuumed = true
            try execute("VACUUM;")
            // VACUUM writes the rewritten pages through the WAL in WAL mode;
            // checkpoint so the reported size is the file actually on disk.
            try execute("PRAGMA wal_checkpoint(TRUNCATE);")
            report.vacuumed = true
            after = Self.totalBytes(of: filePath)
        }
        report.bytesAfter = after
        return report
    }

    private func intValue(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// SQLite's own size: the main file plus a possibly large WAL.
    private static func totalBytes(of path: String) -> Int64 {
        let manager = FileManager.default
        return ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
            let attributes = try? manager.attributesOfItem(atPath: path + suffix)
            return total + Int64((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    // MARK: - SQLite helpers

    private func execute(_ sql: String) throws {
        try Self.execute(sql, on: database)
    }

    private static func execute(_ sql: String, on database: OpaquePointer?) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &error)
        if status != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            throw ProviderError.failed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProviderError.failed(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func step(_ statement: OpaquePointer?) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw ProviderError.failed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
}
