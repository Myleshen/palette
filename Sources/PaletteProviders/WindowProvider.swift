import AppKit
import ApplicationServices
import Foundation
import PaletteCore
import PalettePlatform

/// Window switcher: every open window, keyboard-first, Enter raises it.
public final class WindowProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "win",
        name: "Windows",
        trigger: "win",
        isGlobal: true,
        priority: 43,
        icon: "symbol:macwindow.on.rectangle",
        keywords: ["window", "switch", "alt tab", "app", "focus"]
    )

    private let launcher: LauncherService

    public init(launcher: LauncherService) {
        self.launcher = launcher
    }

    private struct Entry: Sendable {
        var pid: pid_t
        var appName: String
        var title: String
        var bounds: CGRect
        var number: Int
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let entries = await Self.windows().filter { $0.pid != ownPID }

        let items = entries.compactMap { entry -> PaletteItem? in
            let title = entry.title.isEmpty ? entry.appName : entry.title
            // Every window is a candidate when the query is empty; otherwise
            // the host's fuzzy score decides, matching every other provider.
            let score = query.isEmpty
                ? 9_000
                : Ranking.score(query: query, candidate: "\(title) \(entry.appName)")
            guard let score else { return nil }
            return PaletteItem(
                id: "win:\(entry.number)",
                title: title,
                subtitle: entry.appName == title ? nil : entry.appName,
                icon: .symbol("rectangle.inset.filled"),
                group: entry.appName,
                score: score,
                actions: [PaletteAction(id: "focus", title: "Switch to \(entry.appName)", kind: .custom, value: .text("focus:\(entry.number):\(entry.pid)"))],
                providerID: descriptor.id,
                providerName: descriptor.name
            )
        }
        return items
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let raw = action.value.text, raw.hasPrefix("focus:") else { return }
        let parts = raw.dropFirst("focus:".count).split(separator: ":").map(String.init)
        guard parts.count == 2, let number = Int(parts[0]), let pid = Int32(parts[1]) else { return }
        let title = item.title
        await MainActor.run {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: [.activateAllWindows])
            }
            Self.raise(windowNumber: number, pid: pid, title: title)
        }
    }

    // MARK: - Windows

    private static func windows() async -> [Entry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var entries: [Entry] = []
        for raw in list {
            guard let layer = raw[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = raw[kCGWindowOwnerPID as String] as? pid_t,
                  let appName = raw[kCGWindowOwnerName as String] as? String,
                  let number = raw[kCGWindowNumber as String] as? Int,
                  let boundsDict = raw[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            guard bounds.width > 120, bounds.height > 80 else { continue }
            let title = (raw[kCGWindowName as String] as? String) ?? ""
            let key = "\(pid)|\(title)|\(Int(bounds.width))x\(Int(bounds.height))"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            entries.append(Entry(pid: pid, appName: appName, title: title, bounds: bounds, number: number))
        }
        return entries
    }

    /// Raises the matching AX window; falls back to the app activation.
    private static func raise(windowNumber: Int, pid: pid_t, title: String) {
        let appElement = AXUIElementCreateApplication(pid)
        guard let windows = Self.attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else { return }
        for window in windows {
            let windowTitle = (Self.attribute(window, kAXTitleAttribute) as? String) ?? ""
            if windowTitle == title {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
                return
            }
        }
        if let first = windows.first {
            AXUIElementPerformAction(first, kAXRaiseAction as CFString)
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return result == .success ? value : nil
    }
}
