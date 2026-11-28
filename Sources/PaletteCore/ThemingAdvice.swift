import Foundation

/// One line in a user's own config that stops Palette's palette from taking
/// effect, with the fix. Pure: this only reads files and never writes them.
public struct ThemingAdvice: Sendable, Equatable, Identifiable {
    public enum Severity: String, Sendable, Equatable {
        /// The old colours will win until the user changes the config.
        case blocking
        /// The palette may still land, but this makes it unreliable.
        case warning
    }

    public var target: ThemingTarget
    public var severity: Severity
    /// `~`-shortened path, for display.
    public var file: String
    /// 1-based line, or nil when the whole file is the problem.
    public var line: Int?
    public var message: String
    public var suggestion: String

    public var id: String { "\(target.rawValue)|\(file)|\(line ?? 0)|\(message)" }

    public init(
        target: ThemingTarget,
        severity: Severity,
        file: String,
        line: Int? = nil,
        message: String,
        suggestion: String
    ) {
        self.target = target
        self.severity = severity
        self.file = file
        self.line = line
        self.message = message
        self.suggestion = suggestion
    }

    public static func scan(
        home: String = NSHomeDirectory(),
        enabledTargets: Set<ThemingTarget> = Set(ThemingTarget.allCases),
        managedPreferencesDirectory: String = "/Library/Managed Preferences/\(NSUserName())"
    ) -> [ThemingAdvice] {
        var rows: [ThemingAdvice] = []

        func enabled(_ target: ThemingTarget) -> Bool { enabledTargets.contains(target) }
        func display(_ path: String) -> String {
            guard path == home || path.hasPrefix(home + "/") else { return path }
            return "~" + path.dropFirst(home.count)
        }
        func add(
            _ target: ThemingTarget,
            _ severity: Severity,
            _ path: String,
            line: Int? = nil,
            message: String,
            suggestion: String
        ) {
            rows.append(
                ThemingAdvice(
                    target: target,
                    severity: severity,
                    file: display(path),
                    line: line,
                    message: message,
                    suggestion: suggestion
                )
            )
        }
        func unreadable(_ target: ThemingTarget, _ path: String) {
            add(
                target,
                .warning,
                path,
                message: "Palette cannot read this file, so it cannot check it for conflicts.",
                suggestion: "Check that the file is readable by your user."
            )
        }
        func read(_ path: String) -> FileContents {
            ThemingAdvice.read(path)
        }

        // MARK: nvim

        let nvimMessage = "Palette repaints on ColorScheme/VimEnter, but this sets colours after it; "
            + "remove it (or set `LazyVim` opts.colorscheme = false) if nvim keeps the old palette."

        if enabled(.nvim) {
            var luaFiles: [String] = []
            for folder in ["config", "plugins"] {
                let directory = home + "/.config/nvim/lua/" + folder
                guard FileManager.default.fileExists(atPath: directory) else { continue }
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                    unreadable(.nvim, directory)
                    continue
                }
                luaFiles += names.filter { $0.hasSuffix(".lua") }.sorted()
                    .map { directory + "/" + $0 }
            }
            for path in luaFiles {
                let contents = read(path)
                guard case .lines(let lines) = contents else {
                    if contents == .unreadable { unreadable(.nvim, path) }
                    continue
                }
                var depth = 0
                var installDepth: Int?
                for (index, raw) in lines.enumerated() {
                    let number = index + 1
                    let code = ThemingAdvice.stripping(raw, comment: "--")
                    let trimmed = code.trimmingCharacters(in: .whitespaces)
                    let opens = code.filter { $0 == "{" }.count
                    let closes = code.filter { $0 == "}" }.count
                    let lineOpensInstall = trimmed.contains("install")
                        && trimmed.contains("{")
                    let insideInstall = installDepth != nil
                        || (lineOpensInstall && offset(of: "install", in: trimmed) < offset(of: "colorscheme", in: trimmed))

                    if !trimmed.isEmpty {
                        if trimmed.contains("vim.cmd.colorscheme") {
                            add(
                                .nvim, .blocking, path, line: number,
                                message: nvimMessage,
                                suggestion: "Delete this call; Palette loads its colours after LazyVim."
                            )
                        } else if trimmed.contains("vim.o.background") {
                            add(
                                .nvim, .blocking, path, line: number,
                                message: nvimMessage,
                                suggestion: "Remove the background override; Palette sets it from the theme."
                            )
                        } else if trimmed.contains("nvim_set_hl"),
                                  let group = ["Normal", "NormalFloat", "Visual"].first(where: {
                                      trimmed.contains("\"\($0)\"") || trimmed.contains("'\($0)'")
                                  }) {
                            add(
                                .nvim, .blocking, path, line: number,
                                message: nvimMessage,
                                suggestion: "Remove the \(group) highlight override; Palette owns that group."
                            )
                        } else if ThemingAdvice.hasAssignment(trimmed, key: "colorscheme") {
                            add(
                                .nvim, insideInstall ? .warning : .blocking, path, line: number,
                                message: nvimMessage,
                                suggestion: insideInstall
                                    ? "LazyVim's install colorscheme is a fallback; remove it if nvim keeps the old palette."
                                    : "Remove the colorscheme assignment, or set LazyVim opts.colorscheme = false."
                            )
                        }
                    }

                    if lineOpensInstall, installDepth == nil { installDepth = depth + 1 }
                    depth += opens - closes
                    if let opened = installDepth, depth < opened { installDepth = nil }
                }
            }

            let neovide = home + "/.config/neovide/config.toml"
            let neovideContents = read(neovide)
            if case .lines(let lines) = neovideContents {
                for (index, raw) in lines.enumerated() {
                    let code = ThemingAdvice.stripping(raw, comment: "#")
                    let trimmed = code.trimmingCharacters(in: .whitespaces)
                    guard ThemingAdvice.hasAssignment(trimmed, key: "fork"),
                          ThemingAdvice.value(after: "fork", in: trimmed)?.lowercased() == "true" else {
                        continue
                    }
                    add(
                        .nvim, .warning, neovide, line: index + 1,
                        message: "Neovide runs detached (fork = true), so Palette cannot signal it; "
                            + "it keeps the old colours until restarted.",
                        suggestion: "Set fork = false, or restart Neovide after each palette change."
                    )
                }
            } else if neovideContents == .unreadable {
                unreadable(.nvim, neovide)
            }
        }

        // MARK: Starship

        if enabled(.starship) {
            let path = home + "/.config/starship.toml"
            switch read(path) {
            case .missing:
                break
            case .unreadable:
                unreadable(.starship, path)
            case .lines(let lines):
                var inTable = false
                for (index, raw) in lines.enumerated() {
                    let code = ThemingAdvice.stripping(raw, comment: "#")
                    let trimmed = code.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("[") { inTable = true }
                    guard !inTable, ThemingAdvice.hasAssignment(trimmed, key: "palette"),
                          let name = ThemingAdvice.value(after: "palette", in: trimmed),
                          !name.isEmpty, name != "palette" else { continue }
                    add(
                        .starship, .blocking, path, line: index + 1,
                        message: "Starship reads the \"\(name)\" palette, but Palette only rewrites "
                            + "the \"palette\" table in its generated copy.",
                        suggestion: "Set palette = \"palette\", or drop the line; Palette's copy then follows the theme."
                    )
                }
            }
        }

        // MARK: zellij

        if enabled(.zellij) {
            let path = home + "/.config/zellij/config.kdl"
            switch read(path) {
            case .missing:
                break
            case .unreadable:
                unreadable(.zellij, path)
            case .lines(let lines):
                var depth = 0
                var inBlock = false
                var themes: [(line: Int, managed: Bool)] = []
                for (index, raw) in lines.enumerated() {
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    if trimmed == "// >>> palette theme >>>" { inBlock = true; continue }
                    if trimmed == "// <<< palette theme <<<" { inBlock = false; continue }
                    let code = ThemingAdvice.stripping(raw, comment: "//")
                    let value = code.trimmingCharacters(in: .whitespaces)
                    if depth == 0, value.hasPrefix("theme"),
                       ThemingAdvice.isArgument(value, key: "theme") {
                        themes.append((index + 1, inBlock))
                    }
                    depth += code.filter { $0 == "{" }.count - code.filter { $0 == "}" }.count
                }
                for theme in themes where !theme.managed {
                    add(
                        .zellij, .blocking, path, line: theme.line,
                        message: "Duplicate theme key; keep only the managed one.",
                        suggestion: "Delete this theme line and keep the one inside Palette's marked block."
                    )
                }
                if themes.count > 1, themes.allSatisfy(\.managed) {
                    for theme in themes.dropFirst() {
                        add(
                            .zellij, .blocking, path, line: theme.line,
                            message: "Duplicate theme key; keep only the managed one.",
                            suggestion: "Delete the extra theme line inside Palette's marked block."
                        )
                    }
                }
            }
        }

        // MARK: kitty

        if enabled(.kitty) {
            let path = home + "/.config/kitty/kitty.conf"
            switch read(path) {
            case .missing:
                break
            case .unreadable:
                unreadable(.kitty, path)
            case .lines(let lines):
                var afterInclude = false
                for (index, raw) in lines.enumerated() {
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    if !afterInclude, trimmed.hasPrefix("include"),
                       trimmed.contains("palette/theme/kitty.conf") {
                        afterInclude = true
                        continue
                    }
                    guard afterInclude, !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                    let key = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
                    guard key == "background" || key == "foreground" || key == "cursor"
                        || ThemingAdvice.isAnsiColorKey(key) else { continue }
                    add(
                        .kitty, .blocking, path, line: index + 1,
                        message: "This \(key) line runs after Palette's include and overrides the palette.",
                        suggestion: "Move it above the include line, or remove it."
                    )
                }
            }
        }

        // MARK: ghostty

        if enabled(.ghostty) {
            let path = home + "/.config/ghostty/config"
            switch read(path) {
            case .missing:
                break
            case .unreadable:
                unreadable(.ghostty, path)
            case .lines(let lines):
                var afterInclude = false
                for (index, raw) in lines.enumerated() {
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    if !afterInclude, trimmed.hasPrefix("config-file"),
                       trimmed.contains("palette/theme/ghostty.conf") {
                        afterInclude = true
                        continue
                    }
                    guard afterInclude, !trimmed.hasPrefix("#"),
                          ThemingAdvice.hasAssignment(trimmed, key: "theme") else { continue }
                    add(
                        .ghostty, .blocking, path, line: index + 1,
                        message: "This theme line runs after Palette's include and overrides the palette.",
                        suggestion: "Move it above the config-file line, or remove it."
                    )
                }
            }
        }

        // MARK: fish

        if enabled(.fish) {
            var fishFiles = [home + "/.config/fish/config.fish"]
            let confDir = home + "/.config/fish/conf.d"
            if FileManager.default.fileExists(atPath: confDir) {
                if let names = try? FileManager.default.contentsOfDirectory(atPath: confDir) {
                    fishFiles += names.filter { $0.hasSuffix(".fish") }.sorted()
                        .map { confDir + "/" + $0 }
                } else {
                    unreadable(.fish, confDir)
                }
            }
            let expected = home + "/.config/palette/theme/starship-theme.toml"
            for path in fishFiles {
                let contents = read(path)
                guard case .lines(let lines) = contents else {
                    if contents == .unreadable { unreadable(.fish, path) }
                    continue
                }
                var inBlock = false
                for (index, raw) in lines.enumerated() {
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    if trimmed == "# >>> palette theme >>>" { inBlock = true; continue }
                    if trimmed == "# <<< palette theme <<<" { inBlock = false; continue }
                    guard !inBlock, !trimmed.hasPrefix("#"), trimmed.contains("STARSHIP_CONFIG"),
                          let value = ThemingAdvice.fishValue(trimmed, key: "STARSHIP_CONFIG") else { continue }
                    let expanded = ThemingAdvice.expanded(value, home: home)
                    guard expanded != expected else { continue }
                    add(
                        .fish, .blocking, path, line: index + 1,
                        message: "STARSHIP_CONFIG points at \(display(expanded)), so Starship never reads "
                            + "Palette's themed copy.",
                        suggestion: "Remove this assignment; Palette's managed block exports "
                            + "~/.config/palette/theme/starship-theme.toml."
                    )
                }
            }
        }

        // MARK: Helium

        if enabled(.helium), let browser = ChromiumBrowser.browser(for: .helium) {
            let own = managedPreferencesDirectory + "/\(browser.bundleID).plist"
            if !FileManager.default.fileExists(atPath: own) {
                add(
                    .helium, .blocking, own,
                    message: "Helium is enabled, but no Palette managed policy exists, so the palette "
                        + "never reaches it.",
                    suggestion: "Settings → Theming → Browsers → Enable silent browser theming."
                )
            }
            if FileManager.default.fileExists(atPath: managedPreferencesDirectory) {
                if let names = try? FileManager.default.contentsOfDirectory(
                    atPath: managedPreferencesDirectory
                ) {
                    for name in names.sorted() where name.hasSuffix(".plist") {
                        let path = managedPreferencesDirectory + "/" + name
                        guard path != own,
                              let data = FileManager.default.contents(atPath: path),
                              ChromiumPolicy.themeColor(in: data, bundleID: browser.bundleID) != nil else {
                            continue
                        }
                        add(
                            .helium, .blocking, path,
                            message: "Another managed preference also sets BrowserThemeColor for Helium; "
                                + "macOS merges both and the old value can win.",
                            suggestion: "Remove the old profile, or re-run Enable silent browser theming."
                        )
                    }
                } else {
                    unreadable(.helium, managedPreferencesDirectory)
                }
            }
        }

        return rows.filter { enabledTargets.contains($0.target) }
    }
}

// MARK: - Line helpers

extension ThemingAdvice {
    enum FileContents: Equatable {
        case missing
        case unreadable
        case lines([String])
    }

    static func read(_ path: String) -> FileContents {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return .unreadable }
        return .lines(text.components(separatedBy: "\n"))
    }

    /// Everything before the format's line comment, so a commented-out setting
    /// is not a setting. Forgiving by design: no string or block parsing.
    static func stripping(_ line: String, comment: String) -> String {
        guard let range = line.range(of: comment) else { return line }
        return String(line[..<range.lowerBound])
    }

    /// True when `key` is followed by `=` (ignoring spaces).
    static func hasAssignment(_ line: String, key: String) -> Bool {
        guard let range = line.range(of: key) else { return false }
        return line[range.upperBound...].first { $0 != " " && $0 != "\t" } == "="
    }

    /// The raw value after `key =`, comments and quotes removed.
    static func value(after key: String, in line: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let rest = line[range.upperBound...]
        guard let equals = rest.firstIndex(of: "=") else { return nil }
        var value = rest[rest.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// A key with an argument (`theme "palette"` or `theme = "palette"`).
    static func isArgument(_ line: String, key: String) -> Bool {
        guard let range = line.range(of: key) else { return false }
        let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.hasPrefix("\"") || rest.hasPrefix("=")
    }

    static func isAnsiColorKey(_ key: String) -> Bool {
        guard key.hasPrefix("color"), let slot = Int(key.dropFirst(5)) else { return false }
        return (0...255).contains(slot)
    }

    static func fishValue(_ line: String, key: String) -> String? {
        if let range = line.range(of: key + "=") {
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let position = tokens.firstIndex(of: Substring(key)),
              position + 1 < tokens.count else { return nil }
        let value = String(tokens[position + 1])
        return value.hasPrefix("-") ? nil : value
    }

    static func expanded(_ path: String, home: String) -> String {
        var value = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        value = value.replacingOccurrences(of: "$HOME", with: home)
        if value.hasPrefix("~/") { value = home + value.dropFirst(1) }
        return (value as NSString).standardizingPath
    }

    static func offset(of needle: String, in line: String) -> Int {
        guard let range = line.range(of: needle) else { return .max }
        return line.distance(from: line.startIndex, to: range.lowerBound)
    }
}

public extension ThemingTarget {
    /// SF Symbol for the Recommendations row. Advice has no icon of its own.
    var adviceIcon: String {
        switch self {
        case .kitty, .ghostty, .zellij: return "terminal"
        case .nvim: return "chevron.left.forwardslash.chevron.right"
        case .fish: return "fish"
        case .starship: return "sparkles"
        case .helium: return "globe"
        default: return "app.dashed"
        }
    }
}
