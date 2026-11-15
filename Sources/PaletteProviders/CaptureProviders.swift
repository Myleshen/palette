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
    private let beforeCapture: @MainActor () -> Void

    public init(service: CaptureService, beforeCapture: @escaping @MainActor () -> Void) {
        self.service = service
        self.beforeCapture = beforeCapture
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let delay = await service.config.delay
        let items = [
            row(id: "screen", title: "Capture the screen", subtitle: delay > 0 ? "After \(Int(delay)) seconds" : "All displays", value: "screen", score: 9_000),
            row(id: "region", title: "Capture a region", subtitle: "Drag to select", value: "region", score: 8_900),
            row(id: "window", title: "Capture a window", subtitle: "Click a window", value: "window", score: 8_800),
        ]
        guard !query.isEmpty else { return items }
        return items.filter { "\($0.title) \($0.subtitle ?? "")".lowercased().contains(query.lowercased()) }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let raw = action.value.text, let mode = CaptureMode(rawValue: raw) else { return }
        let hide = await service.config.hidePalette
        if hide { await beforeCapture() }
        // Give the panel a beat to leave the screen before capturing.
        try? await Task.sleep(nanoseconds: 180_000_000)
        _ = try await service.screenshot(mode)
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
            preview: .text("Saves to the configured capture directory and copies to the clipboard, depending on [capture] settings.\n\nRegion and window use the system selection UI; press Escape to cancel."),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }
}

/// Screen recording: start and stop through the same capture engine.
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
    private let beforeStart: @MainActor () -> Void

    public init(service: CaptureService, beforeStart: @escaping @MainActor () -> Void) {
        self.service = service
        self.beforeStart = beforeStart
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
                title: "Start recording the screen",
                subtitle: "Run /rec again to stop",
                icon: .symbol("record.circle"),
                group: "Recording",
                score: 10_000,
                actions: [PaletteAction(id: "start", title: "Start recording", kind: .custom, value: .text("start"))],
                preview: .text("Records the screen with the system capture engine.\n\nStop with /rec or the menu bar. The file lands in the capture directory."),
                providerID: descriptor.id,
                providerName: descriptor.name
            )
        }
        guard !query.isEmpty else { return [item] }
        return "\(item.title) \(item.subtitle ?? "")".lowercased().contains(query.lowercased()) ? [item] : []
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        switch action.value.text {
        case "start":
            if await service.config.hidePalette { await beforeStart() }
            try await service.startRecording()
        case "stop":
            _ = try await service.stopRecording()
        default:
            break
        }
    }
}
