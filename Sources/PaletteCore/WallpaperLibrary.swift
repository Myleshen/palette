import Foundation

/// One picture or clip in the wallpaper folder. The gallery asks for a
/// thumbnail only when the card is near the selection.
public struct WallpaperFile: Equatable, Sendable, Identifiable, Hashable {
    public var url: URL
    public var isVideo: Bool

    public init(url: URL, isVideo: Bool) {
        self.url = url
        self.isVideo = isVideo
    }

    public var id: String { url.standardizedFileURL.path }
    public var name: String { url.lastPathComponent }
}

/// Lists the wallpaper folder. Images become picture cards; video files become
/// cards too, with a still frame when one is cheap to grab and a film glyph
/// otherwise. macOS cannot put a video on the desktop, so those cards are for
/// browsing (the apply path reports that instead of pretending it worked).
public enum WallpaperLibrary {
    /// The folder Palette's own pictures live in on this machine. An empty
    /// setting still means empty; nothing falls back here silently.
    public static let defaultDirectory = "~/wallpapers"

    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp",
    ]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]

    /// nil for an empty setting, so callers never scan the working directory.
    public static func directory(path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }

    public static func files(
        in directory: URL?,
        fileManager: FileManager = .default
    ) -> [WallpaperFile] {
        guard let directory,
              let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        return entries
            .compactMap { url -> WallpaperFile? in
                let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                guard isRegular else { return nil }
                switch url.pathExtension.lowercased() {
                case let ext where imageExtensions.contains(ext):
                    return WallpaperFile(url: url, isVideo: false)
                case let ext where videoExtensions.contains(ext):
                    return WallpaperFile(url: url, isVideo: true)
                default:
                    return nil
                }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
