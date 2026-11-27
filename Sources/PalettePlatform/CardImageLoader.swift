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

/// Thumbnails for wallpaper cards. Decoding happens off the main thread, one
/// per card and never twice: a flip only reads the cache. Video files get a
/// still frame when AVFoundation can produce one cheaply, otherwise nil and
/// the card draws a film glyph.
public actor CardImageLoader {
    public static let shared = CardImageLoader()

    private var cache: [String: CardThumbnail] = [:]
    private var loads: [String: Int] = [:]

    public init() {}

    public func thumbnail(for url: URL, maxPixel: CGFloat = 720) async -> CardThumbnail? {
        let key = Self.key(url, maxPixel: maxPixel)
        if let hit = cache[key] { return hit }
        loads[key, default: 0] += 1
        let image: NSImage?
        if WallpaperLibrary.videoExtensions.contains(url.pathExtension.lowercased()) {
            image = await Self.videoFrame(url: url, maxPixel: maxPixel)
        } else {
            image = Self.imageThumbnail(url: url, maxPixel: maxPixel)
        }
        guard let image else { return nil }
        let thumbnail = CardThumbnail(image)
        cache[key] = thumbnail
        return thumbnail
    }

    /// Test hook: how often this exact picture was decoded.
    public func loadCount(for url: URL, maxPixel: CGFloat = 720) -> Int {
        loads[Self.key(url, maxPixel: maxPixel)] ?? 0
    }

    public func resetForTesting() {
        cache.removeAll()
        loads.removeAll()
    }

    private static func key(_ url: URL, maxPixel: CGFloat) -> String {
        "\(url.standardizedFileURL.path)#\(Int(maxPixel))"
    }

    private static func imageThumbnail(url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static func videoFrame(url: URL, maxPixel: CGFloat) async -> NSImage? {
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
