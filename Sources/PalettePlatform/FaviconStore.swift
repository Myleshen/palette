import AppKit
import CryptoKit
import Foundation
import PaletteCore

/// Fetches and caches site icons. Network failures are silent: a web app
/// without an icon simply keeps the globe.
public actor FaviconStore {
    public static let shared = FaviconStore()

    private let directory: URL
    private var icons: [String: String] = [:]
    /// Negative results, so an offline machine probes Google once per host per
    /// session instead of once per search.
    private var misses: Set<String> = []
    /// Hosts another search is already fetching; a keystroke must not queue a
    /// second request for the same icon.
    private var inFlight: Set<String> = []
    /// Cancels a redirect off Google's origin, and is retained by the session.
    private let session: URLSession

    public init(directory: URL? = nil) {
        let cache = PalettePaths.resolve().cacheDir.appendingPathComponent("Favicons", isDirectory: true)
        self.directory = directory ?? cache
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.5
        session = URLSession(
            configuration: configuration,
            delegate: SafeURL.RedirectGuard(),
            delegateQueue: nil
        )
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Memory or disk only, never the network, so a search can show what it
    /// already has and return at once.
    public func cachedIcon(for urlString: String) async -> String? {
        guard let host = Self.host(of: urlString) else { return nil }
        if let cached = icons[host] { return cached }
        guard !misses.contains(host) else { return nil }
        guard let data = try? Data(contentsOf: file(for: host)), let base64 = pngBase64(data) else {
            return nil
        }
        icons[host] = base64
        return base64
    }

    /// Whether a host still needs a network fetch: nothing cached, no known
    /// miss, and no request already in flight. Lets a search spawn one task per
    /// new host instead of one per row per keystroke.
    public func needsFetch(for urlString: String) -> Bool {
        guard let host = Self.host(of: urlString) else { return false }
        return icons[host] == nil && !misses.contains(host) && !inFlight.contains(host)
    }

    /// Memory, disk, then Google. A miss is remembered for the session so the
    /// next search does not wait on the same dead host again.
    public func icon(for urlString: String) async -> String? {
        guard let host = Self.host(of: urlString) else { return nil }
        if let cached = icons[host] { return cached }
        if misses.contains(host) || inFlight.contains(host) { return nil }

        inFlight.insert(host)
        defer { inFlight.remove(host) }

        let file = file(for: host)
        if let data = try? Data(contentsOf: file), let base64 = pngBase64(data) {
            icons[host] = base64
            return base64
        }

        guard let requestURL = Self.faviconURL(for: host) else {
            misses.insert(host)
            return nil
        }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 2.5
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data = try? await Self.read(bytes, limit: Self.maxBytes),
              let png = try? Self.pngData(from: data) else {
            misses.insert(host)
            return nil
        }

        try? png.write(to: file, options: .atomic)
        let base64 = png.base64EncodedString()
        icons[host] = base64
        return base64
    }

    private static func host(of urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// Built with `URLComponents` so a host containing `&` or `?` stays one
    /// query value instead of injecting parameters.
    static func faviconURL(for host: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/s2/favicons"
        components.queryItems = [
            URLQueryItem(name: "domain", value: host),
            URLQueryItem(name: "sz", value: "64"),
        ]
        return components.url
    }

    private static let maxBytes = 2_000_000

    private static func read(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }

    private func file(for host: String) -> URL {
        let key = SHA256.hash(data: Data(host.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".png")
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
