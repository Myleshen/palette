import AppKit
import Foundation
import PaletteCore
import Vision

public enum ImageTextError: LocalizedError {
    case unreadableImage
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "The image could not be read"
        case .recognitionFailed(let message):
            return message.isEmpty ? "Text recognition failed" : message
        }
    }
}

/// One recognized line with Vision's normalized geometry (origin bottom-left).
/// Kept as a plain value so ordering and joining can be tested without Vision.
public struct ImageTextObservation: Equatable, Sendable {
    public var text: String
    public var boundingBox: CGRect

    public init(text: String, boundingBox: CGRect) {
        self.text = text
        self.boundingBox = boundingBox
    }
}

/// Text and links found in one image, already ordered top-to-bottom.
public struct RecognizedImageText: Equatable, Sendable {
    public var lines: [String]
    public var links: [String]

    public init(lines: [String] = [], links: [String] = []) {
        self.lines = lines
        self.links = links
    }

    /// Newline-joined lines; empty when the image carries no readable text.
    public var text: String { lines.joined(separator: "\n") }

    public var isEmpty: Bool { text.isEmpty && links.isEmpty }

    public var firstLink: String? { links.first }
}

/// On-device text and barcode recognition through Vision. Nothing leaves the
/// machine: the framework runs locally and no network access is involved.
public enum ImageTextRecognition {
    public static let barcodeSymbologies: [VNBarcodeSymbology] = [.qr, .ean13, .ean8, .code128]

    // MARK: - Vision

    public static func recognize(_ image: NSImage) async throws -> RecognizedImageText {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageTextError.unreadableImage
        }
        return try await recognize(cgImage)
    }

    public static func recognize(pngData: Data) async throws -> RecognizedImageText {
        try Task.checkCancellation()
        guard let image = NSImage(data: pngData) else { throw ImageTextError.unreadableImage }
        return try await recognize(image)
    }

    public static func recognize(_ cgImage: CGImage) async throws -> RecognizedImageText {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            let barcodeRequest = VNDetectBarcodesRequest()
            barcodeRequest.symbologies = Self.barcodeSymbologies

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([textRequest, barcodeRequest])
            } catch {
                throw ImageTextError.recognitionFailed(error.localizedDescription)
            }
            // shortcut: Vision's perform is synchronous, so cancellation is
            // honoured between requests, not mid-frame; revisit if a very large
            // image ever makes an in-flight request noticeable.
            try Task.checkCancellation()

            let observations = (textRequest.results ?? []).compactMap { observation -> ImageTextObservation? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return ImageTextObservation(text: candidate.string, boundingBox: observation.boundingBox)
            }
            let barcodes = (barcodeRequest.results ?? []).compactMap(\.payloadStringValue)
            return Self.compose(observations: observations, barcodes: barcodes)
        }.value
    }

    // MARK: - Post-processing

    /// Lines and links, ordered top-to-bottom, from synthetic or Vision
    /// observations. Pure so the ordering rules are testable without a camera.
    public static func compose(
        observations: [ImageTextObservation],
        barcodes: [String] = []
    ) -> RecognizedImageText {
        var lines = orderedLines(observations)
        var found: [String] = []
        for payload in barcodes {
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if isOpenable(trimmed) {
                if !found.contains(trimmed) { found.append(trimmed) }
            } else if !lines.contains(trimmed) {
                // A product code or plain QR payload is still useful text.
                lines.append(trimmed)
            }
        }
        let text = lines.joined(separator: "\n")
        for link in links(in: text) where !found.contains(link) {
            found.append(link)
        }
        return RecognizedImageText(lines: lines, links: found)
    }

    /// Vision's origin is bottom-left, so a higher `midY` is higher on screen.
    /// Fragments that share a visual line are joined left-to-right.
    public static func orderedLines(_ observations: [ImageTextObservation]) -> [String] {
        var rows: [[ImageTextObservation]] = []
        for observation in observations.sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            if let index = rows.firstIndex(where: { sameLine($0[0].boundingBox, observation.boundingBox) }) {
                rows[index].append(observation)
            } else {
                rows.append([observation])
            }
        }
        return rows.compactMap { row in
            let text = row
                .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return text.isEmpty ? nil : text
        }
    }

    private static func sameLine(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        let shortest = min(lhs.height, rhs.height)
        if shortest > 0, overlap > shortest * 0.5 { return true }
        if overlap <= 0 { return false }
        return abs(lhs.midY - rhs.midY) < 0.01
    }

    /// http(s) links found in text, deduped in reading order.
    public static func links(in text: String) -> [String] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        var found: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let url = match.url else { return }
            let value = url.absoluteString
            guard isOpenable(value), !found.contains(value) else { return }
            found.append(value)
        }
        return found
    }

    /// Only absolute http(s) URLs are actionable; a file or script scheme from
    /// recognized text must never be opened.
    public static func isOpenable(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else { return false }
        return true
    }

    // MARK: - Cache

    private static let cacheLock = NSLock()
    private static var cache: [String: RecognizedImageText] = [:]

    public static func cached(cacheKey: String) -> RecognizedImageText? {
        cacheLock.withLock { cache[cacheKey] }
    }

    /// Recognition is expensive enough that a clipboard thumbnail should be
    /// read once, not on every keystroke.
    public static func recognize(pngData: Data, cacheKey: String) async throws -> RecognizedImageText {
        if let cached = cached(cacheKey: cacheKey) { return cached }
        let value = try await recognize(pngData: pngData)
        cacheLock.withLock {
            if cache.count >= 64 { cache.removeAll() }
            cache[cacheKey] = value
        }
        return value
    }

    public static func recognize(_ image: NSImage, cacheKey: String) async throws -> RecognizedImageText {
        if let cached = cached(cacheKey: cacheKey) { return cached }
        let value = try await recognize(image)
        cacheLock.withLock {
            if cache.count >= 64 { cache.removeAll() }
            cache[cacheKey] = value
        }
        return value
    }

    // MARK: - Feedback

    /// Copies recognized text and reports the count, or says nothing was found.
    @discardableResult
    public static func copyText(_ recognition: RecognizedImageText, using bridge: HostBridge) async -> Bool {
        let text = recognition.text
        guard !text.isEmpty else {
            await bridge.notify("No text found")
            return false
        }
        await bridge.copyToClipboard(text, concealed: false, clearAfterMs: nil)
        await bridge.notify("Text copied (\(text.count) chars)")
        return true
    }

    /// Opens the first validated link, or reports that the image had none.
    @discardableResult
    public static func openFirstLink(_ recognition: RecognizedImageText, using bridge: HostBridge) async -> Bool {
        guard let raw = recognition.firstLink,
              let url = URL(string: raw),
              isOpenable(raw) else {
            await bridge.notify("No link found")
            return false
        }
        await bridge.notify("Opening \(url.host ?? raw)")
        NSWorkspace.shared.open(url)
        return true
    }
}
