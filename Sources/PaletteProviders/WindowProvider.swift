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
    private let titles: WindowTitleResolver

    public convenience init(launcher: LauncherService) {
        self.init(launcher: launcher, titles: WindowTitleResolver())
    }

    init(launcher: LauncherService, titles: WindowTitleResolver) {
        self.launcher = launcher
        self.titles = titles
    }

    struct Entry: Sendable {
        var pid: pid_t
        var appName: String
        var title: String
        var bounds: CGRect
        var number: Int?
        var key: String
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let entries = Self.windows().filter { $0.pid != ownPID }

        var items: [PaletteItem] = []
        for entry in entries {
            let title = entry.title.isEmpty
                ? (await titles.title(for: entry.bounds, pid: entry.pid) ?? "")
                : entry.title
            let row = Self.row(title: title, appName: entry.appName, bounds: entry.bounds)
            // Every window is a candidate when the query is empty; otherwise
            // the host's fuzzy score decides, matching every other provider.
            let score = query.isEmpty
                ? 9_000
                : Ranking.score(query: query, candidate: "\(row.title) \(entry.appName)")
            guard let score else { continue }
            items.append(PaletteItem(
                id: "win:\(entry.key)",
                title: row.title,
                subtitle: row.subtitle,
                icon: .symbol("rectangle.inset.filled"),
                group: entry.appName,
                score: score,
                actions: [PaletteAction(id: "focus", title: "Switch to \(entry.appName)", kind: .custom, value: .text("focus:\(entry.number ?? 0):\(entry.pid)"))],
                providerID: descriptor.id,
                providerName: descriptor.name
            ))
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

    private static func windows() -> [Entry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Self.entries(from: list)
    }

    /// Maps a CG window list to entries. One entry per CG window number, so
    /// two untitled windows of the same size both survive; the older
    /// `pid|title|WxH` key collapsed them.
    static func entries(from list: [[String: Any]]) -> [Entry] {
        var seen = Set<String>()
        var entries: [Entry] = []
        for (index, raw) in list.enumerated() {
            guard let layer = raw[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = raw[kCGWindowOwnerPID as String] as? pid_t,
                  let appName = raw[kCGWindowOwnerName as String] as? String,
                  let boundsDict = raw[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            // A fully transparent window is a helper, not something to switch to.
            if let alpha = raw[kCGWindowAlpha as String] as? Double, alpha == 0 { continue }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            guard bounds.width > 120, bounds.height > 80 else { continue }
            let number = raw[kCGWindowNumber as String] as? Int
            let key = Self.dedupeKey(pid: pid, number: number, bounds: bounds, index: index)
            guard seen.insert(key).inserted else { continue }
            let title = (raw[kCGWindowName as String] as? String) ?? ""
            entries.append(Entry(pid: pid, appName: appName, title: title, bounds: bounds, number: number, key: key))
        }
        return entries
    }

    static func dedupeKey(pid: pid_t, number: Int?, bounds: CGRect, index: Int) -> String {
        if let number { return "\(pid)|\(number)" }
        return "\(pid)|\(Int(bounds.width))x\(Int(bounds.height))|\(index)"
    }

    /// The row text: a titled window shows its title and app; an untitled one
    /// still gets a readable row, never a blank title.
    static func row(title: String, appName: String, bounds: CGRect) -> (title: String, subtitle: String?) {
        guard title.isEmpty else { return (title, title == appName ? nil : appName) }
        return ("Untitled window", "\(appName) · \(Int(bounds.width))×\(Int(bounds.height))")
    }

    /// Raises the matching AX window; falls back to the app activation.
    private static func raise(windowNumber: Int, pid: pid_t, title: String) {
        let appElement = AXUIElementCreateApplication(pid)
        guard let windows = AXAccess.attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else { return }
        for window in windows {
            let windowTitle = (AXAccess.attribute(window, kAXTitleAttribute) as? String) ?? ""
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
}
