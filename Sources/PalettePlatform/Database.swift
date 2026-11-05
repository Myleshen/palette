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

public actor PaletteStore {
    private var database: OpaquePointer?

    public init(path: String) throws {
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
        try Self.migrate(handle)
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    private static func migrate(_ database: OpaquePointer?) throws {
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
            image BLOB,
            thumbnail BLOB,
            width INTEGER NOT NULL DEFAULT 0,
            height INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS clipboard_created ON clipboard(created DESC);

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

        CREATE TABLE IF NOT EXISTS scratch_notes (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            text TEXT NOT NULL,
            created REAL NOT NULL,
            updated REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS scratch_notes_updated ON scratch_notes(updated DESC);
        """, on: database)

        if try !hasColumn("webapps", "shortcut", on: database) {
            try execute("ALTER TABLE webapps ADD COLUMN shortcut TEXT;", on: database)
        }
        if try !hasColumn("clipboard", "kind", on: database) {
            try execute("ALTER TABLE clipboard ADD COLUMN kind TEXT NOT NULL DEFAULT 'text';", on: database)
        }
        if try !hasColumn("clipboard", "image", on: database) {
            try execute("ALTER TABLE clipboard ADD COLUMN image BLOB;", on: database)
        }
        if try !hasColumn("clipboard", "thumbnail", on: database) {
            try execute("ALTER TABLE clipboard ADD COLUMN thumbnail BLOB;", on: database)
        }
        if try !hasColumn("clipboard", "width", on: database) {
            try execute("ALTER TABLE clipboard ADD COLUMN width INTEGER NOT NULL DEFAULT 0;", on: database)
        }
        if try !hasColumn("clipboard", "height", on: database) {
            try execute("ALTER TABLE clipboard ADD COLUMN height INTEGER NOT NULL DEFAULT 0;", on: database)
        }
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
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let existing = try clipboardContains(hash: hash)
        let statement = try prepare("""
        INSERT INTO clipboard (id, hash, text, created, pinned, kind, image, thumbnail, width, height)
        VALUES (?, ?, '', ?, 0, 'image', ?, ?, ?, ?)
        ON CONFLICT(hash) DO UPDATE SET created = excluded.created;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, UUID().uuidString)
        bind(statement, 2, hash)
        sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
        sqlite3_bind_blob(statement, 4, (png as NSData).bytes, Int32(png.count), sqliteTransient)
        if let thumbnail {
            sqlite3_bind_blob(statement, 5, (thumbnail as NSData).bytes, Int32(thumbnail.count), sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        sqlite3_bind_int(statement, 6, Int32(width))
        sqlite3_bind_int(statement, 7, Int32(height))
        try step(statement)
        try trimClipboard(maxEntries: maxEntries)
        return !existing
    }

    public func clipboardImage(id: String) throws -> Data? {
        let statement = try prepare("SELECT image FROM clipboard WHERE id = ? AND kind = 'image' LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }

    public func clipboardThumbnail(id: String) throws -> Data? {
        let statement = try prepare("SELECT thumbnail FROM clipboard WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
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
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let existing = try clipboardContains(hash: hash)

        let statement = try prepare("""
        INSERT INTO clipboard (id, hash, text, created, pinned, kind, thumbnail)
        VALUES (?, ?, ?, ?, 0, 'files', ?)
        ON CONFLICT(hash) DO UPDATE SET created = excluded.created;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, UUID().uuidString)
        bind(statement, 2, hash)
        bind(statement, 3, text)
        sqlite3_bind_double(statement, 4, date.timeIntervalSince1970)
        if let thumbnail {
            sqlite3_bind_blob(statement, 5, (thumbnail as NSData).bytes, Int32(thumbnail.count), sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        try step(statement)
        try trimClipboard(maxEntries: maxEntries)
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
            conditions.append("text LIKE ? ESCAPE '\\'")
        }
        if kind != nil {
            conditions.append("kind = ?")
        }
        let thumbnailColumn = includeThumbnails ? "thumbnail" : "NULL"
        var sql = "SELECT id, text, created, pinned, kind, width, height, \(thumbnailColumn) FROM clipboard"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY pinned DESC, created DESC LIMIT ?;"

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
            guard let idText = sqlite3_column_text(statement, 0),
                  let bodyText = sqlite3_column_text(statement, 1) else { continue }
            let kind = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "text"
            var thumbnail: Data?
            if sqlite3_column_type(statement, 7) != SQLITE_NULL,
               let bytes = sqlite3_column_blob(statement, 7) {
                let count = Int(sqlite3_column_bytes(statement, 7))
                if count > 0 { thumbnail = Data(bytes: bytes, count: count) }
            }
            entries.append(ClipboardEntry(
                id: String(cString: idText),
                text: String(cString: bodyText),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                pinned: sqlite3_column_int(statement, 3) != 0,
                kind: ClipboardKind(rawValue: kind) ?? .text,
                imageWidth: Int(sqlite3_column_int(statement, 5)),
                imageHeight: Int(sqlite3_column_int(statement, 6)),
                thumbnailPNG: thumbnail
            ))
        }
        return entries
    }

    public func clipboardEntry(id: String) throws -> ClipboardEntry? {
        let statement = try prepare("""
        SELECT id, text, created, pinned, kind, width, height, thumbnail
        FROM clipboard WHERE id = ? LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let idText = sqlite3_column_text(statement, 0),
              let bodyText = sqlite3_column_text(statement, 1) else { return nil }
        let kind = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "text"
        var thumbnail: Data?
        if sqlite3_column_type(statement, 7) != SQLITE_NULL,
           let bytes = sqlite3_column_blob(statement, 7) {
            let count = Int(sqlite3_column_bytes(statement, 7))
            if count > 0 { thumbnail = Data(bytes: bytes, count: count) }
        }
        return ClipboardEntry(
            id: String(cString: idText),
            text: String(cString: bodyText),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            pinned: sqlite3_column_int(statement, 3) != 0,
            kind: ClipboardKind(rawValue: kind) ?? .text,
            imageWidth: Int(sqlite3_column_int(statement, 5)),
            imageHeight: Int(sqlite3_column_int(statement, 6)),
            thumbnailPNG: thumbnail
        )
    }

    public func deleteClipboard(id: String) throws {
        let statement = try prepare("DELETE FROM clipboard WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        try step(statement)
    }

    public func setClipboardPinned(id: String, pinned: Bool) throws {
        let statement = try prepare("UPDATE clipboard SET pinned = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, pinned ? 1 : 0)
        bind(statement, 2, id)
        try step(statement)
    }

    public func clearClipboard() throws {
        try execute("DELETE FROM clipboard WHERE pinned = 0;")
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
        let statement = try prepare("""
        DELETE FROM clipboard
        WHERE pinned = 0 AND id NOT IN (
            SELECT id FROM clipboard ORDER BY pinned DESC, created DESC LIMIT ?
        );
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, maxEntries)))
        try step(statement)
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
