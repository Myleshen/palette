import Foundation
import PaletteCore
import PalettePlatform

/// Native keep-awake provider. Idle sleep prevention is user-space and works
/// on every Mac; lid-closed operation additionally arms a root guard because
/// macOS treats a lid close as forced sleep.
public final class KeepAwakeProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "awake",
        name: "Keep Awake",
        trigger: "awake",
        isGlobal: false,
        priority: 55,
        icon: "symbol:cup.and.saucer.fill",
        keywords: ["caffeine", "sleep", "clamshell", "lid", "awake", "insomnia"]
    )

    private let service: KeepAwakeService
    private let bridge: HostBridge
    private let launcher: LauncherService

    public init(service: KeepAwakeService, bridge: HostBridge, launcher: LauncherService) {
        self.service = service
        self.bridge = bridge
        self.launcher = launcher
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let status = await service.snapshot()
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [PaletteItem] = []
        items.append(mainRow(status))
        for (seconds, label) in Self.durations {
            items.append(durationRow(seconds: seconds, label: label, status: status))
        }
        items.append(clamshellRow(status))
        if status.active || status.clamshell {
            items.append(stopRow(status))
        }
        items.append(settingsRow())

        guard !query.isEmpty else { return items }
        return items.compactMap { item in
            var item = item
            guard let score = Ranking.score(
                query: query,
                candidate: "\(item.title) \(item.subtitle ?? "") awake caffeine clamshell lid sleep"
            ) else { return nil }
            item.score = score
            return item
        }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let raw = action.value.text else { return }
        do {
            if raw.hasPrefix("start:") {
                let seconds = TimeInterval(raw.dropFirst("start:".count)) ?? 0
                try await service.start(duration: seconds > 0 ? seconds : nil)
                let status = await service.snapshot()
                await bridge.notify(
                    status.endsAt == nil
                        ? "Keeping your Mac awake until you stop it"
                        : "Keeping your Mac awake for \(status.remainingLabel)"
                )
            } else if raw == "stop" {
                await service.stop()
                await bridge.notify("Normal sleep is back")
            } else if raw == "clamshell" {
                let status = await service.snapshot()
                let enabled = !status.clamshell
                try await service.setClamshell(enabled)
                await bridge.notify(
                    enabled
                        ? "Clamshell mode on · AC power only"
                        : "Clamshell mode off; lid close sleeps normally"
                )
            } else if raw == "settings" {
                await MainActor.run {
                    launcher.openURL("x-apple.systempreferences:com.apple.settings.Battery")
                }
            }
        } catch {
            await bridge.notify(error.localizedDescription)
        }
    }

    private static let durations: [(TimeInterval, String)] = [
        (15 * 60, "15 minutes"),
        (30 * 60, "30 minutes"),
        (60 * 60, "1 hour"),
        (2 * 60 * 60, "2 hours"),
        (4 * 60 * 60, "4 hours"),
        (8 * 60 * 60, "8 hours"),
    ]

    private func mainRow(_ status: KeepAwakeStatus) -> PaletteItem {
        let title = status.active ? "Keeping Mac Awake" : "Keep Mac Awake"
        let detail: String
        if status.active {
            let left = status.endsAt == nil ? "until you stop it" : "\(status.remainingLabel) left"
            detail = "\(left) · display \(status.displaySleepPrevented ? "stays on" : "can sleep")"
        } else {
            detail = "Prevent idle sleep · choose a duration below"
        }
        return PaletteItem(
            id: "status",
            title: title,
            subtitle: detail,
            icon: .symbol(status.active ? "cup.and.saucer.fill" : "cup.and.saucer"),
            badge: status.active ? "ACTIVE" : "READY",
            group: "Keep Awake",
            score: 10_000,
            actions: [
                PaletteAction(
                    id: status.active ? "stop" : "start",
                    title: status.active ? "Stop Keeping Awake" : "Keep Awake Indefinitely",
                    kind: .custom,
                    value: .text(status.active ? "stop" : "start:0")
                ),
            ],
            preview: .text(preview(status)),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func durationRow(seconds: TimeInterval, label: String, status: KeepAwakeStatus) -> PaletteItem {
        PaletteItem(
            id: "duration:\(Int(seconds))",
            title: "Keep awake for \(label)",
            subtitle: status.active ? "Restart the timer" : "Stops automatically",
            icon: .symbol("timer"),
            group: "Durations",
            score: 9_000,
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

    private func clamshellRow(_ status: KeepAwakeStatus) -> PaletteItem {
        PaletteItem(
            id: "clamshell",
            title: "Clamshell Mode (Lid Closed)",
            subtitle: status.clamshell
                ? "On · root guard checks AC power"
                : "Off · keeps running with the lid shut · admin prompt once",
            icon: .symbol(status.clamshell ? "laptopcomputer.and.arrow.down" : "laptopcomputer"),
            badge: status.clamshell ? "ON" : "OFF",
            group: "Clamshell",
            score: 8_000,
            actions: [
                PaletteAction(
                    id: "clamshell",
                    title: status.clamshell ? "Turn Off Clamshell" : "Turn On Clamshell",
                    kind: .custom,
                    value: .text("clamshell")
                ),
            ],
            preview: .text("""
            Clamshell mode keeps the Mac awake after the lid closes.

            macOS treats a lid close as forced sleep, so Palette arms a small root guard. The guard only enables sleep-disabled mode while:
            • Palette is running
            • clamshell mode is on
            • the Mac is on AC power

            Unplugging power restores normal lid sleep. Quitting Palette also restores it. Never leave an awake, closed MacBook in a bag.
            """),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func stopRow(_ status: KeepAwakeStatus) -> PaletteItem {
        PaletteItem(
            id: "stop",
            title: "Stop Keeping Awake",
            subtitle: "Restore normal sleep and lid-close behavior",
            icon: .symbol("moon.zzz"),
            group: "Keep Awake",
            score: 7_000,
            actions: [PaletteAction(id: "stop", title: "Stop", kind: .custom, value: .text("stop"))],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func settingsRow() -> PaletteItem {
        PaletteItem(
            id: "settings",
            title: "Open Battery Settings",
            subtitle: "Review energy and power settings",
            icon: .symbol("gearshape"),
            group: "Settings",
            score: 1_000,
            actions: [PaletteAction(id: "settings", title: "Open Settings", kind: .custom, value: .text("settings"))],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func preview(_ status: KeepAwakeStatus) -> String {
        var lines: [String] = []
        if status.active {
            lines.append("Keeping your Mac awake \(status.remainingLabel).")
            lines.append("Display sleep: \(status.displaySleepPrevented ? "prevented" : "allowed").")
            lines.append("Clamshell: \(status.clamshell ? "armed (AC power only)" : "off").")
            lines.append("")
            lines.append("Press ⌘K on this row to stop, or choose another duration to restart the timer.")
        } else {
            lines.append("Keep your Mac awake while builds, downloads, or agent sessions run.")
            lines.append("")
            lines.append("Choose a duration, or enable clamshell mode to keep running with the lid closed.")
            lines.append("Clamshell mode asks for an administrator password once and restores normal sleep when you stop or quit.")
        }
        return lines.joined(separator: "\n")
    }
}
