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

    public static func parse(_ raw: String) -> HotKeySpec? {        let parts = raw
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
    private let hotKeyID: UInt32

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
        unregister()
        HotKeyRouter.shared.set(hotKeyID) { [weak self] in self?.onPressed?() }

        let hotKeyID = EventHotKeyID(signature: OSType(0x50414C54), id: hotKeyID) // 'PALT'
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            throw ProviderError.failed("Hotkey \(raw) is already in use. Change it in config.toml.")
        }
        registered = spec
        return spec
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        HotKeyRouter.shared.remove(hotKeyID)
        registered = nil
    }

    public var current: HotKeySpec? { registered }
}
