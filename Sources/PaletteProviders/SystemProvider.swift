import AppKit
import Foundation
import PaletteCore
import PalettePlatform

public final class SystemProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "system",
        name: "System",
        trigger: "sys",
        isGlobal: false,
        priority: 10,
        icon: "symbol:gearshape"
    )

    private enum Command: String, Sendable {
        case sleep
        case sleepDisplay
        case lock
        case emptyTrash
        case restart
        case shutdown
        case reload
        case openConfig
        case openProviders
        case quit
    }

    private struct Entry {
        var command: Command
        var title: String
        var subtitle: String
        var icon: String
        var keywords: String
        var destructive: Bool
        var group: String
    }

    private let launcher: LauncherService
    private let bridge: HostBridge

    public var onReload: (() -> Void)?
    public var onOpenConfig: (() -> Void)?
    public var onOpenProviders: (() -> Void)?
    public var onQuit: (() -> Void)?

    public init(launcher: LauncherService, bridge: HostBridge) {
        self.launcher = launcher
        self.bridge = bridge
    }

    private var entries: [Entry] {
        [
            Entry(command: .lock, title: "Lock Screen", subtitle: "Lock macOS", icon: "lock", keywords: "lock screen security", destructive: false, group: "Power"),
            Entry(command: .sleepDisplay, title: "Sleep Display", subtitle: "Turn the display off", icon: "display", keywords: "monitor display sleep", destructive: false, group: "Power"),
            Entry(command: .sleep, title: "Sleep", subtitle: "Put the Mac to sleep", icon: "moon.zzz", keywords: "sleep suspend", destructive: false, group: "Power"),
            Entry(command: .restart, title: "Restart…", subtitle: "Restart the Mac", icon: "arrow.clockwise", keywords: "reboot restart", destructive: true, group: "Power"),
            Entry(command: .shutdown, title: "Shut Down…", subtitle: "Shut down the Mac", icon: "power", keywords: "power off shutdown", destructive: true, group: "Power"),
            Entry(command: .emptyTrash, title: "Empty Trash", subtitle: "Permanently delete items in the Trash", icon: "trash", keywords: "trash delete empty", destructive: true, group: "Maintenance"),
            Entry(command: .reload, title: "Reload Configuration", subtitle: "Re-read config.toml, themes, and providers", icon: "arrow.triangle.2.circlepath", keywords: "reload refresh config", destructive: false, group: "Palette"),
            Entry(command: .openConfig, title: "Open config.toml", subtitle: "Edit Palette configuration", icon: "doc.text", keywords: "config settings preferences edit", destructive: false, group: "Palette"),
            Entry(command: .openProviders, title: "Open Providers Folder", subtitle: "Add or edit provider manifests", icon: "puzzlepiece.extension", keywords: "providers extensions plugins folder", destructive: false, group: "Palette"),
            Entry(command: .quit, title: "Quit Palette", subtitle: "Stop the launcher", icon: "xmark.circle", keywords: "quit exit stop", destructive: false, group: "Palette"),
        ]
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.compactMap { entry in
            let candidate = entry.title + " " + entry.subtitle + " " + entry.keywords
            let score: Double
            if query.isEmpty {
                score = 0
            } else if let value = Ranking.score(query: query, candidate: candidate) {
                score = value
            } else {
                return nil
            }
            return PaletteItem(
                id: entry.command.rawValue,
                title: entry.title,
                subtitle: entry.subtitle,
                icon: .symbol(entry.icon),
                group: entry.group,
                score: score,
                actions: [
                    PaletteAction(
                        id: entry.command.rawValue,
                        title: entry.title,
                        kind: .custom,
                        value: .text(entry.command.rawValue)
                    ),
                ],
                providerID: descriptor.id,
                providerName: descriptor.name
            )
        }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let raw = action.value.text, let command = Command(rawValue: raw) else { return }
        switch command {
        case .lock:
            _ = try await ProcessRunner.run(["/usr/bin/osascript", "-e",
                "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"])
        case .sleepDisplay:
            _ = try await ProcessRunner.run(["/usr/bin/pmset", "displaysleepnow"])
        case .sleep:
            _ = try await ProcessRunner.run(["/usr/bin/pmset", "sleepnow"])
        case .restart:
            guard await confirm(title: "Restart the Mac?", message: "Open apps will be asked to quit.") else { return }
            _ = try await ProcessRunner.run(["/usr/bin/osascript", "-e", "tell application \"System Events\" to restart"])
        case .shutdown:
            guard await confirm(title: "Shut down the Mac?", message: "Open apps will be asked to quit.") else { return }
            _ = try await ProcessRunner.run(["/usr/bin/osascript", "-e", "tell application \"System Events\" to shut down"])
        case .emptyTrash:
            guard await confirm(title: "Empty the Trash?", message: "This cannot be undone.") else { return }
            _ = try await ProcessRunner.run(["/usr/bin/osascript", "-e", "tell application \"Finder\" to empty trash"])
        case .reload:
            await MainActor.run { onReload?() }
            await bridge.notify("Reloaded configuration and providers")
        case .openConfig:
            await MainActor.run { onOpenConfig?() }
        case .openProviders:
            await MainActor.run { onOpenProviders?() }
        case .quit:
            await MainActor.run { onQuit?() }
        }
    }

    private func confirm(title: String, message: String) async -> Bool {
        let answer = await bridge.prompt(kind: .confirm, title: "\(title) \(message)", placeholder: nil)
        return answer == "true"
    }
}
