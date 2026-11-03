import Foundation
import PaletteCore
import PalettePlatform

/// Actions on the current Finder selection. Reading the selection uses
/// AppleScript, so macOS may ask for Automation permission once.
public final class FinderProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "finder",
        name: "Finder Selection",
        trigger: "finder",
        isGlobal: false,
        priority: 54,
        icon: "symbol:macwindow.on.rectangle"
    )

    private actor Cache {
        var paths: [String] = []
        var error: String?
        var at = Date.distantPast
        var attempted = false

        func update(_ paths: [String], error: String?, at date: Date) {
            self.paths = paths
            self.error = error
            self.at = date
            self.attempted = true
        }
    }

    private let launcher: LauncherService
    private let bridge: HostBridge
    private let terminal: String
    private let cache = Cache()

    public init(launcher: LauncherService, bridge: HostBridge, terminal: String = "kitty") {
        self.launcher = launcher
        self.bridge = bridge
        self.terminal = terminal
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let attempted = await cache.attempted
        if !attempted {
            return [PaletteItem(
                id: "finder:load",
                title: "Read Current Finder Selection",
                subtitle: "Palette asks macOS for Automation access the first time",
                icon: .symbol("cursorarrow"),
                badge: "FINDER",
                score: 10_000,
                actions: [PaletteAction(id: "load", title: "Read Selection", kind: .custom, value: .text("load"))],
                preview: .text("Select files in Finder, press Enter here, then run /finder again. macOS will ask once for permission to control Finder."),
                providerID: descriptor.id,
                providerName: descriptor.name
            )]
        }
        let paths = await selection()
        if paths.isEmpty {
            let error = await cache.error
            if let error, !error.isEmpty {
                return [PaletteItem(
                    id: "finder:permission",
                    title: "Finder Automation permission required",
                    subtitle: error,
                    icon: .symbol("lock.shield"),
                    badge: "PERMISSION",
                    score: 10_000,
                    actions: [PaletteAction(
                        id: "permission",
                        title: "Open Automation Settings",
                        kind: .openURL,
                        value: .text("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
                    )],
                    preview: .text("Allow Palette to control Finder in System Settings → Privacy & Security → Automation, then run /finder again."),
                    providerID: descriptor.id,
                    providerName: descriptor.name
                )]
            }
            return [PaletteItem(
                id: "finder:none",
                title: "No Finder selection",
                subtitle: "Select one or more files in Finder, then run /finder again",
                icon: .symbol("cursorarrow"),
                badge: "FINDER",
                score: 1_000,
                actions: [PaletteAction(id: "open", title: "Open Finder", kind: .openPath, value: .text(NSHomeDirectory()))],
                providerID: descriptor.id,
                providerName: descriptor.name
            )]
        }
        let folder = Self.folder(for: paths[0])
        let name = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) items"
        let value = ["paths": paths.joined(separator: "\n"), "folder": folder]
        let actions: [PaletteAction] = [
            PaletteAction(id: "terminal", title: "Open Terminal Here", kind: .custom, value: .object(value)),
            PaletteAction(id: "ghostty", title: "Open Ghostty Here", kind: .custom, value: .object(value)),
            PaletteAction(id: "neovide", title: "Open in Neovide", kind: .custom, value: .object(value)),
            PaletteAction(id: "copy-paths", title: "Copy Absolute Paths", kind: .copyText, value: .text(paths.joined(separator: "\n"))),
            PaletteAction(id: "reveal", title: "Reveal in Finder", kind: .custom, value: .object(value)),
            PaletteAction(id: "compress", title: "Compress Selection", kind: .custom, value: .object(value)),
            PaletteAction(id: "new-file", title: "New File Here…", kind: .custom, value: .object(value)),
            PaletteAction(id: "new-folder", title: "New Folder Here…", kind: .custom, value: .object(value)),
        ]
        return [PaletteItem(
            id: "finder:\(paths.joined(separator: "|"))",
            title: name,
            subtitle: folder,
            icon: .file(paths[0]),
            badge: "FINDER",
            score: 1_000,
            actions: actions,
            preview: .files(paths: paths),
            providerID: descriptor.id,
            providerName: descriptor.name
        )]
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        if action.id == "load" {
            _ = await selection()
            await bridge.notify("Finder selection read; run /finder again")
            return
        }
        guard let value = action.value.object,
              let paths = value["paths"]?.split(separator: "\n").map(String.init),
              let folder = value["folder"] else { return }
        switch action.id {
        case "terminal":
            try await MainActor.run {
                try launcher.openTerminal(command: "cd \(Self.shellQuote(folder))", app: terminal)
            }
        case "ghostty":
            try await MainActor.run { try launcher.openPath(folder, with: "Ghostty") }
        case "neovide":
            try await MainActor.run { try launcher.openPath(paths.first ?? folder, with: "neovide") }
        case "reveal":
            await MainActor.run { launcher.reveal(paths.first ?? folder) }
        case "compress":
            try await compress(paths: paths, folder: folder)
        case "new-file":
            guard let name = await bridge.prompt(kind: .text, title: "New file in \((folder as NSString).lastPathComponent)", placeholder: "notes.md"),
                  !name.isEmpty else { return }
            let target = (folder as NSString).appendingPathComponent(name)
            FileManager.default.createFile(atPath: target, contents: Data())
            await bridge.notify("Created \(name)")
        case "new-folder":
            guard let name = await bridge.prompt(kind: .text, title: "New folder in \((folder as NSString).lastPathComponent)", placeholder: "New Folder"),
                  !name.isEmpty else { return }
            try FileManager.default.createDirectory(
                atPath: (folder as NSString).appendingPathComponent(name),
                withIntermediateDirectories: false
            )
            await bridge.notify("Created \(name)")
        default:
            break
        }
    }

    private func compress(paths: [String], folder: String) async throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = (folder as NSString).appendingPathComponent("Archive-\(stamp).zip")
        var arguments = ["-c", "-k", "--sequesterRsrc", target]
        arguments.append(contentsOf: paths)
        let result = try await ProcessRunner.run(["/usr/bin/ditto"] + arguments, timeout: 120)
        if result.status == 0 {
            await bridge.notify("Compressed to \((target as NSString).lastPathComponent)")
        } else {
            await bridge.notify("Compression failed: \(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private func selection() async -> [String] {
        let now = Date()
        let cached = await cache.paths
        let cachedAt = await cache.at
        if now.timeIntervalSince(cachedAt) < 3 { return cached }

        let script = """
        tell application "Finder"
            set out to ""
            repeat with f in selection
                set out to out & POSIX path of (f as alias) & linefeed
            end repeat
            return out
        end tell
        """
        let result = try? await ProcessRunner.run(["/usr/bin/osascript", "-e", script], timeout: 5)
        let paths = (result?.stdoutString ?? "")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
        let error = (result?.status ?? 0) == 0 ? nil : result?.stderrString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        await cache.update(paths, error: error, at: now)
        return paths
    }

    private static func folder(for path: String) -> String {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
