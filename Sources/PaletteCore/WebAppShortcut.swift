import Foundation

/// A Hammerspoon-compatible shortcut such as `ctrl+alt+f`.
///
/// Shortcuts are stored canonically so duplicates are easy to detect and the
/// generated Hammerspoon file never has to normalize anything.
public struct WebAppShortcut: Equatable, Sendable {
    public let modifiers: [String]
    public let key: String

    public var canonical: String {
        (modifiers + [key]).joined(separator: "+")
    }

    public static func parse(_ raw: String) -> WebAppShortcut? {
        let parts = raw
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count >= 3 else { return nil }

        var modifiers: Set<String> = []
        var key: String?
        for part in parts {
            switch part {
            case "cmd", "command", "meta": modifiers.insert("cmd")
            case "opt", "option", "alt": modifiers.insert("alt")
            case "ctrl", "control": modifiers.insert("ctrl")
            case "shift": modifiers.insert("shift")
            default:
                if key != nil { return nil }
                key = part
            }
        }

        guard modifiers.count >= 2, let key, isSupportedKey(key) else { return nil }
        let order = ["ctrl", "alt", "shift", "cmd"]
        let normalizedKey: String
        switch key {
        case "enter": normalizedKey = "return"
        case "esc": normalizedKey = "escape"
        default: normalizedKey = key
        }
        return WebAppShortcut(modifiers: order.filter(modifiers.contains), key: normalizedKey)
    }

    private static func isSupportedKey(_ key: String) -> Bool {
        if key.count == 1, key.allSatisfy({ $0.isLetter || $0.isNumber }) { return true }
        var named: Set<String> = [
            "space", "return", "enter", "tab", "escape", "esc",
            "left", "right", "up", "down", "home", "end", "pageup", "pagedown",
        ]
        named.formUnion((1...12).map { "f\($0)" })
        return named.contains(key)
    }
}
