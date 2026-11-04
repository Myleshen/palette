import AppKit
import ApplicationServices
import Foundation
import PaletteCore
import PalettePlatform

/// Actions on the current Finder selection. The selection is read through the
/// Accessibility API, so it works with the Accessibility grant Palette already
/// needs and does not depend on AppleScript/Automation.
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
        var at = Date.distantPast

        func update(_ paths: [String], at date: Date) {
            self.paths = paths
            self.at = date
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
        guard AXIsProcessTrusted() else {
            return [PaletteItem(
                id: "finder:accessibility",
                title: "Accessibility permission required",
                subtitle: "Palette needs Accessibility to read Finder’s selection",
                icon: .symbol("lock.shield"),
                badge: "PERMISSION",
                score: 10_000,
                actions: [PaletteAction(
                    id: "permission",
                    title: "Open Accessibility Settings",
                    kind: .openURL,
                    value: .text("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                )],
                preview: .text("Allow Palette in System Settings → Privacy & Security → Accessibility, then run /finder again."),
                providerID: descriptor.id,
                providerName: descriptor.name
            )]
        }

        let paths = await selection()
        if paths.isEmpty {
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
        let names = paths.map { path -> String in
            path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path
        }
        let result = try await ProcessRunner.run(
            ["/usr/bin/zip", "-r", "-y", "-q", target] + names,
            cwd: folder,
            timeout: 120
        )
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

        let paths = Self.accessibilitySelection()
        await cache.update(paths, at: now)
        return paths
    }

    /// Finder does not expose a scripting-free selection API, but its browser
    /// rows and icon cells are ordinary Accessibility elements. Walk the
    /// focused window and collect anything marked AXSelected, then resolve its
    /// URL (or filename relative to the window's folder).
    private static func accessibilitySelection() -> [String] {
        guard let finder = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.finder"
        }) else { return [] }

        let app = AXUIElementCreateApplication(finder.processIdentifier)
        var roots: [AXUIElement] = []
        if let focused = attribute(app, kAXFocusedWindowAttribute) {
            roots = [focused as! AXUIElement]
        } else if let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] {
            roots = windows
        }

        var paths = Set<String>()
        var visited = 0
        for window in roots {
            let folder = path(from: attribute(window, kAXDocumentAttribute))
                ?? path(from: attribute(window, kAXURLAttribute))
            walk(window, folder: folder, depth: 0, visited: &visited, paths: &paths)
        }
        let result = paths.sorted()
        Log.shared.info(
            "Finder AX selection: \(result.count) path(s) from \(visited) element(s)",
            source: "finder"
        )
        return result
    }

    private static func walk(
        _ element: AXUIElement,
        folder: String?,
        depth: Int,
        visited: inout Int,
        paths: inout Set<String>
    ) {
        guard depth <= 14, visited < 8_000 else { return }
        visited += 1

        if let selectedChildren = attribute(element, kAXSelectedChildrenAttribute) as? [AXUIElement] {
            for child in selectedChildren {
                if let value = path(from: attribute(child, kAXURLAttribute))
                    ?? path(from: attribute(child, kAXDocumentAttribute)) {
                    paths.insert(value)
                } else if let name = attribute(child, kAXFilenameAttribute) as? String,
                          let folder, !name.isEmpty {
                    paths.insert((folder as NSString).appendingPathComponent(name))
                }
            }
        }

        let selected = attribute(element, kAXSelectedAttribute) as? Bool ?? false
        if selected {
            let currentFolder = path(from: attribute(element, kAXURLAttribute))
                ?? path(from: attribute(element, kAXDocumentAttribute))
            if let value = currentFolder {
                paths.insert(value)
            } else if let name = attribute(element, kAXFilenameAttribute) as? String,
                      let folder, !name.isEmpty {
                paths.insert((folder as NSString).appendingPathComponent(name))
            }
        }

        guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children {
            walk(child, folder: folder, depth: depth + 1, visited: &visited, paths: &paths)
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func path(from value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if CFGetTypeID(value) == CFURLGetTypeID(), let url = value as? URL {
            return url.isFileURL ? url.path : nil
        }
        if let string = value as? String {
            if string.hasPrefix("file://"), let url = URL(string: string) {
                return url.path
            }
            if string.hasPrefix("/"), FileManager.default.fileExists(atPath: string) {
                return string
            }
        }
        return nil
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
