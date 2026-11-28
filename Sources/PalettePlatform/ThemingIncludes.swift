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
        /// True when this install first put kitty's `allow_remote_control` in
        /// the config, so the running kitty needs one restart to start its
        /// socket.
        public var addedRemoteControl: Bool = false
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

    /// btop reads a named theme from its own themes directory. Palette links it
    /// but never edits btop.conf: btop deletes a marker block on save.
    public var btopThemeLink: String {
        home + "/.config/btop/themes/palette.theme"
    }

    /// bat only sees a new theme after its cache is rebuilt. Public so the
    /// engine and its tests name the same command.
    public static let batCacheArguments = ["bat", "cache", "--build"]

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
            let lua = Plan(target: target, path: homeDir + "/.config/nvim/init.lua", format: .lua)
            let vim = Plan(target: target, path: homeDir + "/.config/nvim/init.vim", format: .vim)
            // A block Palette installed in init.vim must still be found after
            // the user creates an init.lua, or Remove/Revert would miss it.
            if hasMarker(lua) { return lua }
            if hasMarker(vim) { return vim }
            if !fileManager.fileExists(atPath: lua.path), fileManager.fileExists(atPath: vim.path) {
                return vim
            }
            return lua
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
            // so appending a second [mgr]/[status] block is invalid TOML.
            // The generated file stays available as a manual merge.
            return nil
        case .helium, .chrome, .edge, .brave, .vivaldi, .chromium, .arc, .vscode, .zed:
            return nil
        }
    }

    public func status(for target: ThemingTarget) -> Status {
        if target.isManual {
            if target == .btop {
                let link = btopThemeLink
                let linked = fileManager.fileExists(atPath: link)
                return Status(
                    available: true,
                    installed: linked,
                    path: link,
                    note: linked
                        ? "Manual — theme file linked; set color_theme = \"palette\" in btop.conf"
                        : "Manual — apply to link the theme file, then set color_theme = \"palette\" in btop.conf"
                )
            }
            return Status(
                available: false,
                installed: false,
                path: nil,
                note: "Manual — \(target.includeHint)"
            )
        }
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
        if target.isManual {
            do {
                try installAuxiliary(target)
                // An older build injected a block into btop.conf; btop deletes
                // markers when it saves, so strip any leftover on every apply.
                if let plan = plan(for: target) {
                    try removeLegacyBlock(plan)
                }
                return Outcome(target: target, path: nil, action: .unchanged, error: nil)
            } catch {
                return Outcome(target: target, path: nil, action: .failed, error: error.localizedDescription)
            }
        }
        guard let plan = plan(for: target) else {
            return Outcome(target: target, path: nil, action: .unchanged, error: nil)
        }
        if target == .starship, !fileManager.fileExists(atPath: resolve(plan.path)) {
            // No user config to update; the generated copy still works through
            // STARSHIP_CONFIG.
            return Outcome(target: target, path: plan.path, action: .unchanged, error: nil)
        }
        guard let body = blockBody(for: plan, palette: palette, metadata: metadata) else {
            return Outcome(target: target, path: plan.path, action: .failed, error: "No block body for \(target.title).")
        }
        let resolved = resolve(plan.path)
        let existing = (try? String(contentsOfFile: resolved, encoding: .utf8)) ?? ""
        let existed = fileManager.fileExists(atPath: resolved)
        let addedRemoteControl = target == .kitty && (
            !hasRemoteControlDirective(existing) || !hasManagedListenOn(existing)
        )
        do {
            try backupIfNeeded(plan, resolved: resolved, existed: existed)
            let updated = appendingBlock(to: removingBlock(from: existing, format: plan.format), format: plan.format, body: body)
            if updated != existing {
                try write(updated, to: resolved)
            }
            if target == .kitty {
                writeQuickAccessKitty(body)
            }
            try installAuxiliary(target)
            return Outcome(
                target: target,
                path: plan.path,
                action: updated == existing ? .unchanged : .installed,
                error: nil,
                addedRemoteControl: addedRemoteControl
            )
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
        if target == .kitty { removeQuickAccessKitty() }
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
            let hasBackup = fileManager.fileExists(atPath: backup.path)
            let hasCreated = fileManager.fileExists(atPath: created.path)
            guard hasBackup || hasCreated else { continue }
            do {
                let current = try? String(contentsOfFile: resolved, encoding: .utf8)
                if let current, current.contains(startMarker(plan.format)) {
                    // Strip only Palette's block: settings the user added after
                    // the first Apply stay. Same rule as `remove()`.
                    let updated = removingBlock(from: current, format: plan.format)
                    if hasCreated, updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Palette created the whole file and nothing else is in it.
                        try fileManager.removeItem(atPath: resolved)
                        outcomes.append(Outcome(target: target, path: plan.path, action: .removed, error: nil))
                    } else {
                        try write(updated, to: resolved)
                        outcomes.append(Outcome(target: target, path: plan.path, action: .restored, error: nil))
                    }
                } else if hasBackup {
                    // No block left to strip, so the snapshot is the only copy.
                    try fileManager.createDirectory(
                        at: URL(fileURLWithPath: resolved).deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if fileManager.fileExists(atPath: resolved) {
                        try fileManager.removeItem(atPath: resolved)
                    }
                    try fileManager.copyItem(at: backup, to: URL(fileURLWithPath: resolved))
                    outcomes.append(Outcome(target: target, path: plan.path, action: .restored, error: nil))
                } else {
                    // Palette created the file; keep whatever the user wrote.
                    if let current, current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        try fileManager.removeItem(atPath: resolved)
                    }
                    outcomes.append(Outcome(target: target, path: plan.path, action: .removed, error: nil))
                }
                try? fileManager.removeItem(at: backup)
                try? fileManager.removeItem(at: created)
            } catch {
                outcomes.append(Outcome(target: target, path: plan.path, action: .failed, error: error.localizedDescription))
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

    /// The quick-access panel is a separate kitty process with its own config,
    /// so it never sees kitty.conf's include or listener. Give it the same
    /// managed block, or the drop-down keeps the previous palette forever.
    private var quickAccessKittyPath: String? {
        let path = home + "/.config/kitty/quick-access-terminal.conf"
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    private func writeQuickAccessKitty(_ body: String) {
        guard let path = quickAccessKittyPath else { return }
        let resolved = resolve(path)
        let existing = (try? String(contentsOfFile: resolved, encoding: .utf8)) ?? ""
        let updated = appendingBlock(
            to: removingBlock(from: existing, format: .hash),
            format: .hash,
            body: body
        )
        if updated != existing { try? write(updated, to: resolved) }
    }

    private func removeQuickAccessKitty() {
        guard let path = quickAccessKittyPath else { return }
        let resolved = resolve(path)
        guard let existing = try? String(contentsOfFile: resolved, encoding: .utf8),
              existing.contains(startMarker(.hash)) else { return }
        let updated = removingBlock(from: existing, format: .hash)
        if updated != existing { try? write(updated, to: resolved) }
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
            // socket-only keeps remote control on the local unix socket and
            // off TCP. Palette's listen_on is intentionally after the user's
            // line: kitty keeps the last one, so the managed block overrides it
            // for live recolour, and removing the block restores the original.
            return [
                "allow_remote_control socket-only",
                "# Palette overrides listen_on so it can recolour this window live; unchecking restores your own line.",
                "listen_on unix:${TMPDIR}palette-kitty-{kitty_pid}",
                "include \(shortPath(themeFile(.kitty).path))",
            ].joined(separator: "\n")
        case .ghostty:
            return "config-file = \(themeFile(.ghostty).path)"
        case .zellij:
            guard let raw = ThemingRenderer.contents(for: .zellij, palette: palette, metadata: metadata) else {
                return nil
            }
            return stripHeader(raw)
                + "\ntheme \"palette\"\ntheme_dark \"palette\"\ntheme_light \"palette\""
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
            // The remapped copy is what fish exports through STARSHIP_CONFIG;
            // this block covers shells that inherited no environment (a zellij
            // server started before the setting existed) and would otherwise
            // keep a stale palette forever.
            return StarshipTheme.paletteBlock(palette)
        case .bat:
            return "--theme=palette"
        case .delta:
            return "[include]\n    path = \(themeFile(.delta).path)"
        case .btop:
            // Manual only: see `plan(for:)`. btop deletes a marker block the
            // next time it saves btop.conf.
            return nil
        case .yazi:
            // Manual only: see `plan(for:)`.
            return nil
        case .helium, .chrome, .edge, .brave, .vivaldi, .chromium, .arc, .vscode, .zed:
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

    /// A comment mentioning the directive is not a setting; only a real line
    /// counts, so the one-restart hint is not silently skipped.
    private func hasRemoteControlDirective(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { return false }
            return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first == "allow_remote_control"
        }
    }

    /// An install from the version that only wrote `allow_remote_control` has
    /// no managed listener yet, so its running kitty needs one restart too.
    private func hasManagedListenOn(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "listen_on unix:${TMPDIR}\(KittyRemoteControl.managedListenTemplate)"
        }
    }

    private func hasMarker(_ plan: Plan) -> Bool {
        guard let text = try? String(contentsOfFile: resolve(plan.path), encoding: .utf8) else { return false }
        return text.contains(startMarker(plan.format))
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

    /// Applies the same block removal an older Palette wrote, without touching
    /// anything else. Used when a target became manual.
    private func removeLegacyBlock(_ plan: Plan) throws {
        let resolved = resolve(plan.path)
        guard let existing = try? String(contentsOfFile: resolved, encoding: .utf8),
              existing.contains(startMarker(plan.format)) else { return }
        try write(removingBlock(from: existing, format: plan.format), to: resolved)
    }

    public func stripHeader(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        // Every comment marker the renderers use: `#` shell/conf, `//` KDL,
        // `--` Lua. A leftover header would otherwise land inside the inlined
        // block as app syntax.
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty
                || trimmed.hasPrefix("# ")
                || trimmed.hasPrefix("// ")
                || trimmed.hasPrefix("-- ") {
                lines.removeFirst()
            } else {
                break
            }
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
        try? fileManager.removeItem(at: themeDir.appendingPathComponent("starship.toml"))
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
            pair = (btopThemeLink, themeFile(.btop))
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
            pair = (btopThemeLink, themeFile(.btop))
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
