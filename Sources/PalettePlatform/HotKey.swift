import AppKit
import Carbon.HIToolbox
import PaletteCore

public struct HotKeySpec: Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var display: String

    public init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// Human-readable keycaps for the UI ("⌥Space", "⌘⇧3"). `display` stays
    /// the canonical string `parse` accepts.
    public var prettyDisplay: String {
        let parts = display.lowercased().split(separator: "+").map(String.init)
        let key = parts.last { !Self.modifierWords.contains($0) } ?? ""
        var result = ""
        // Command first, matching how this app writes shortcuts in its docs.
        if parts.contains("cmd") || parts.contains("command") || parts.contains("meta") { result += "⌘" }
        if parts.contains("ctrl") || parts.contains("control") { result += "⌃" }
        if parts.contains("opt") || parts.contains("option") || parts.contains("alt") { result += "⌥" }
        if parts.contains("shift") { result += "⇧" }
        return result + Self.prettyKey(key)
    }

    private static let modifierWords: Set<String> = [
        "cmd", "command", "meta", "opt", "option", "alt", "ctrl", "control", "shift",
    ]

    private static func prettyKey(_ name: String) -> String {
        switch name {
        case "space": return "Space"
        case "return", "enter": return "↩"
        case "tab": return "⇥"
        case "esc", "escape": return "⎋"
        default: return name.uppercased()
        }
    }

    /// Carbon's real identity for the pair, used to spot a duplicate without
    /// caring about modifier order or aliases.
    public var identity: String { "\(keyCode)-\(modifiers)" }

    public static func parse(_ raw: String) -> HotKeySpec? {
        let parts = raw
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var modifiers: UInt32 = 0
        var keyName: String?
        for part in parts {
            switch part {
            case "cmd", "command", "meta": modifiers |= UInt32(cmdKey)
            case "opt", "option", "alt": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: keyName = part
            }
        }

        guard let keyName, let keyCode = keyCode(for: keyName), modifiers != 0 else { return nil }
        return HotKeySpec(keyCode: keyCode, modifiers: modifiers, display: parts.joined(separator: "+"))
    }

    /// Recorder support: turn a real key press into the same canonical string
    /// `parse` accepts, so Settings can record instead of asking for typed text.
    public static func from(event: NSEvent) -> HotKeySpec? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        var parts: [String] = []
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); parts.append("cmd") }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); parts.append("opt") }
        if flags.contains(.control) { modifiers |= UInt32(controlKey); parts.append("ctrl") }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); parts.append("shift") }
        guard modifiers != 0,
              let name = keyName(for: Int(event.keyCode)) else { return nil }
        parts.append(name)
        let display = parts.joined(separator: "+")
        guard parse(display) != nil else { return nil }
        return HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: modifiers, display: display)
    }

    private static func keyName(for code: Int) -> String? {
        let map: [Int: String] = [
            kVK_Space: "space", kVK_Return: "return", kVK_Tab: "tab", kVK_Escape: "esc",
            kVK_ANSI_A: "a", kVK_ANSI_S: "s", kVK_ANSI_D: "d", kVK_ANSI_F: "f",
            kVK_ANSI_H: "h", kVK_ANSI_G: "g", kVK_ANSI_Z: "z", kVK_ANSI_X: "x",
            kVK_ANSI_C: "c", kVK_ANSI_V: "v", kVK_ANSI_B: "b", kVK_ANSI_Q: "q",
            kVK_ANSI_W: "w", kVK_ANSI_E: "e", kVK_ANSI_R: "r", kVK_ANSI_Y: "y",
            kVK_ANSI_T: "t", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_6: "6", kVK_ANSI_5: "5", kVK_ANSI_9: "9",
            kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_0: "0", kVK_ANSI_O: "o",
            kVK_ANSI_U: "u", kVK_ANSI_I: "i", kVK_ANSI_P: "p", kVK_ANSI_L: "l",
            kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_N: "n", kVK_ANSI_M: "m",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Minus: "-",
            kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`",
            kVK_F1: "f1", kVK_F2: "f2", kVK_F3: "f3", kVK_F4: "f4",
            kVK_F5: "f5", kVK_F6: "f6", kVK_F7: "f7", kVK_F8: "f8",
            kVK_F9: "f9", kVK_F10: "f10", kVK_F11: "f11", kVK_F12: "f12",
        ]
        return map[code]
    }

    private static func keyCode(for name: String) -> UInt32? {
        let map: [String: Int] = [
            "space": kVK_Space,
            "return": kVK_Return,
            "enter": kVK_Return,
            "tab": kVK_Tab,
            "escape": kVK_Escape,
            "esc": kVK_Escape,
            "a": kVK_ANSI_A, "s": kVK_ANSI_S, "d": kVK_ANSI_D, "f": kVK_ANSI_F,
            "h": kVK_ANSI_H, "g": kVK_ANSI_G, "z": kVK_ANSI_Z, "x": kVK_ANSI_X,
            "c": kVK_ANSI_C, "v": kVK_ANSI_V, "b": kVK_ANSI_B, "q": kVK_ANSI_Q,
            "w": kVK_ANSI_W, "e": kVK_ANSI_E, "r": kVK_ANSI_R, "y": kVK_ANSI_Y,
            "t": kVK_ANSI_T, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "6": kVK_ANSI_6, "5": kVK_ANSI_5, "9": kVK_ANSI_9,
            "7": kVK_ANSI_7, "8": kVK_ANSI_8, "0": kVK_ANSI_0, "o": kVK_ANSI_O,
            "u": kVK_ANSI_U, "i": kVK_ANSI_I, "p": kVK_ANSI_P, "l": kVK_ANSI_L,
            "j": kVK_ANSI_J, "k": kVK_ANSI_K, "n": kVK_ANSI_N, "m": kVK_ANSI_M,
            ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, "[": kVK_ANSI_LeftBracket,
            "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "`": kVK_ANSI_Grave,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
            "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
            "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        ]
        return map[name].map(UInt32.init)
    }
}

/// Filters `[[binding]]` rows down to the ones that can be registered, and
/// explains every row it had to drop. The first binding wins a duplicate key.
public enum HotKeyBindings {
    public static func usable(
        _ bindings: [HotkeyBinding],
        reserved: [String] = []
    ) -> (usable: [HotkeyBinding], issues: [String]) {
        var seen = Set<String>()
        for key in reserved {
            if let spec = HotKeySpec.parse(key) { seen.insert(spec.identity) }
        }
        var usable: [HotkeyBinding] = []
        var issues: [String] = []
        for binding in bindings {
            let keys = binding.keys.trimmingCharacters(in: .whitespaces)
            let value = binding.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keys.isEmpty, !value.isEmpty else {
                issues.append("Binding '\(keys)' skipped: keys and a value are required.")
                continue
            }
            guard let spec = HotKeySpec.parse(keys) else {
                issues.append("Binding '\(keys)' skipped: not a valid shortcut.")
                continue
            }
            guard seen.insert(spec.identity).inserted else {
                issues.append("Binding '\(keys)' skipped: the shortcut is already in use.")
                continue
            }
            usable.append(HotkeyBinding(keys: keys, action: binding.action, value: value))
        }
        return (usable, issues)
    }
}

/// Filters `[[shortcut]]` rows down to the ones that can be registered and
/// explains every row it had to drop. Unknown command ids are reported but
/// left in config.toml by the writer, so a newer build can still use them.
public enum ShortcutResolver {
    public struct Plan: Sendable, Equatable {
        public var resolved: [ShortcutBinding]
        public var issues: [String]

        public init(resolved: [ShortcutBinding] = [], issues: [String] = []) {
            self.resolved = resolved
            self.issues = issues
        }
    }

    public static func resolve(
        _ entries: [ShortcutBinding],
        commands: [CatalogCommand],
        reserved: [String] = []
    ) -> Plan {
        let known = Set(commands.map(\.id))
        var seen = Set<String>()
        for key in reserved {
            if let spec = HotKeySpec.parse(key) { seen.insert(spec.identity) }
        }
        var resolved: [ShortcutBinding] = []
        var issues: [String] = []
        for entry in entries {
            let command = entry.command.trimmingCharacters(in: .whitespaces)
            let keys = entry.keys.trimmingCharacters(in: .whitespaces)
            guard known.contains(command) else {
                issues.append("Shortcut '\(command)' skipped: unknown command.")
                continue
            }
            guard !keys.isEmpty else { continue }
            guard let spec = HotKeySpec.parse(keys) else {
                issues.append("Shortcut '\(keys)' for \(command) skipped: not a valid shortcut.")
                continue
            }
            guard seen.insert(spec.identity).inserted else {
                issues.append("Shortcut '\(keys)' for \(command) skipped: the shortcut is already in use.")
                continue
            }
            resolved.append(ShortcutBinding(command: command, keys: keys))
        }
        return Plan(resolved: resolved, issues: issues)
    }
}

/// Whether a key combination can be claimed. Carbon exposes no list, so this
/// is only answerable by trying to register and letting go again.
public enum HotKeyProbe: Equatable, Sendable {
    case available
    case usedByPalette
    case usedBySystem

    /// A failure means someone else owns the pair: macOS, another app, or a
    /// Palette registration the live set does not know about.
    public static func classify(isLive: Bool, status: OSStatus) -> HotKeyProbe {
        if isLive { return .usedByPalette }
        return status == noErr ? .available : .usedBySystem
    }
}

/// The one message a recorder shows: our own keys first so a live registration
/// of ours is never blamed on macOS, then the throwaway Carbon probe.
public enum ShortcutAvailability {
    public static let usedByPalette = "Used by Palette"
    public static let usedByAnotherApp = "Already used by another app"

    public static func message(
        for spec: HotKeySpec,
        ownedKeys: [String],
        probe: (HotKeySpec) -> HotKeyProbe = HotKeyManager.probe
    ) -> String? {
        let owned = ownedKeys.contains { key in
            guard let other = HotKeySpec.parse(key) else { return false }
            return other.identity == spec.identity
        }
        if owned { return usedByPalette }
        switch probe(spec) {
        case .available: return nil
        case .usedByPalette: return usedByPalette
        case .usedBySystem: return usedByAnotherApp
        }
    }
}

/// A shortcut Palette wants to own, before any Carbon call. `id` is the stable
/// row id Settings uses to ask why a key is unavailable.
public struct HotKeyRequest: Sendable, Equatable {
    public var id: String
    public var label: String
    public var keys: String

    public init(id: String, label: String, keys: String) {
        self.id = id
        self.label = label
        self.keys = keys
    }
}

/// One line of the plan: either the request may register, or an earlier entry
/// already owns the key and this one is unavailable.
public struct HotKeyResolution: Sendable, Equatable {
    public var request: HotKeyRequest
    public var unavailable: String?

    public init(request: HotKeyRequest, unavailable: String? = nil) {
        self.request = request
        self.unavailable = unavailable
    }
}

/// Decides Palette-internal collisions before anything touches Carbon. Input
/// order is the priority: built-ins, then web apps, then `[[binding]]`, then
/// the catalogue, so a launch and a reload resolve the same way.
public enum HotKeyPlan {
    public static func resolve(_ requests: [HotKeyRequest]) -> [HotKeyResolution] {
        var owners: [String: String] = [:]
        return requests.map { request in
            let keys = request.keys.trimmingCharacters(in: .whitespaces)
            guard !keys.isEmpty else { return HotKeyResolution(request: request) }
            guard let spec = HotKeySpec.parse(keys) else {
                return HotKeyResolution(request: request, unavailable: HotKeyUnavailable.invalid)
            }
            if let owner = owners[spec.identity] {
                return HotKeyResolution(request: request, unavailable: HotKeyUnavailable.usedBy(owner))
            }
            owners[spec.identity] = request.label
            return HotKeyResolution(request: request)
        }
    }
}

public enum HotKeyUnavailable {
    public static let anotherApp = "Unavailable — already used by another app"
    public static let invalid = "Unavailable — not a valid shortcut"
    public static func usedBy(_ owner: String) -> String { "Unavailable — used by \(owner)" }
}

/// What the live registration pass achieved, readable by Settings. `id` matches
/// the row id (`launcher`, a catalogue command id, `binding-3`, `web:<uuid>`).
public struct HotKeyStatus: Sendable, Equatable {
    public var id: String
    public var label: String
    public var keys: String
    /// nil when Palette holds the key; otherwise the red line Settings shows.
    public var unavailable: String?

    public init(id: String, label: String, keys: String, unavailable: String? = nil) {
        self.id = id
        self.label = label
        self.keys = keys
        self.unavailable = unavailable
    }
}

public enum HotKeyRegistry {
    nonisolated(unsafe) private static var entries: [String: HotKeyStatus] = [:]
    private static let lock = NSLock()

    public static func replaceAll(_ newEntries: [HotKeyStatus]) {
        lock.lock()
        entries = Dictionary(newEntries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        lock.unlock()
    }

    public static func status(id: String) -> HotKeyStatus? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]
    }

    public static func unavailable(id: String) -> String? {
        status(id: id)?.unavailable
    }
}

/// One Carbon handler for the whole process. `InstallEventHandler` replaces the
/// previous handler for the same target and event kind, so installing one per
/// manager silently disables every hotkey registered before it.
private final class HotKeyRouter {
    static let shared = HotKeyRouter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?

    func set(_ id: UInt32, handler: @escaping () -> Void) {
        handlers[id] = handler
        installIfNeeded()
    }

    func remove(_ id: UInt32) {
        handlers[id] = nil
    }

    private func installIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                var pressed = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressed
                )
                let router = Unmanaged<HotKeyRouter>.fromOpaque(userData).takeUnretainedValue()
                guard let handler = router.handlers[pressed.id] else { return noErr }
                DispatchQueue.main.async { handler() }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )
    }
}

public final class HotKeyManager {
    public var onPressed: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var registered: HotKeySpec?
    private var hotKeyID: UInt32

    /// Identities this process currently owns. A probe must answer "Used by
    /// Palette" for these instead of blaming another app.
    nonisolated(unsafe) private static var liveIdentities: Set<String> = []
    private static let liveLock = NSLock()
    /// Throwaway id for probes, above the catalogue range.
    private static let probeID: UInt32 = 900
    /// Every successful registration gets a fresh id, so an attempt can be made
    /// while the old key is still live without Carbon rejecting the duplicate.
    nonisolated(unsafe) private static var installID: UInt32 = 1000
    private static let installLock = NSLock()

    private static func nextInstallID() -> UInt32 {
        installLock.lock()
        defer { installLock.unlock() }
        installID += 1
        return installID
    }

    /// Each manager needs its own id: Carbon rejects a duplicate pair.
    public init(hotKeyID: UInt32 = 1) {
        self.hotKeyID = hotKeyID
    }

    deinit {
        unregister()
    }

    @discardableResult
    public func register(_ raw: String) throws -> HotKeySpec {
        guard let spec = HotKeySpec.parse(raw) else {
            throw ProviderError.failed("Invalid hotkey '\(raw)'")
        }
        // Register the new pair first, under a fresh id. A failure (another app
        // owns it) leaves the previous registration untouched, so a reload can
        // never leave the user with no shortcut at all.
        let candidateID = Self.nextInstallID()
        var candidateRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers,
            EventHotKeyID(signature: OSType(0x50414C54), id: candidateID), // 'PALT'
            GetApplicationEventTarget(),
            0,
            &candidateRef
        )
        guard status == noErr else {
            let kept = registered.map { " Kept \($0.prettyDisplay)." } ?? ""
            throw ProviderError.failed("Hotkey \(raw) is already in use.\(kept)")
        }

        let previousID = hotKeyID
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let registered {
            Self.liveLock.lock()
            Self.liveIdentities.remove(registered.identity)
            Self.liveLock.unlock()
        }
        HotKeyRouter.shared.remove(previousID)

        hotKeyID = candidateID
        hotKeyRef = candidateRef
        registered = spec
        HotKeyRouter.shared.set(hotKeyID) { [weak self] in self?.onPressed?() }
        Self.liveLock.lock()
        Self.liveIdentities.insert(spec.identity)
        Self.liveLock.unlock()
        return spec
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let registered {
            Self.liveLock.lock()
            Self.liveIdentities.remove(registered.identity)
            Self.liveLock.unlock()
        }
        HotKeyRouter.shared.remove(hotKeyID)
        registered = nil
    }

    public var current: HotKeySpec? { registered }

    /// Try the pair with a throwaway id and release it at once. Only a live
    /// registration of our own is distinguishable from someone else's.
    public static func probe(_ spec: HotKeySpec) -> HotKeyProbe {
        liveLock.lock()
        let live = liveIdentities.contains(spec.identity)
        liveLock.unlock()
        if live { return HotKeyProbe.classify(isLive: true, status: noErr) }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x50414C54), id: probeID)
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if let ref { UnregisterEventHotKey(ref) }
        return HotKeyProbe.classify(isLive: false, status: status)
    }
}
