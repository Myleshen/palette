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
            row(id: "annotate-region", title: "Capture a region and annotate", subtitle: "Arrow, rectangle, text, crop", value: "annotate:region", score: 8_700),
            row(id: "annotate-screen", title: "Capture the screen and annotate", subtitle: "Arrow, rectangle, text, crop", value: "annotate:screen", score: 8_600),
        ]
        guard !query.isEmpty else { return items }
        return items.filter { Ranking.score(query: query, candidate: "\($0.title) \($0.subtitle ?? "")") != nil }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let raw = action.value.text else { return }
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
            var rows = [
                startRow(
                    id: "screen",
                    title: "Record the whole screen",
                    subtitle: "Run /rec again to stop",
                    value: "start",
                    score: 10_000
                )
            ]
            for display in CaptureDisplays.active() {
                rows.append(startRow(
                    id: "display-\(display.index)",
                    title: "Record \(display.name)",
                    subtitle: "\(display.width)×\(display.height) · display \(display.index)",
                    value: "start:display:\(display.index)",
                    score: 9_900
                ))
            }
            let region = await service.config.recordingRegion.trimmingCharacters(in: .whitespaces)
            if !region.isEmpty {
                rows.append(startRow(
                    id: "region",
                    title: "Record the region \(region)",
                    subtitle: "Set in Settings → Capture",
                    value: "start:region",
                    score: 9_800
                ))
            }
            let filtered = query.isEmpty
                ? rows
                : rows.filter { Ranking.score(query: query, candidate: "\($0.title) \($0.subtitle ?? "")") != nil }
            return filtered
        }
        guard !query.isEmpty else { return [item] }
        return Ranking.score(query: query, candidate: "\(item.title) \(item.subtitle ?? "")") != nil ? [item] : []
    }

    private func startRow(id: String, title: String, subtitle: String, value: String, score: Double) -> PaletteItem {
        PaletteItem(
            id: "rec:\(id)",
            title: title,
            subtitle: subtitle,
            icon: .symbol("record.circle"),
            group: "Recording",
            score: score,
            actions: [PaletteAction(id: id, title: title, kind: .custom, value: .text(value))],
            preview: .text("Records with the system capture engine.\n\nChoose a display, the whole screen, or the region from Settings → Capture. Stop with /rec or the menu bar."),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        switch action.value.text {
        case let value? where value.hasPrefix("start"):
            let parts = value.split(separator: ":").map(String.init)
            await MainActor.run {
                if parts.count == 3, parts[1] == "display", let index = Int(parts[2]) {
                    service.config.recordingTarget = "display"
                    service.config.recordingDisplay = index
                } else if parts.count == 2, parts[1] == "region" {
                    service.config.recordingTarget = "region"
                } else {
                    service.config.recordingTarget = "screen"
                }
            }
            if await service.config.hidePalette { await beforeStart() }
            try await service.startRecording()
        case "stop":
            _ = try await service.stopRecording()
        default:
            break
        }
    }
}
