import Foundation
import PaletteCore

public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let queue = DispatchQueue(label: "dev.myleshen.palette.log")
    private var url: URL?

    public func configure(url: URL) {
        queue.sync {
            self.url = url
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
                try? line.data(using: .utf8)?.write(to: url)
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
