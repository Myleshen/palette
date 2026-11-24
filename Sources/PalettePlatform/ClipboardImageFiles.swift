import CryptoKit
import Foundation
import PaletteCore

/// Content-addressed clipboard image files under the state directory:
/// `images/<first2>/<sha256>.png` and `thumbs/<first2>/<sha256>.png`. Identical
/// bytes always map to one file, and paths stay relative so the state directory
/// can move. Files are written 0600 and read back to prove the write landed.
public struct ClipboardImageFiles: Sendable {
    public enum Folder: String, Sendable {
        case images
        case thumbs
    }

    public struct Stored: Sendable, Equatable {
        public let sha256: String
        public let relativePath: String
        public let byteCount: Int

        public init(sha256: String, relativePath: String, byteCount: Int) {
            self.sha256 = sha256
            self.relativePath = relativePath
            self.byteCount = byteCount
        }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The default root for a database: `clipboard/` beside `palette.sqlite`.
    public static func defaultDirectory(forDatabase path: String) -> URL {
        URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appendingPathComponent("clipboard", isDirectory: true)
    }

    public func fileURL(forRelativePath relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else { return nil }
        return directory.appendingPathComponent(relativePath)
    }

    /// Writes `data` under its content hash and returns the relative path.
    /// Reuses an existing file only after comparing its bytes.
    @discardableResult
    public func store(_ data: Data, in folder: Folder) throws -> Stored {
        let sha = Self.sha256(data)
        let relativePath = "\(folder.rawValue)/\(sha.prefix(2))/\(sha).png"
        guard let url = fileURL(forRelativePath: relativePath) else {
            throw ProviderError.failed("Invalid clipboard image path")
        }
        if let existing = try? Data(contentsOf: url), existing == data {
            return Stored(sha256: sha, relativePath: relativePath, byteCount: data.count)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard try Data(contentsOf: url) == data else {
            throw ProviderError.failed("Clipboard image write did not verify")
        }
        return Stored(sha256: sha, relativePath: relativePath, byteCount: data.count)
    }

    public func read(relativePath: String) -> Data? {
        guard let url = fileURL(forRelativePath: relativePath) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// A cheap stat, so a cached read can notice a file deleted outside Palette.
    public func exists(relativePath: String) -> Bool {
        guard let url = fileURL(forRelativePath: relativePath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func delete(relativePath: String) throws {
        guard let url = fileURL(forRelativePath: relativePath) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Every file currently on disk, as relative paths. Used by the orphan sweep.
    public func allRelativePaths() -> [String] {
        var paths: [String] = []
        let manager = FileManager.default
        for folder in [Folder.images, Folder.thumbs] {
            let root = directory.appendingPathComponent(folder.rawValue, isDirectory: true)
            guard let subpaths = try? manager.subpathsOfDirectory(atPath: root.path) else { continue }
            for subpath in subpaths {
                var isDirectory: ObjCBool = false
                let full = root.appendingPathComponent(subpath).path
                guard manager.fileExists(atPath: full, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { continue }
                paths.append("\(folder.rawValue)/\(subpath)")
            }
        }
        return paths
    }
}
