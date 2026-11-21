import Foundation
import PaletteCore
import PalettePlatform

/// Countdown timer. One timer runs at a time; it keeps counting with the panel
/// closed and notifies when it finishes.
public final class TimerProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "timer",
        name: "Timers",
        trigger: "timer",
        isGlobal: false,
        priority: 50,
        icon: "symbol:timer",
        keywords: ["timer", "countdown", "pomodoro", "alarm", "focus", "minutes"]
    )

    private let service: TimerService
    private let presets: [Double]

    public init(service: TimerService, presetMinutes: [Int]) {
        self.service = service
        self.presets = presetMinutes.map { Double($0) * 60 }
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let snapshot = await service.snapshot()
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)

        var items: [PaletteItem] = [statusRow(snapshot)]

        if let seconds = TimerDuration.parse(query) {
            items.append(startRow(seconds: seconds, label: TimerDuration.label(seconds), score: 10_000))
        }

        for seconds in presets.sorted() {
            let label = TimerDuration.label(seconds)
            items.append(startRow(seconds: seconds, label: label, score: 8_000))
        }

        if snapshot.isRunning {
            items.append(stopRow(snapshot))
        }

        guard !query.isEmpty else { return items }
        // Keep the exact match if the query parsed as a duration, and drop
        // presets that do not match the text.
        if TimerDuration.parse(query) != nil {
            return items.filter {
                $0.group != "Presets" || Ranking.score(query: query, candidate: $0.title) != nil
            }
        }
        return items.compactMap { item in
            guard let score = Ranking.score(
                query: query,
                candidate: "\(item.title) \(item.subtitle ?? "") \(item.group ?? "") timer countdown pomodoro"
            ) else { return nil }
            var item = item
            item.score = score
            return item
        }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let raw = action.value.text else { return }
        if raw.hasPrefix("start:") {
            let seconds = TimeInterval(raw.dropFirst("start:".count)) ?? 0
            await service.start(seconds: seconds, label: TimerDuration.label(seconds))
        } else if raw == "stop" {
            await service.stop()
        }
    }

    private func statusRow(_ snapshot: TimerSnapshot) -> PaletteItem {
        let running = snapshot.isRunning
        let defaultSeconds = presets.first ?? 1_500
        return PaletteItem(
            id: "status",
            title: running ? "\(TimerDuration.format(snapshot.remaining)) remaining" : "No timer running",
            subtitle: running
                ? "\(snapshot.label) · stops at \(Self.finishTime(snapshot.endsAt))"
                : "Type a duration like 25m, 1h30m or 1:30, then press Enter",
            icon: .symbol(running ? "timer" : "timer.circle"),
            badge: running ? "RUNNING" : "IDLE",
            group: "Timer",
            score: 9_500,
            actions: running
                ? [PaletteAction(id: "stop", title: "Stop Timer", kind: .custom, value: .text("stop"))]
                : [PaletteAction(
                    id: "start-default",
                    title: "Start \(TimerDuration.label(defaultSeconds)) Timer",
                    kind: .custom,
                    value: .text("start:\(Int(defaultSeconds))")
                )],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func startRow(seconds: TimeInterval, label: String, score: Double) -> PaletteItem {
        PaletteItem(
            id: "start:\(Int(seconds))",
            title: "Start a \(label) timer",
            subtitle: "Notifies you when it finishes",
            icon: .symbol("play.circle"),
            group: score > 9_000 ? "Timer" : "Presets",
            score: score,
            actions: [
                PaletteAction(
                    id: "start-\(Int(seconds))",
                    title: "Start \(label)",
                    kind: .custom,
                    value: .text("start:\(Int(seconds))")
                ),
            ],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func stopRow(_ snapshot: TimerSnapshot) -> PaletteItem {
        PaletteItem(
            id: "stop",
            title: "Stop the timer",
            subtitle: "\(TimerDuration.format(snapshot.remaining)) left",
            icon: .symbol("stop.circle"),
            group: "Timer",
            score: 9_000,
            actions: [PaletteAction(id: "stop", title: "Stop", kind: .custom, value: .text("stop"))],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private static func finishTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
