import AppKit
import AVFoundation
import ImageIO
import PaletteCore

/// A decoded card picture, wrapped so it can cross the loader actor boundary.
/// NSImage is immutable here: the gallery only reads it.
public struct CardThumbnail: @unchecked Sendable {
    public let image: NSImage

    public init(_ image: NSImage) {
        self.image = image
    }
}

/// Thumbnails for wallpaper cards. Decoding is ImageIO-downsampled to the size
/// the card draws (512 px is 2× its width, enough for Retina), so a 4K/8K file
/// never becomes a full-size bitmap. A 512 px picture is kept in an NSCache and
/// encoded to a disk cache keyed by path+mtime, so a warm open reads ~40 KB
/// instead of the original file. A small bounded queue decodes, never the main
/// thread. Video files get a still frame when AVFoundation can produce one
/// cheaply, otherwise nil and the card shows its palette colour.
public actor CardImageLoader {
    public static let shared = CardImageLoader()

    private final class Entry {
        let thumbnail: CardThumbnail

        init(_ thumbnail: CardThumbnail) {
            self.thumbnail = thumbnail
        }
    }

    /// Test-visible high-water mark, so "several at once, never more than the
    /// bound" is an assertion rather than a timing guess.
    private final class DecodeMonitor: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = 0
        private var peak = 0

        func begin() {
            lock.lock()
            inFlight += 1
            peak = max(peak, inFlight)
            lock.unlock()
        }

        func end() {
            lock.lock()
            inFlight -= 1
            lock.unlock()
        }

        var peakInFlight: Int {
            lock.lock()
            defer { lock.unlock() }
            return peak
        }

        func reset() {
            lock.lock()
            peak = 0
            lock.unlock()
        }
    }

    private let cacheDirectory: URL
    private let memory = NSCache<NSString, Entry>()
    /// A visible window is ~15 4K–8K pictures. Decoding them one at a time made
    /// the last card wait on every earlier one; six at a time fills the window
    /// without turning the branch into 15 simultaneous full decodes.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.myleshen.palette.card-thumbnails"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 6
        return queue
    }()
    private let monitor = DecodeMonitor()

    private var loads: [String: Int] = [:]

    /// `cacheDirectory` is injectable so tests never touch the real cache.
    public init(
        cacheDirectory: URL = PalettePaths.resolve().cacheDir
            .appendingPathComponent("ThemeThumbnails", isDirectory: true)
    ) {
        self.cacheDirectory = cacheDirectory
        memory.countLimit = 120
        memory.totalCostLimit = 64 * 1024 * 1024
        let directory = cacheDirectory
        queue.addOperation {
            Self.prune(directory, maxFiles: 400)
        }
    }

    public func thumbnail(for url: URL, maxPixel: CGFloat = 512) async -> CardThumbnail? {
        let pixel = max(32, Int(maxPixel.rounded()))
        let key = Self.cacheKey(url, maxPixel: pixel)
        if let hit = memory.object(forKey: key as NSString) { return hit.thumbnail }
        loads[key, default: 0] += 1
        let image: NSImage?
        if WallpaperLibrary.videoExtensions.contains(url.pathExtension.lowercased()) {
            image = await Self.videoFrame(url: url, maxPixel: pixel)
        } else {
            let directory = cacheDirectory
            let monitor = monitor
            image = await withCheckedContinuation { continuation in
                queue.addOperation {
                    monitor.begin()
                    let decoded = Self.imageThumbnail(
                        url: url,
                        maxPixel: pixel,
                        cacheDirectory: directory
                    )
                    monitor.end()
                    continuation.resume(returning: decoded)
                }
            }
        }
        guard let image else { return nil }
        let thumbnail = CardThumbnail(image)
        let cost = Int(image.size.width * image.size.height * 4)
        memory.setObject(Entry(thumbnail), forKey: key as NSString, cost: cost)
        return thumbnail
    }

    /// Test hook: how often this exact picture was decoded.
    public func loadCount(for url: URL, maxPixel: CGFloat = 512) -> Int {
        loads[Self.cacheKey(url, maxPixel: max(32, Int(maxPixel.rounded())))] ?? 0
    }

    /// Test hook: most decodes that ever ran at the same time.
    public func peakConcurrentDecodes() -> Int {
        monitor.peakInFlight
    }

    public func resetForTesting() {
        memory.removeAllObjects()
        loads.removeAll()
        monitor.reset()
    }

    /// The key both caches use: a changed file or mtime is a different picture.
    static func cacheKey(_ url: URL, maxPixel: Int) -> String {
        let path = url.standardizedFileURL.path
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSince1970) ?? 0
        return "\(path)|\(Int(modified))|\(maxPixel)"
    }

    private static func imageThumbnail(url: URL, maxPixel: Int, cacheDirectory: URL) -> NSImage? {
        let key = cacheKey(url, maxPixel: maxPixel)
        let file = cacheDirectory.appendingPathComponent("\(stableHash(key)).jpg")
        if let data = try? Data(contentsOf: file),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(
               source,
               0,
               [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
           ) {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        if let encoded = jpegData(image) {
            try? FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try? encoded.write(to: file, options: .atomic)
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// FNV-1a, stable across launches: Swift's Hasher is seeded per process and
    /// would never find yesterday's cache file.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Watch every edit leaves an entry behind; keep the folder bounded.
    private static func prune(_ directory: URL, maxFiles: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ), files.count > maxFiles else { return }
        let oldest = files.sorted {
            let left = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return left < right
        }
        for file in oldest.prefix(files.count - maxFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func videoFrame(url: URL, maxPixel: Int) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
