import Foundation

/// Whether the user's terminal or Neovide is already translucent, so the nvim
/// file can skip its normal background. Reads the real config under `home`;
/// anything missing or unreadable counts as opaque.
public enum TransparencyDetection {
    public struct Result: Sendable, Equatable {
        public var isTransparent: Bool
        /// Short diagnostic, e.g. "kitty 0.6"; empty when opaque.
        public var reason: String

        public init(isTransparent: Bool, reason: String = "") {
            self.isTransparent = isTransparent
            self.reason = reason
        }
    }

    public static func detect(home: String) -> Result {
        let root = URL(fileURLWithPath: home, isDirectory: true)
        let kitty = root.appendingPathComponent(".config/kitty")
        for name in ["kitty.conf", "quick-access-terminal.conf"] {
            if let value = lastConfigValue("background_opacity", at: kitty.appendingPathComponent(name)),
               value < 1 {
                return Result(isTransparent: true, reason: "kitty \(value)")
            }
        }
        let ghostty = root.appendingPathComponent(".config/ghostty/config")
        if let value = lastConfigValue("background-opacity", at: ghostty), value < 1 {
            return Result(isTransparent: true, reason: "ghostty \(value)")
        }
        if let value = neovideOpacity(root: root) {
            return Result(isTransparent: true, reason: "neovim lua \(value)")
        }
        return Result(isTransparent: false)
    }

    /// The last assignment wins, as it does in kitty and Ghostty. Accepts
    /// `key value` and `key = value`, ignores comments.
    private static func lastConfigValue(_ key: String, at url: URL) -> Double? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var value: Double?
        for line in text.split(whereSeparator: \.isNewline) {
            let body = line.prefix { $0 != "#" }
            let parts = body.split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            guard parts.count >= 2, parts[0] == key[...], let parsed = Double(parts[1]) else { continue }
            value = parsed
        }
        return value
    }

    private static func neovideOpacity(root: URL) -> Double? {
        let directory = root.appendingPathComponent(".config/nvim/lua", isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let files = walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "lua" }
            .sorted { $0.path < $1.path }
        for file in files {
            if let value = lastLuaOpacity(in: file), value < 1 { return value }
        }
        return nil
    }

    private static let opacityPattern = try? NSRegularExpression(
        pattern: "neovide_(?:normal_)?opacity\\s*=\\s*([0-9]*\\.?[0-9]+)"
    )

    private static func lastLuaOpacity(in url: URL) -> Double? {
        guard let pattern = opacityPattern,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        var value: Double?
        for match in pattern.matches(in: text, range: range) {
            guard let captured = Range(match.range(at: 1), in: text),
                  let parsed = Double(text[captured]) else { continue }
            value = parsed
        }
        return value
    }
}
