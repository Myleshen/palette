import AppKit
import PaletteCore
import SwiftUI

/// Session cache for markdown images. Only https URLs ever reach the network.
@MainActor
final class AskImageCache {
    static let shared = AskImageCache()

    private var images: [URL: NSImage] = [:]
    private var failed: Set<URL> = []
    private var loading: [URL: Task<NSImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    func image(for url: URL) async -> NSImage? {
        guard AskMarkdown.isSafeImageURL(url) else { return nil }
        if let image = images[url] { return image }
        if failed.contains(url) { return nil }
        if let loading = loading[url] { return await loading.value }
        let task = Task { () -> NSImage? in
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            request.setValue("Palette/1.8 (macOS)", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data),
                  image.size.width > 0, image.size.height > 0 else {
                return nil
            }
            return image
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image {
            images[url] = image
        } else {
            failed.insert(url)
        }
        return image
    }
}

/// One markdown image. Loading never blocks the transcript: the alt text acts
/// as the caption until the image arrives, and the image is capped so it can
/// never blow up the window.
struct AskImageView: View {
    var alt: String
    var url: URL
    var theme: Theme

    @State private var image: NSImage?
    @State private var failed = false
    @State private var loading = true
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let image {
                let size = displaySize(for: image)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.color(theme.palette.border).opacity(0.7), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .help("Open image in browser")
                    .accessibilityLabel(alt.isEmpty ? "Image" : alt)
            } else {
                HStack(spacing: 8) {
                    if loading {
                        ProgressView().controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alt.isEmpty ? "Image" : alt)
                            .font(theme.font(size: max(9, theme.typography.size - 2)))
                            .foregroundStyle(theme.color(theme.palette.fgMuted))
                        if failed {
                            Text(url.absoluteString)
                                .font(theme.font(size: max(8, theme.typography.size - 4)))
                                .foregroundStyle(theme.color(theme.palette.fgMuted).opacity(0.8))
                                .lineLimit(2)
                        }
                    }
                    .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.color(theme.palette.elevated).opacity(0.35))
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if failed { NSWorkspace.shared.open(url) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: AskImageWidthKey.self, value: geo.size.width)
            }
        }
        .onPreferenceChange(AskImageWidthKey.self) { availableWidth = $0 }
        .task(id: url) {
            image = nil
            failed = false
            loading = true
            let loaded = await AskImageCache.shared.image(for: url)
            image = loaded
            failed = loaded == nil
            loading = false
        }
    }

    /// Cap at 260pt high and the available width, never upscaling.
    private func displaySize(for image: NSImage) -> CGSize {
        let widthLimit = availableWidth > 0 ? availableWidth : 600
        let scale = min(1, 260 / max(1, image.size.height), widthLimit / max(1, image.size.width))
        return CGSize(
            width: max(1, image.size.width * scale),
            height: max(1, image.size.height * scale)
        )
    }
}

private struct AskImageWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
