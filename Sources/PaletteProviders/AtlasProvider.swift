import CommonCrypto
import Foundation
import PaletteCore
import PalettePlatform

/// Documents and artifacts tracked by `atlas` (`brew install Myleshen/tap/atlas`).
///
/// Atlas keeps its index in `~/.config/atlas/state.json`; the marker, mtime and
/// Markdown preview path are derived here exactly as atlas derives them, so the
/// review inbox matches the `~/atlas.html` page.
public final class AtlasProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "atlas",
        name: "Atlas",
        trigger: "atlas",
        isGlobal: false,
        priority: 46,
        icon: "symbol:book.closed",
        keywords: ["atlas", "index", "artifacts", "docs", "notes", "review", "inbox"]
    )

    private struct Config: Sendable {
        var stateFile: URL
        var previewDirectory: URL
        var home: String
        var roots: [String]
    }

    private struct Entry: Sendable {
        var path: String
        var title: String
        var summary: String
        var project: String
        var kind: String
        var lastSeen: String
        var mtime: Double
        var marked: Bool
        var relativePath: String

        /// Mirrors atlas's `inbox_items` exactly: only artifacts that carry the
        /// review marker. Acking a file removes the marker, so it leaves the
        /// inbox; nothing queues by default.
        var isInbox: Bool { kind == "artifact" && marked }

        /// What the matcher and the fzf filter see. No file contents.
        var haystack: String { "\(title) \(relativePath) \(summary)" }
    }

    private struct Snapshot: Sendable {
        var entries: [Entry]
        var stateFound: Bool
    }

    private actor Cache {
        private var snapshot: (key: String, value: Snapshot)?
        /// Preview HTML path per `path|mtime`, built only for the rows a search
        /// actually returns.
        private var previews: [String: String?] = [:]

        /// Keyed by state.json's mtime and size: atlas rewrites it on every run,
        /// so nothing is re-parsed or re-read while the index is unchanged.
        func load(_ config: Config) -> Snapshot {
            let key = AtlasProvider.stateKey(config.stateFile)
            if let snapshot, snapshot.key == key { return snapshot.value }
            let fresh = AtlasProvider.load(config)
            snapshot = (key, fresh)
            previews.removeAll()
            return fresh
        }

        func preview(for entry: Entry, config: Config) -> String? {
            let key = "\(entry.path)|\(entry.mtime)"
            if let cached = previews[key] { return cached }
            let preview = AtlasProvider.previewPath(entry, config: config)
            if previews.count > 512 { previews.removeAll() }
            previews[key] = preview
            return preview
        }

        func invalidate() {
            snapshot = nil
            previews.removeAll()
        }
    }

    private let config: Config
    private let bridge: HostBridge?
    /// Resolves the atlas binary. A seam for tests: a machine that has atlas
    /// installed cannot otherwise exercise the missing-tool path.
    private let toolPath: () -> String?
    private let cache = Cache()

    public init(
        bridge: HostBridge? = nil,
        stateFile: URL = AtlasProvider.defaultStateFile,
        previewDirectory: URL = AtlasProvider.defaultPreviewDirectory,
        home: String = NSHomeDirectory(),
        toolPath: @escaping () -> String? = { ToolLocator.shared.path(for: "atlas") }
    ) {
        self.bridge = bridge
        self.toolPath = toolPath
        let home = PathExpansion.expand(home)
        self.config = Config(
            stateFile: stateFile,
            previewDirectory: previewDirectory,
            home: home,
            roots: ["dev", "learning", "Downloads", "dot-files"].map { home + "/" + $0 }
        )
    }

    public static var defaultStateFile: URL {
        URL(fileURLWithPath: PathExpansion.expand("~/.config/atlas/state.json"))
    }

    public static var defaultPreviewDirectory: URL {
        URL(fileURLWithPath: PathExpansion.expand("~/.cache/atlas/preview"), isDirectory: true)
    }

    public static var indexFile: String {
        PathExpansion.expand("~/atlas.html")
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let snapshot = await cache.load(config)
        guard snapshot.stateFound, !snapshot.entries.isEmpty else {
            // Global providers run on every search: offer the setup row only
            // when the user asked for atlas explicitly.
            return request.isBound ? [setupItem()] : []
        }
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = snapshot.entries.map(\.haystack)
        let indices = await RowFilter.matchingIndices(query: query, candidates: candidates)
        let matched = indices.map { index -> (entry: Entry, score: Double) in
            let entry = snapshot.entries[index]
            let score = query.isEmpty ? 0 : (Ranking.score(query: query, candidate: candidates[index]) ?? 0)
            return (entry, score)
        }
        // Inbox first, then relevance; an empty query keeps newest first, which
        // is what the review queue wants.
        let sorted = matched.sorted { lhs, rhs in
            if lhs.entry.isInbox != rhs.entry.isInbox { return lhs.entry.isInbox }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.entry.lastSeen != rhs.entry.lastSeen { return lhs.entry.lastSeen > rhs.entry.lastSeen }
            if lhs.entry.mtime != rhs.entry.mtime { return lhs.entry.mtime > rhs.entry.mtime }
            return lhs.entry.path < rhs.entry.path
        }
        // Preview work stays on the rows on screen.
        var items: [PaletteItem] = []
        for (entry, score) in sorted.prefix(100) {
            items.append(await item(entry, score: score))
        }
        return items
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        // open, reveal, copy-path and open-index are host-side action kinds;
        // only the review round trip runs here.
        guard action.id == "review",
              let value = action.value.text,
              value.hasPrefix("review:") else { return }
        let path = String(value.dropFirst("review:".count))
        guard let tool = toolPath() else {
            await bridge?.notify("atlas is not installed")
            throw ProviderError.toolMissing("atlas")
        }
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run([tool, "review", path], timeout: 30)
        } catch {
            await bridge?.notify("atlas review failed: \(error.localizedDescription)")
            throw error
        }
        await cache.invalidate()
        guard result.status == 0 else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            await bridge?.notify("atlas review failed: \(message.isEmpty ? "exit \(result.status)" : message)")
            throw ProviderError.failed(message.isEmpty ? "atlas review failed" : message)
        }
        await bridge?.notify("Reviewed \(item.title)")
    }

    // MARK: - Rows

    private func item(_ entry: Entry, score: Double) async -> PaletteItem {
        let path = entry.path
        var actions = [
            PaletteAction(id: "open", title: "Open", kind: .openPath, value: .text(path)),
            PaletteAction(id: "reveal", title: "Reveal in Finder", kind: .reveal, value: .text(path)),
            PaletteAction(id: "copy-path", title: "Copy Path", kind: .copyText, value: .text(path)),
            PaletteAction(id: "open-index", title: "Open Atlas Index", kind: .openPath, value: .text(Self.indexFile)),
        ]
        // Only the review inbox carries the marker; acked files have nothing
        // to mark, and atlas would refuse the round trip.
        if entry.isInbox {
            actions.insert(
                PaletteAction(id: "review", title: "Mark Reviewed", kind: .custom, value: .text("review:\(path)")),
                at: 1
            )
        }
        let previewPath = await cache.preview(for: entry, config: config)
        return PaletteItem(
            id: path,
            title: entry.title,
            subtitle: "\(entry.project) · \(entry.relativePath)",
            icon: .file(path),
            badge: entry.isInbox ? "review" : nil,
            group: entry.project,
            score: 1_000 + score,
            actions: actions,
            preview: preview(entry, previewPath: previewPath),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func preview(_ entry: Entry, previewPath: String?) -> ItemPreview {
        // The generated HTML is a whole page; inside the pane it renders at a
        // fraction of its size and is unreadable. Show the source text instead.
        let ext = (entry.path as NSString).pathExtension.lowercased()
        if ext == "md" || ext == "markdown",
           let text = try? String(contentsOfFile: entry.path, encoding: .utf8) {
            let body = AtlasProvider.stripFrontMatter(text)
            let limit = 6_000
            return .text(body.count > limit ? String(body.prefix(limit)) + "\n…" : body)
        }
        if let previewPath {
            return .document(url: previewPath, kind: "html")
        }
        if ext == "html" || ext == "htm" {
            return .document(url: entry.path, kind: "html")
        }
        return .files(paths: [entry.path])
    }

    private func setupItem() -> PaletteItem {
        // The folder exists but atlas itself may be the missing piece.
        let atlasMissing = toolPath() == nil
        let requirement = ProviderRequirements.requirements(forProviderID: descriptor.id).first
        return PaletteItem(
            id: "atlas:setup",
            title: atlasMissing ? "Install atlas" : "Atlas state not found — run `atlas`",
            subtitle: atlasMissing ? requirement?.install : config.stateFile.path,
            icon: .symbol("book.closed"),
            badge: "SETUP",
            score: 10_000,
            actions: [PaletteAction(
                id: "reveal",
                title: "Reveal Atlas State Folder",
                kind: .reveal,
                value: .text(config.stateFile.deletingLastPathComponent().path)
            )],
            preview: .text("Run `atlas` to build the index at ~/atlas.html, then reopen Palette."),
            trouble: atlasMissing ? requirement.map(ItemTrouble.missingTool) : nil,
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    // MARK: - Loading

    private struct StoredState: Decodable {
        var files: [String: StoredFile]
    }

    private struct StoredFile: Decodable {
        var title: String?
        var summary: String?
        var project: String?
        var kind: String?
        var last_seen: String?
        var removed_on: String?
    }

    private static func stateKey(_ url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return "missing"
        }
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return "\(mtime)|\(size)"
    }

    private static func load(_ config: Config) -> Snapshot {
        guard let data = try? Data(contentsOf: config.stateFile),
              let state = try? JSONDecoder().decode(StoredState.self, from: data) else {
            return Snapshot(entries: [], stateFound: false)
        }
        let manager = FileManager.default
        var entries: [Entry] = []
        for (path, stored) in state.files {
            // Tombstones and files deleted since the last atlas run have no row.
            guard stored.removed_on == nil,
                  let attributes = try? manager.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date else { continue }
            let ext = (path as NSString).pathExtension.lowercased()
            let isMarkdown = ext == "md" || ext == "markdown"
            let isHTML = ext == "html" || ext == "htm"
            // The inbox flag needs the marker, which lives in the front matter
            // or the `<head>`. Read the head only; the full text and the
            // preview digest wait until a row is actually shown.
            let head = isMarkdown || isHTML ? readHead(path) : nil
            let marked = head.map { hasMarker($0, isMarkdown: isMarkdown) } ?? false
            let root = config.roots.first { path.hasPrefix($0 + "/") }
            let relative = root.map { String(path.dropFirst($0.count + 1)) }
                ?? path.replacingOccurrences(of: config.home + "/", with: "")
            let project = (stored.project?.isEmpty == false ? stored.project : nil)
                ?? relative.split(separator: "/").first.map(String.init)
                ?? ""
            entries.append(Entry(
                path: path,
                title: stored.title.flatMap { $0.isEmpty ? nil : $0 }
                    ?? (path as NSString).lastPathComponent,
                summary: stored.summary ?? "",
                project: project,
                kind: stored.kind ?? "doc",
                lastSeen: stored.last_seen ?? "",
                mtime: modified.timeIntervalSince1970,
                marked: marked,
                relativePath: relative
            ))
        }
        return Snapshot(entries: entries, stateFound: true)
    }

    /// The preview atlas wrote for this exact content, or nil when there is
    /// none. Hashing the whole file is why this is deferred to the visible rows.
    private static func previewPath(_ entry: Entry, config: Config) -> String? {
        let ext = (entry.path as NSString).pathExtension.lowercased()
        guard ext == "md" || ext == "markdown",
              let text = readText(entry.path) else { return nil }
        let candidate = config.previewDirectory
            .appendingPathComponent(previewDigest(path: entry.path, text: text) + ".html").path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    private static func readText(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        // Atlas reads with errors="replace"; decode the same way so the preview
        // hash still matches for files that are not clean UTF-8.
        return String(decoding: data, as: UTF8.self)
    }

    /// The marker only lives at the top of a file: front matter for Markdown,
    /// `<head>` for HTML. 8 KB is far past either and keeps the index scan cheap.
    private static func readHead(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return String(decoding: handle.readData(ofLength: 8_192), as: UTF8.self)
    }

    // MARK: - Atlas compatibility
    //
    // These replicate the Python helpers in `atlas` byte for byte: the preview
    // filename is a hash of the stripped content, so any drift silently loses
    // previews (rows still open the file).

    static func previewDigest(path: String, text: String) -> String {
        let stripped = stripFrontMatter(text)
        var input = Data(path.utf8)
        input.append(0)
        input.append(contentsOf: stripped.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { buffer in
            input.withUnsafeBytes {
                _ = CC_SHA1($0.baseAddress, CC_LONG(input.count), buffer.baseAddress)
            }
        }
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    static func stripFrontMatter(_ text: String) -> String {
        let lines = splitLines(text)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return text
        }
        for index in 1..<lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "---" || line == "..." {
                return lines[(index + 1)...].joined(separator: "\n")
            }
        }
        return text
    }

    static func hasMarker(_ text: String, isMarkdown: Bool) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if !isMarkdown {
            return htmlMarkerRegex.firstMatch(in: text, range: range) != nil
        }
        guard let match = frontMatterRegex.firstMatch(in: text, range: range),
              let body = Range(match.range(at: 1), in: text) else { return false }
        return splitLines(String(text[body])).contains { line in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "review" else {
                return false
            }
            let value = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return ["true", "yes", "1"].contains(value.lowercased())
        }
    }

    private static let frontMatterRegex = try! NSRegularExpression(
        pattern: "\\A---[ \\t]*\\r?\\n(.*?)(^---[ \\t]*$|^\\.\\.\\.[ \\t]*$)",
        // .useUnixLineSeparators matches Python's `$`, which ignores \r.
        options: [.dotMatchesLineSeparators, .anchorsMatchLines, .useUnixLineSeparators]
    )

    private static let htmlMarkerRegex = try! NSRegularExpression(
        pattern: "(?is)<meta\\b(?=[^>]*\\bname\\s*=\\s*[\"']?atlas-review[\"']?)[^>]*>"
    )

    /// Python's `str.splitlines()`, which also breaks on \v, \f, \x1c–\x1e, NEL
    /// and the Unicode line separators.
    static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x0A, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
                lines.append(String(current))
                current = String.UnicodeScalarView()
            case 0x0D:
                if index + 1 < scalars.count, scalars[index + 1].value == 0x0A { index += 1 }
                lines.append(String(current))
                current = String.UnicodeScalarView()
            default:
                current.append(scalar)
            }
            index += 1
        }
        if !current.isEmpty { lines.append(String(current)) }
        return lines
    }
}
