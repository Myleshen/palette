import AppKit
import CryptoKit
import Foundation
import PaletteCore

/// Fetches and caches site icons. Network failures are silent: a web app
/// without an icon simply keeps the globe.
public actor FaviconStore {
    public static let shared = FaviconStore()

    private let directory: URL
    private var memory: [String: String] = [:]

    public init(directory: URL? = nil) {
        let cache = PalettePaths.resolve().cacheDir.appendingPathComponent("Favicons", isDirectory: true)
        self.directory = directory ?? cache
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func icon(for urlString: String) async -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased(), !host.isEmpty else { return nil }
        if let cached = memory[host] { return cached }

        let key = SHA256.hash(data: Data(host.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(key + ".png")
        if let data = try? Data(contentsOf: file), let base64 = pngBase64(data) {
            memory[host] = base64
            return base64
        }

        guard let requestURL = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64") else { return nil }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 2.5
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let png = try? Self.pngData(from: data) else { return nil }

        try? png.write(to: file, options: .atomic)
        let base64 = png.base64EncodedString()
        memory[host] = base64
        return base64
    }

    private func pngBase64(_ data: Data) -> String? {
        guard let png = try? Self.pngData(from: data) else { return nil }
        return png.base64EncodedString()
    }

    private static func pngData(from data: Data) throws -> Data {
        guard let image = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return png
    }
}
