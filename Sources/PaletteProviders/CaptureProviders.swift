import AppKit
import Foundation
import PaletteCore
import PalettePlatform

/// Screenshots through the system capture engine: full screen, region, window.
public final class ShotProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "shot",
        name: "Screenshot",
        trigger: "shot",
        isGlobal: false,
        priority: 47,
        icon: "symbol:camera.viewfinder",
        keywords: ["screenshot", "shot", "capture", "screen", "region", "window", "snip"]
    )

    private let service: CaptureService
    private let bridge: HostBridge
    private let lastScreenshot: @MainActor () -> URL?
    private let beforeCapture: @MainActor () -> Void

    public init(
        service: CaptureService,
        bridge: HostBridge,
        lastScreenshot: @escaping @MainActor () -> URL?,
        beforeCapture: @escaping @MainActor () -> Void
    ) {
        self.service = service
        self.bridge = bridge
        self.lastScreenshot = lastScreenshot
        self.beforeCapture = beforeCapture
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let delay = await service.config.delay
        var items = [
            row(id: "screen", title: "Capture the screen", subtitle: delay > 0 ? "After \(Int(delay)) seconds" : "All displays", value: "screen", score: 9_000),
            row(id: "region", title: "Capture a region", subtitle: "Drag to select", value: "region", score: 8_900),
            row(id: "window", title: "Capture a window", subtitle: "Click a window", value: "window", score: 8_800),
            row(id: "annotate-region", title: "Capture a region and annotate", subtitle: "Arrow, rectangle, text, crop", value: "annotate:region", score: 8_700),
            row(id: "annotate-screen", title: "Capture the screen and annotate", subtitle: "Arrow, rectangle, text, crop", value: "annotate:screen", score: 8_600),
        ]
        if let last = await MainActor.run(body: { lastScreenshot() }),
           FileManager.default.fileExists(atPath: last.path) {
            items.append(row(
                id: "ocr-copy",
                title: "Copy Text from Last Screenshot",
                subtitle: last.lastPathComponent,
                value: "ocr-copy",
                score: 8_500
            ))
            items.append(row(
                id: "ocr-open",
                title: "Open Detected Link",
                subtitle: "From \(last.lastPathComponent)",
                value: "ocr-open",
                score: 8_400
            ))
        }
        guard !query.isEmpty else { return items }
        return items.filter { Ranking.score(query: query, candidate: "\($0.title) \($0.subtitle ?? "")") != nil }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let raw = action.value.text else { return }
        if raw == "ocr-copy" || raw == "ocr-open" {
            await readLastScreenshot(openLink: raw == "ocr-open")
            return
        }
        let annotate = raw.hasPrefix("annotate:")
        let name = annotate ? String(raw.dropFirst("annotate:".count)) : raw
        guard let mode = CaptureMode(rawValue: name) else { return }
        await MainActor.run { service.annotateNextCapture = annotate }
        let hide = await service.config.hidePalette
        if hide { await beforeCapture() }
        // Give the panel a beat to leave the screen before capturing.
        try? await Task.sleep(nanoseconds: 180_000_000)
        _ = try await service.screenshot(mode)
    }

    private func readLastScreenshot(openLink: Bool) async {
        guard let url = await MainActor.run(body: { lastScreenshot() }),
              let image = NSImage(contentsOf: url) else {
            await bridge.notify("No last screenshot")
            return
        }
        do {
            let recognition = try await ImageTextRecognition.recognize(image)
            if openLink {
                await ImageTextRecognition.openFirstLink(recognition, using: bridge)
            } else {
                await ImageTextRecognition.copyText(recognition, using: bridge)
            }
        } catch {
            await bridge.notify("Text recognition failed")
        }
    }

    private func row(id: String, title: String, subtitle: String, value: String, score: Double) -> PaletteItem {
        PaletteItem(
            id: "shot:\(id)",
            title: title,
            subtitle: subtitle,
            icon: .symbol("camera.viewfinder"),
            group: "Screenshot",
            score: score,
            actions: [PaletteAction(id: id, title: title, kind: .custom, value: .text(value))],
            preview: .text("Saves to the configured capture directory and copies to the clipboard, depending on [capture] settings.\n\nAnnotate opens the editor with arrow, rectangle, text and crop tools. Region and window use the system selection UI; press Escape to cancel."),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }
}

/// Screen recording: the hotkey and `/rec` both ask for the options first, then
/// start and stop through the same capture engine.
public final class RecProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "rec",
        name: "Recording",
        trigger: "rec",
        isGlobal: false,
        priority: 47,
        icon: "symbol:record.circle",
        keywords: ["record", "recording", "screen", "video", "capture"]
    )

    private let service: CaptureService
    private let startRequest: @MainActor () -> Void

    public init(service: CaptureService, startRequest: @escaping @MainActor () -> Void) {
        self.service = service
        self.startRequest = startRequest
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let recording = await service.isRecording
        let elapsed = await service.recordingElapsed

        let item: PaletteItem
        if recording {
            item = PaletteItem(
                id: "rec:stop",
                title: "Stop recording",
                subtitle: "Recording for \(TimerDuration.format(elapsed))",
                icon: .symbol("stop.circle.fill"),
                badge: "REC",
                group: "Recording",
                score: 10_000,
                actions: [PaletteAction(id: "stop", title: "Stop recording", kind: .custom, value: .text("stop"))],
                preview: .text("Stops the recording, converts it when mp4 is configured, and saves it to the capture directory."),
                providerID: descriptor.id,
                providerName: descriptor.name
            )
        } else {
            item = PaletteItem(
                id: "rec:start",
                title: "Start recording…",
                subtitle: "Audio, display and area",
                icon: .symbol("record.circle"),
                group: "Recording",
                score: 10_000,
                actions: [PaletteAction(id: "start", title: "Start recording…", kind: .custom, value: .text("start"))],
                preview: .text("Asks for audio, microphone, display and area, then records with the system capture engine.\n\nStop with the same shortcut, /rec, or the menu bar."),
                providerID: descriptor.id,
                providerName: descriptor.name
            )
        }
        guard !query.isEmpty else { return [item] }
        return Ranking.score(query: query, candidate: "\(item.title) \(item.subtitle ?? "")") != nil ? [item] : []
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        switch action.value.text {
        case "start":
            // The options panel owns the launcher's start path too, so a
            // recording asks the same questions however it is triggered.
            await MainActor.run { startRequest() }
        case "stop":
            _ = try await service.stopRecording()
        default:
            break
        }
    }
}
