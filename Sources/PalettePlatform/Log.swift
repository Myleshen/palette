import Foundation
import PaletteCore

public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let queue = DispatchQueue(label: "dev.myleshen.palette.log")
    private var url: URL?

    public func configure(url: URL) {
        queue.sync {
            self.url = url
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Logs quote prompt and page text, so the file is owner-only.
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            } else {
                try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    public func write(_ level: String, _ message: String, source: String? = nil) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let prefix = source.map { "[\($0)] " } ?? ""
        let line = "\(timestamp) \(level.uppercased()) \(prefix)\(message)\n"
        queue.async {
            guard let url = self.url else { return }
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
               size.intValue > 5_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                // Rotation deletes the file, so recreate it owner-only too.
                FileManager.default.createFile(
                    atPath: url.path,
                    contents: Data(line.utf8),
                    attributes: [.posixPermissions: 0o600]
                )
            } else if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            }
        }
        FileHandle.standardError.write(Data(line.utf8))
    }

    public func info(_ message: String, source: String? = nil) { write("info", message, source: source) }
    public func warn(_ message: String, source: String? = nil) { write("warn", message, source: source) }
    public func error(_ message: String, source: String? = nil) { write("error", message, source: source) }
}
