import Foundation

/// The launcher has four focus zones. Only the search field ever owns the real
/// keyboard focus, so typing keeps working everywhere; this zone decides what
/// Tab, the arrow keys, Enter and Esc act on.
public enum LauncherZone: String, Sendable, Equatable, CaseIterable {
    case search
    case list
    case rail
    case strip
}

public enum LauncherFocus {
    /// Tab order: search → list → rail → strip. The strip only joins the cycle
    /// while the active rail row is a group; Shift-Tab runs the same order in
    /// reverse and every end wraps.
    public static func tab(from zone: LauncherZone, forward: Bool, hasStrip: Bool) -> LauncherZone {
        let order: [LauncherZone] = hasStrip
            ? [.search, .list, .rail, .strip]
            : [.search, .list, .rail]
        guard let index = order.firstIndex(of: zone) else { return .search }
        let step = forward ? index + 1 : index - 1
        return order[(step + order.count) % order.count]
    }
}

public enum HotkeyTargets {
    /// ⌘⌥S opens the scratchpad *list*, not the editor's most recent note.
    public static let scratchpadListTrigger = "scratch"

    public static func scratchpadListQuery(prefix: String) -> String {
        prefix + scratchpadListTrigger + " "
    }

    public enum ScratchpadAction: Equatable, Sendable {
        case showList
        case hide
    }

    /// A second press over an already visible list closes it; anything else
    /// lands the user on the list.
    public static func scratchpadAction(panelVisible: Bool, listActive: Bool) -> ScratchpadAction {
        panelVisible && listActive ? .hide : .showList
    }
}
