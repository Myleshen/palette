import Foundation
import PaletteCore

/// Installs the include line for each app inside a marked block in that app's
/// own config, and removes it again. The generated palette files stay under
/// `themeDir`; this type is the only code that touches an app's config.
public struct ThemingIncludes: Sendable {
    public enum Format: String, Sendable, Equatable {
        case hash
        case kdl
        case lua
        case vim

        /// `#` for conf/fish/TOML, KDL and Lua get their own comment tokens so
        /// the inserted block never makes the app's config invalid, and Vim
        /// uses a double quote.
        public var comment: String {
            switch self {
            case .hash: return "#"
            case .kdl: return "//"
            case .lua: return "--"
            case .vim: return "\""
            }
        }
    }

    public struct Plan: Sendable, Equatable {
        public var target: ThemingTarget
        public var path: String
        public var format: Format
    }

    public struct Outcome: Sendable, Equatable {
        public enum Action: String, Sendable, Equatable {
            case installed, removed, restored, unchanged, failed
        }
        public var target: ThemingTarget
        public var path: String?
        public var action: Action
        public var error: String?
    }

    public struct Status: Sendable, Equatable {
        public var available: Bool
        public var installed: Bool
        /// Absolute path, or the tilde form for display.
        public var path: String?
        public var note: String
    }

    public let home: String
    public let themeDir: URL
    private var fileManager: FileManager { .default }

    public init(home: String, themeDir: URL) {
        self.home = home
        self.themeDir = themeDir
    }

    public var previousDir: URL {
        themeDir.appendingPathComponent("previous", isDirectory: true)
    }

    /// The colour-remapped copy Starship is pointed at, and the fish snippet
    /// that exports STARSHIP_CONFIG. Both are generated files owned by Palette.
    public var starshipThemeURL: URL {
        themeDir.appendingPathComponent(StarshipTheme.fileName)
    }

    public var starshipSnippetURL: URL {
        themeDir.appendingPathComponent(StarshipTheme.snippetFileName)
    }

    // MARK: - Per-target mappings

    public func plan(for target: ThemingTarget) -> Plan? {
        let homeDir = home
        switch target {
        case .kitty:
            return Plan(target: target, path: homeDir + "/.config/kitty/kitty.conf", format: .hash)
        case .ghostty:
            return Plan(target: target, path: homeDir + "/.config/ghostty/config", format: .hash)
        case .zellij:
            return Plan(target: target, path: homeDir + "/.config/zellij/config.kdl", format: .kdl)
        case .nvim:
            let lua = homeDir + "/.config/nvim/init.lua"
            let vim = homeDir + "/.config/nvim/init.vim"
            if !fileManager.fileExists(atPath: lua), fileManager.fileExists(atPath: vim) {
                return Plan(target: target, path: vim, format: .vim)
            }
            return Plan(target: target, path: lua, format: .lua)
        case .fish:
            return Plan(target: target, path: homeDir + "/.config/fish/config.fish", format: .hash)
        case .starship:
            return Plan(target: target, path: homeDir + "/.config/starship.toml", format: .hash)
        case .bat:
            return Plan(target: target, path: homeDir + "/.config/bat/config", format: .hash)
        case .btop:
            return Plan(target: target, path: homeDir + "/.config/btop/btop.conf", format: .hash)
        case .delta:
            // `~/.gitconfig` wins because git reads it first; otherwise use the
            // XDG file and create it. Never both.
            let legacy = homeDir + "/.gitconfig"
            let xdg = homeDir + "/.config/git/config"
            let path = fileManager.fileExists(atPath: legacy) ? legacy : xdg
            return Plan(target: target, path: path, format: .hash)
        case .yazi:
            // Not auto-merged: yazi's theme.toml is a table-per-section file,
            // so appending a second [manager]/[status] block is invalid TOML.
            // The generated file stays available as a manual full replacement.
            return nil
        case .helium, .chrome, .edge, .brave, .vivaldi, .chromium, .arc, .vscode, .zed, .neovide:
            return nil
        }
    }

    public func status(for target: ThemingTarget) -> Status {
        // Starship has no include directive and Palette never edits its config,
        // so installed means "the themed copy exists". Whether fish exports
        // STARSHIP_CONFIG changes the note, not the file itself.
        if target == .starship, plan(for: target) != nil {
            let themed = fileManager.fileExists(atPath: starshipThemeURL.path)
            guard themed else {
                return Status(available: true, installed: false, path: starshipThemeURL.path, note: "Not installed")
            }
            let wired = fishExportsStarship
            return Status(
                available: true,
                installed: true,
                path: starshipThemeURL.path,
                note: wired
                    ? "Installed — fish sets STARSHIP_CONFIG"
                    : "Generated — export STARSHIP_CONFIG=\(shortPath(starshipThemeURL.path))"
            )
        }
        guard let plan = plan(for: target) else {
            let reason = target.unavailableReason ?? target.includeHint
            return Status(available: false, installed: false, path: nil, note: "Unavailable — \(reason)")
        }
        guard let text = try? String(contentsOfFile: plan.path, encoding: .utf8) else {
            return Status(available: true, installed: false, path: plan.path, note: "Not installed")
        }
        let installed = text.contains(startMarker(plan.format))
        return Status(
            available: true,
            installed: installed,
            path: plan.path,
            note: installed ? "Installed in \(shortPath(plan.path))" : "Not installed"
        )
    }

    public var hasBackups: Bool {
        ThemingTarget.allCases.contains { target in
            guard let plan = plan(for: target) else { return false }
            return fileManager.fileExists(atPath: backupURL(for: plan).path)
                || fileManager.fileExists(atPath: createdURL(for: plan).path)
        }
    }

    // MARK: - Install

    public func install(
        _ target: ThemingTarget,
        palette: PalettePalette,
        metadata: PaletteMetadata
    ) -> Outcome {
        guard let plan = plan(for: target) else {
            return Outcome(target: target, path: nil, action: .unchanged, error: nil)
        }
        if target == .starship {
            // The engine writes the colour-remapped copy; Palette never edits
            // the user's starship.toml, so there is no include to install.
            return Outcome(target: target, path: plan.path, action: .unchanged, error: nil)
        }
        guard let body = blockBody(for: plan, palette: palette, metadata: metadata) else {
            return Outcome(target: target, path: plan.path, action: .failed, error: "No block body for \(target.title).")
        }
        let resolved = resolve(plan.path)
        let existing = (try? String(contentsOfFile: resolved, encoding: .utf8)) ?? ""
        let existed = fileManager.fileExists(atPath: resolved)
        do {
            try backupIfNeeded(plan, resolved: resolved, existed: existed)
            let updated = appendingBlock(to: removingBlock(from: existing, format: plan.format), format: plan.format, body: body)
            if updated != existing {
                try write(updated, to: resolved)
            }
            try installAuxiliary(target)
            return Outcome(target: target, path: plan.path, action: updated == existing ? .unchanged : .installed, error: nil)
        } catch {
            return Outcome(target: target, path: plan.path, action: .failed, error: error.localizedDescription)
        }
    }

    // MARK: - Remove

    public func remove(_ target: ThemingTarget) -> Outcome {
        guard let plan = plan(for: target) else {
            return Outcome(target: target, path: nil, action: .unchanged, error: nil)
        }
        if target == .starship {
            return removeStarship(plan)
        }
        removeAuxiliary(target)
        let resolved = resolve(plan.path)
        guard let existing = try? String(contentsOfFile: resolved, encoding: .utf8),
              existing.contains(startMarker(plan.format)) else {
            return Outcome(target: target, path: plan.path, action: .unchanged, error: nil)
        }
        do {
            var updated = removingBlock(from: existing, format: plan.format)
            if target == .starship {
                updated = starshipRemoving(updated)
            }
            let created = fileManager.fileExists(atPath: createdURL(for: plan).path)
            if created, updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Palette created the whole file, so there is nothing left to keep.
                try fileManager.removeItem(atPath: resolved)
            } else {
                try write(updated, to: resolved)
            }
            try? fileManager.removeItem(at: backupURL(for: plan))
            try? fileManager.removeItem(at: createdURL(for: plan))
            return Outcome(target: target, path: plan.path, action: .removed, error: nil)
        } catch {
            return Outcome(target: target, path: plan.path, action: .failed, error: error.localizedDescription)
        }
    }

    @discardableResult
    public func removeAll() -> [Outcome] {
        ThemingTarget.allCases.compactMap { target in
            guard plan(for: target) != nil else { return nil }
            let outcome = remove(target)
            return outcome.action == .unchanged ? nil : outcome
        }
    }

    // MARK: - Revert

    @discardableResult
    public func revert() -> [Outcome] {
        var outcomes: [Outcome] = []
        for target in ThemingTarget.allCases {
            guard let plan = plan(for: target) else { continue }
            removeAuxiliary(target)
            let backup = backupURL(for: plan)
            let created = createdURL(for: plan)
            let resolved = resolve(plan.path)
            if fileManager.fileExists(atPath: backup.path) {
                do {
                    try fileManager.createDirectory(
                        at: URL(fileURLWithPath: resolved).deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if fileManager.fileExists(atPath: resolved) {
                        try fileManager.removeItem(atPath: resolved)
                    }
                    try fileManager.copyItem(at: backup, to: URL(fileURLWithPath: resolved))
                    try? fileManager.removeItem(at: backup)
                    try? fileManager.removeItem(at: created)
                    outcomes.append(Outcome(target: target, path: plan.path, action: .restored, error: nil))
                } catch {
                    outcomes.append(Outcome(target: target, path: plan.path, action: .failed, error: error.localizedDescription))
                }
            } else if fileManager.fileExists(atPath: created.path) {
                do {
                    if fileManager.fileExists(atPath: resolved) {
                        try fileManager.removeItem(atPath: resolved)
                    }
                    try? fileManager.removeItem(at: created)
                    outcomes.append(Outcome(target: target, path: plan.path, action: .removed, error: nil))
                } catch {
                    outcomes.append(Outcome(target: target, path: plan.path, action: .failed, error: error.localizedDescription))
                }
            }
        }
        return outcomes
    }

    // MARK: - Block text

    public func startMarker(_ format: Format) -> String {
        "\(format.comment) >>> palette theme >>>"
    }

    public func endMarker(_ format: Format) -> String {
        "\(format.comment) <<< palette theme <<<"
    }

    private func blockBody(
        for plan: Plan,
        palette: PalettePalette,
        metadata: PaletteMetadata
    ) -> String? {
        // Kitty documents `~` in its config, so it keeps the portable form.
        // Every other app gets the absolute path: Ghostty's `config-file`,
        // fish's `source` and git's `include.path` are not guaranteed to
        // expand `~` on every version.
        switch plan.target {
        case .kitty:
            return "include \(shortPath(themeFile(.kitty).path))"
        case .ghostty:
            return "config-file = \(themeFile(.ghostty).path)"
        case .zellij:
            guard let raw = ThemingRenderer.contents(for: .zellij, palette: palette, metadata: metadata) else {
                return nil
            }
            return stripHeader(raw) + "\ntheme \"palette\""
        case .nvim:
            let path = themeFile(.nvim).path
            return plan.format == .vim
                ? "source \(path)"
                : "dofile(\"\(path)\")"
        case .fish:
            // One block line: either the palette snippet, or the wrapper that
            // also exports STARSHIP_CONFIG for the themed copy.
            return fishBody()
        case .starship:
            // Never inlined: the engine writes the remapped copy and fish
            // exports STARSHIP_CONFIG. Kept out of the block path on purpose.
            return nil
        case .bat:
            return "--theme=palette"
        case .delta:
            return "[include]\n    path = \(themeFile(.delta).path)"
        case .btop:
            return "color_theme = \"palette\""
        case .yazi:
            // Manual only: see `plan(for:)`.
            return nil
        case .helium, .chrome, .edge, .brave, .vivaldi, .chromium, .arc, .vscode, .zed, .neovide:
            return nil
        }
    }

    private func themeFile(_ target: ThemingTarget) -> URL {
        themeDir.appendingPathComponent(target.fileName)
    }

    private func appendingBlock(to text: String, format: Format, body: String) -> String {
        let block = [
            startMarker(format),
            body,
            endMarker(format),
        ].joined(separator: "\n")
        if text.isEmpty {
            return block + "\n"
        }
        if text.hasSuffix("\n") {
            return text + block + "\n"
        }
        // shortcut: a config that did not end with a newline gains one, because
        // the block cannot be separated otherwise. Configs end with newlines.
        return text + "\n" + block + "\n"
    }

    private func removingBlock(from text: String, format: Format) -> String {
        let start = startMarker(format)
        let end = endMarker(format)
        var lines = text.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == start }),
              let finish = lines[begin...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == end })
        else { return text }
        lines.removeSubrange(begin...finish)
        return lines.joined(separator: "\n")
    }

    private func stripHeader(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        while let first = lines.first, first.isEmpty || first.hasPrefix("# ") {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Starship

    private func fishBody() -> String {
        if fileManager.fileExists(atPath: starshipSnippetURL.path) {
            return "source \(starshipSnippetURL.path)"
        }
        return "source \(themeFile(.fish).path)"
    }

    /// True when the fish config's managed block points at Palette's starship
    /// snippet, i.e. STARSHIP_CONFIG will be set in a new shell.
    private var fishExportsStarship: Bool {
        guard let plan = plan(for: .fish),
              let text = try? String(contentsOfFile: resolve(plan.path), encoding: .utf8),
              text.contains(startMarker(plan.format)) else { return false }
        return text.contains(starshipSnippetURL.path)
    }

    private func removeStarship(_ plan: Plan) -> Outcome {
        var changed = false
        for url in [starshipThemeURL, starshipSnippetURL] where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
            changed = true
        }
        let resolved = resolve(plan.path)
        if let existing = try? String(contentsOfFile: resolved, encoding: .utf8),
           existing.contains(startMarker(plan.format)) {
            // Legacy block from the version that inlined the palette table.
            var updated = removingBlock(from: existing, format: plan.format)
            updated = starshipRemoving(updated)
            let created = fileManager.fileExists(atPath: createdURL(for: plan).path)
            if created, updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? fileManager.removeItem(atPath: resolved)
            } else {
                try? write(updated, to: resolved)
            }
            changed = true
        }
        try? fileManager.removeItem(at: backupURL(for: plan))
        try? fileManager.removeItem(at: createdURL(for: plan))
        refreshFishBlock()
        return Outcome(
            target: .starship,
            path: plan.path,
            action: changed ? .removed : .unchanged,
            error: nil
        )
    }

    /// Keeps a one-line fish block pointing at the right file when the snippet
    /// disappears outside an Apply (direct remove, Disable).
    private func refreshFishBlock() {
        guard let plan = plan(for: .fish) else { return }
        let resolved = resolve(plan.path)
        guard let existing = try? String(contentsOfFile: resolved, encoding: .utf8),
              existing.contains(startMarker(plan.format)) else { return }
        let updated = appendingBlock(
            to: removingBlock(from: existing, format: plan.format),
            format: plan.format,
            body: fishBody()
        )
        if updated != existing { try? write(updated, to: resolved) }
    }

    private func starshipRemoving(_ text: String) -> String {
        // shortcut: the block is gone, so a root `palette = "palette"` would
        // point at nothing. Removing it also removes a user-set identical line,
        // which is the only value that can end up here.
        guard !text.contains("[palettes.palette]") else { return text }
        var lines = text.components(separatedBy: "\n")
        if let index = topLevelPaletteIndex(in: lines), paletteValue(lines[index]) == "\"palette\"" {
            lines.remove(at: index)
        }
        return lines.joined(separator: "\n")
    }

    private func topLevelPaletteIndex(in lines: [String]) -> Int? {
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil }
            if trimmed.hasPrefix("palette"), trimmed.dropFirst("palette".count)
                .trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                return index
            }
        }
        return nil
    }

    private func paletteValue(_ line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        return line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Auxiliary theme files

    /// bat and btop read a theme by name from their own themes directory, so
    /// the generated file is linked there. Remove/revert unlinks it.
    private func installAuxiliary(_ target: ThemingTarget) throws {
        let pair: (link: String, source: URL)?
        switch target {
        case .bat:
            pair = (home + "/.config/bat/themes/palette.tmTheme", themeFile(.bat))
        case .btop:
            pair = (home + "/.config/btop/themes/palette.theme", themeFile(.btop))
        default:
            pair = nil
        }
        guard let pair else { return }
        guard fileManager.fileExists(atPath: pair.source.path) else { return }
        let linkURL = URL(fileURLWithPath: pair.link)
        try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: pair.link) {
            if destination == pair.source.path { return }
            // Some other Palette-era link; replace it.
            try fileManager.removeItem(at: linkURL)
        } else if fileManager.fileExists(atPath: pair.link) {
            throw IncludeError(
                "\(shortPath(pair.link)) already exists and is not Palette's. Move it away and apply again."
            )
        }
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: pair.source)
    }

    private func removeAuxiliary(_ target: ThemingTarget) {
        if target == .starship {
            try? fileManager.removeItem(at: starshipThemeURL)
            try? fileManager.removeItem(at: starshipSnippetURL)
            return
        }
        let pair: (link: String, source: URL)?
        switch target {
        case .bat:
            pair = (home + "/.config/bat/themes/palette.tmTheme", themeFile(.bat))
        case .btop:
            pair = (home + "/.config/btop/themes/palette.theme", themeFile(.btop))
        default:
            pair = nil
        }
        guard let pair,
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: pair.link),
              destination == pair.source.path else { return }
        try? fileManager.removeItem(atPath: pair.link)
    }

    // MARK: - Files

    private func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func write(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mode = (try? fileManager.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
        try Data(text.utf8).write(to: url, options: .atomic)
        if let mode {
            try? fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
    }

    private func backupIfNeeded(_ plan: Plan, resolved: String, existed: Bool) throws {
        let backup = backupURL(for: plan)
        let created = createdURL(for: plan)
        if existed {
            guard !fileManager.fileExists(atPath: backup.path) else { return }
            try fileManager.createDirectory(at: previousDir, withIntermediateDirectories: true)
            try fileManager.copyItem(at: URL(fileURLWithPath: resolved), to: backup)
        } else {
            guard !fileManager.fileExists(atPath: backup.path),
                  !fileManager.fileExists(atPath: created.path) else { return }
            try fileManager.createDirectory(at: previousDir, withIntermediateDirectories: true)
            try Data().write(to: created)
        }
    }

    private func backupURL(for plan: Plan) -> URL {
        previousDir.appendingPathComponent("\(recordName(plan)).orig")
    }

    private func createdURL(for plan: Plan) -> URL {
        previousDir.appendingPathComponent("\(recordName(plan)).created")
    }

    private func recordName(_ plan: Plan) -> String {
        "\(plan.target.rawValue)-\((plan.path as NSString).lastPathComponent)"
    }

    /// `~` form so status text and includes stay portable across machines.
    public func shortPath(_ path: String) -> String {
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

private struct IncludeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
