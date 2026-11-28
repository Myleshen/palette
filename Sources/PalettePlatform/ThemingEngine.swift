import AppKit
import Combine
import Foundation
import PaletteCore

/// One palette in, a managed directory of app include files out. The app's
/// own config gets only a marked include block, installed and removed by
/// `ThemingIncludes`.
@MainActor
public final class ThemingEngine: ObservableObject {
    public struct TargetReport: Sendable, Equatable, Identifiable {
        public enum State: String, Sendable, Equatable {
            case written, skipped, failed
        }
        public var id: String
        public var title: String
        public var fileName: String
        public var includeHint: String
        public var note: String
        public var state: State
    }

    public struct ApplyResult: Sendable, Equatable {
        public var status: String
        public var source: String
        public var appearance: String
        public var written: [String]
        public var skipped: [String]
        public var includeLines: [String]
        public var notices: [String]
        public var changes: [String]
        public var targets: [TargetReport]
        public var error: String?

        public static let empty = ApplyResult(
            status: "",
            source: "",
            appearance: "",
            written: [],
            skipped: [],
            includeLines: [],
            notices: [],
            changes: [],
            targets: [],
            error: nil
        )

        public init(
            status: String,
            source: String,
            appearance: String,
            written: [String],
            skipped: [String],
            includeLines: [String],
            notices: [String],
            changes: [String],
            targets: [TargetReport],
            error: String? = nil
        ) {
            self.status = status
            self.source = source
            self.appearance = appearance
            self.written = written
            self.skipped = skipped
            self.includeLines = includeLines
            self.notices = notices
            self.changes = changes
            self.targets = targets
            self.error = error
        }
    }

    @Published public private(set) var status = "No palette applied yet."
    @Published public private(set) var lastResult: ApplyResult?
    @Published public private(set) var previewPalette: PalettePalette?
    @Published public private(set) var busy = false
    /// Last reload answer per target, so the Targets rows and the Apply result
    /// say what the app actually did rather than guessing.
    @Published public private(set) var reloadStatuses: [String: ThemingReload.Status] = [:]
    /// Apps that need a restart to show the palette. Nil when nothing is left
    /// or the user dismissed it.
    @Published public private(set) var restartPrompt: RestartPrompt?

    /// Called on the main actor after an Apply wrote the palette, so Palette's
    /// own theme can follow the same colours without a second engine pass.
    public var onAppliedPalette: ((PalettePalette, PaletteMetadata) -> Void)?

    public let themeDir: URL
    public let previousDir: URL
    public let themesDirectory: URL
    public let includes: ThemingIncludes

    private let fileManager = FileManager.default
    private let kitty: KittyRemoteControl
    private let appRestart: AppRestart
    /// Tests generate files in a sandbox HOME; asking the user's kitty to
    /// reload colours from that sandbox would paint the live terminal.
    private let reloadsEnabled: Bool
    /// Injected by tests so a sandbox image stands in for the desktop picture.
    private let wallpaperOverride: [URL]?
    /// Injected by tests; the real one asks System Events to switch macOS.
    private let setSystemAppearance: @Sendable (Bool) async -> Bool

    public init(
        paths: PalettePaths,
        themesDirectory: URL,
        kitty: KittyRemoteControl = KittyRemoteControl(),
        appRestart: AppRestart = .live,
        reloadsEnabled: Bool = true,
        wallpaperOverride: [URL]? = nil,
        setSystemAppearance: @escaping @Sendable (Bool) async -> Bool = { _ in false }
    ) {
        self.themeDir = paths.themeDir
        self.previousDir = paths.themeDir.appendingPathComponent("previous", isDirectory: true)
        self.themesDirectory = themesDirectory
        self.kitty = kitty
        self.appRestart = appRestart
        self.reloadsEnabled = reloadsEnabled
        self.wallpaperOverride = wallpaperOverride
        self.setSystemAppearance = setSystemAppearance
        self.includes = ThemingIncludes(home: paths.home, themeDir: paths.themeDir)
    }

    public var hasPrevious: Bool {
        managedFileNames.contains { fileManager.fileExists(atPath: previousDir.appendingPathComponent($0).path) }
            || includes.hasBackups
    }

    /// Status for the Targets list. Reads the app config, so it is current
    /// even when the user edits the include by hand.
    public func includeStatus(for target: ThemingTarget) -> ThemingIncludes.Status {
        includes.status(for: target)
    }

    /// The master switch going off removes every marked block, leaving each
    /// app's own config otherwise untouched.
    public func removeAllIncludes() -> [ThemingIncludes.Outcome] {
        includes.removeAll()
    }

    /// 2.20.1 removed Chromium browser theming. Delete the generated profiles and
    /// the managed plists those builds wrote so the theme directory and
    /// /Library/Managed Preferences hold only what Palette still manages.
    public static func removeLegacyBrowserThemeFiles(
        themeDir: URL,
        managedPreferences: String = "/Library/Managed Preferences/\(NSUserName())"
    ) -> [String] {
        let bundleIDs = [
            "net.imput.helium", "com.google.Chrome", "com.microsoft.edgemac",
            "com.brave.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
            "company.thebrowser.Browser",
        ]
        var removed: [String] = []
        for directory in [themeDir, themeDir.appendingPathComponent("previous", isDirectory: true)] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasSuffix("-theme.mobileconfig") || name.hasPrefix("chromium") {
                let path = directory.appendingPathComponent(name)
                if (try? FileManager.default.removeItem(at: path)) != nil { removed.append(path.path) }
            }
        }
        for bundleID in bundleIDs {
            let path = managedPreferences + "/" + bundleID + ".plist"
            if FileManager.default.fileExists(atPath: path),
               (try? FileManager.default.removeItem(atPath: path)) != nil {
                removed.append(path)
            }
        }
        return removed
    }

    public static func shouldAutoApply(_ config: ThemingConfig, wallpaperChanged: Bool = true) -> Bool {
        config.enabled && config.source == .wallpaper && config.followWallpaper && wallpaperChanged
    }

    /// `auto` reads the user's real config; `on` and `off` override it.
    static func transparency(for config: ThemingConfig, home: String) -> TransparencyDetection.Result {
        switch config.transparent {
        case .on: return TransparencyDetection.Result(isTransparent: true, reason: "transparent = on")
        case .off: return TransparencyDetection.Result(isTransparent: false)
        case .auto: return TransparencyDetection.detect(home: home)
        }
    }

    public static func managedFileNames(targets: [String] = ThemingTarget.allCases.map(\.rawValue)) -> [String] {
        let selected = Set(targets)
        var names = ThemingTarget.allCases
            .filter { selected.contains($0.rawValue) && $0 != .starship }
            .map(\.fileName)
        if selected.contains(ThemingTarget.starship.rawValue) {
            names += [StarshipTheme.fileName, StarshipTheme.snippetFileName]
        }
        return names
    }

    /// A wallpaper card may change the desktop picture regardless; this says
    /// whether the palette run is allowed too: cross-app theming on **and**
    /// sampling the wallpaper. With `source = "theme"` a card changes only the
    /// picture, so the theme the user picked stays in charge.
    public static func shouldApplyWallpaperCard(_ config: ThemingConfig) -> Bool {
        config.enabled && config.source == .wallpaper
    }

    /// A desktop picture can point at a file that was moved or deleted. Name
    /// that path instead of asking the user to "set a desktop picture" they
    /// already set.
    public static func missingWallpaperMessage(path: String?) -> String {
        guard let path, !path.isEmpty else {
            return "No desktop picture found — choose one."
        }
        return "Desktop picture \(path) is missing — choose a new one."
    }

    private var managedFileNames: [String] {
        Self.managedFileNames() + [ThemingRenderer.paletteJSONName] + ThemingRenderer.standardExportNames
    }

    private func disabledResult() -> ApplyResult {
        let removed = includes.removeAll()
        reloadStatuses.removeAll()
        restartPrompt = nil
        var message = "Cross-app theming is off. Palette's own theme still comes from Theming."
        if !removed.isEmpty {
            message += " Removed \(removed.count) managed include\(removed.count == 1 ? "" : "s")."
        }
        status = message
        let result = ApplyResult(
            status: message, source: "", appearance: "",
            written: [], skipped: [], includeLines: [], notices: [], changes: [], targets: [], error: nil
        )
        lastResult = result
        return result
    }

    // MARK: - Apply

    public func apply(_ config: ThemingConfig, fallbackThemeName: String = "default-dark") async -> ApplyResult {
        let value = config.normalized()
        guard value.enabled else { return disabledResult() }
        switch value.source {
        case .wallpaper:
            return await applyWallpaper(value)
        case .theme:
            let name = value.theme.isEmpty ? fallbackThemeName : value.theme
            return await applyTheme(named: name, config: value)
        }
    }

    public func applyTheme(named name: String, config: ThemingConfig) async -> ApplyResult {
        guard config.enabled else { return disabledResult() }
        busy = true
        defer { busy = false }
        var value = config.normalized()
        value.source = .theme
        // Never trust the caller's spelling: display names resolve to the file
        // id. A name that does not resolve is an error, not a silent fallback:
        // writing Default Dark would report success for a theme that is gone.
        guard let id = ThemeLoader.themeID(for: name, themesDirectory: themesDirectory) else {
            let message = name.isEmpty
                ? "No theme name was given; nothing was applied."
                : "Theme '\(name)' was not found; nothing was applied."
            Log.shared.warn(message, source: "theming")
            status = message
            let result = ApplyResult(
                status: message, source: "theme", appearance: "",
                written: [], skipped: [], includeLines: [], notices: [message],
                changes: [], targets: [], error: message
            )
            lastResult = result
            return result
        }
        value.theme = id
        let fallback = Theme.defaultDark
        let loaded = ThemeLoader.load(name: id, themesDirectory: themesDirectory, fallback: fallback)
        let palette = PalettePalette(theme: loaded.theme)
        let transparency = Self.transparency(for: value, home: includes.home)
        let metadata = PaletteMetadata(
            source: "theme",
            theme: loaded.theme.name,
            appearance: palette.appearance,
            themeID: id,
            targets: value.targets,
            transparentBackgrounds: transparency.isTransparent
        )
        Log.shared.info(
            "Applying '\(loaded.theme.name)' (\(id)) · bg \(palette.background) fg \(palette.foreground)",
            source: "theming"
        )
        return await finish(palette: palette, metadata: metadata, config: value, transparency: transparency)
    }

    public func applyWallpaper(_ config: ThemingConfig) async -> ApplyResult {
        busy = true
        defer { busy = false }
        var value = config.normalized()
        value.source = .wallpaper
        guard let palette = await extractWallpaperPalette(
            appearance: value.darkMode,
            saturation: value.saturation,
            contrast: value.contrast
        ) else {
            let message = Self.missingWallpaperMessage(
                path: wallpaperURLs.first.map { includes.shortPath($0.path) }
            )
            status = message
            let result = ApplyResult(
                status: message, source: "wallpaper",
                appearance: PalettePalette.appearance(darkMode: value.darkMode),
                written: [], skipped: [], includeLines: [], notices: [], changes: [], targets: [], error: message
            )
            lastResult = result
            return result
        }
        let transparency = Self.transparency(for: value, home: includes.home)
        let metadata = PaletteMetadata(
            source: "wallpaper",
            theme: "Wallpaper",
            appearance: palette.appearance,
            targets: value.targets,
            transparentBackgrounds: transparency.isTransparent
        )
        // Pywal parity: the picture owns Palette's colours even when nothing is
        // generated for other apps. Only the files are gated on the switch.
        guard value.enabled else {
            let message = "Palette follows the desktop picture. Cross-app theming is off."
            status = message
            let result = ApplyResult(
                status: message, source: "wallpaper", appearance: palette.appearance,
                written: [], skipped: [], includeLines: [], notices: [], changes: [], targets: [], error: nil
            )
            lastResult = result
            onAppliedPalette?(palette, metadata)
            return result
        }
        return await finish(palette: palette, metadata: metadata, config: value, transparency: transparency)
    }

    /// Extracts without writing, so the Settings pane can show the swatches
    /// before the user commits.
    public func previewWallpaper(config: ThemingConfig) async -> PalettePalette? {
        let value = config.normalized()
        let palette = await extractWallpaperPalette(
            appearance: value.darkMode,
            saturation: value.saturation,
            contrast: value.contrast
        )
        previewPalette = palette
        return palette
    }

    public var wallpaperURLs: [URL] {
        if let wallpaperURLOverride { return [wallpaperURLOverride] }
        if let wallpaperOverride { return wallpaperOverride }
        var seen = Set<String>()
        return NSScreen.screens.compactMap { screen in
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    /// Test-only picture, so a wallpaper apply can sample a fixture instead of
    /// whatever is on the user's desktop.
    public var wallpaperURLOverride: URL?

    // MARK: - Revert

    public func revert() async -> ApplyResult {
        busy = true
        defer { busy = false }
        guard hasPrevious else {
            let message = "Nothing to revert to yet."
            status = message
            return ApplyResult(
                status: message, source: "", appearance: "",
                written: [], skipped: [], includeLines: [], notices: [], changes: [], targets: [], error: message
            )
        }
        do {
            // Generated files first: include backups are only touched once the
            // swap succeeded, so a failed swap leaves every app config intact
            // and Revert retryable.
            let restored = try swapWithPrevious()
            let includeOutcomes = includes.revert()
            reloadStatuses.removeAll()
            restartPrompt = nil
            let failures = includeOutcomes.filter { $0.action == .failed }
            let includeCount = includeOutcomes.filter { $0.action != .failed }.count
            var message: String
            if restored.isEmpty {
                message = includeCount > 0
                    ? "Restored \(includeCount) app config\(includeCount == 1 ? "" : "s"); there was no previous palette set."
                    : "No previous palette set was stored."
            } else {
                message = "Restored the previous palette set (\(restored.count) file\(restored.count == 1 ? "" : "s"))"
                if includeCount > 0 {
                    message += " and \(includeCount) app config\(includeCount == 1 ? "" : "s")"
                }
                message += "."
            }
            status = message
            let result = ApplyResult(
                status: message,
                source: "previous",
                appearance: "",
                written: restored,
                skipped: [],
                includeLines: [],
                notices: [],
                changes: includeOutcomes.compactMap { outcome in
                    guard let path = outcome.path else { return nil }
                    switch outcome.action {
                    case .restored: return "Restored \(includes.shortPath(path))"
                    case .removed: return "Removed \(includes.shortPath(path))"
                    case .failed: return "Could not restore \(includes.shortPath(path)): \(outcome.error ?? "unknown error")"
                    case .installed, .unchanged: return nil
                    }
                },
                targets: [],
                error: failures.isEmpty ? nil : "Some app configs could not be restored."
            )
            lastResult = result

            return result
        } catch {
            let message = "Could not revert palette files: \(error.localizedDescription) App configs were left unchanged, so Revert can be tried again."
            status = message
            return ApplyResult(
                status: message, source: "", appearance: "",
                written: [], skipped: [], includeLines: [], notices: [], changes: [], targets: [], error: message
            )
        }
    }

    // MARK: - Writing

    private func finish(
        palette: PalettePalette,
        metadata: PaletteMetadata,
        config: ThemingConfig,
        transparency: TransparencyDetection.Result
    ) async -> ApplyResult {
        do {
            let outcome = try await write(palette: palette, metadata: metadata, targets: config.targets)
            let succeeded = outcome.failed.isEmpty
            let reloads = succeeded
                ? await reloadAll(config.targets, kittyRemoteControlAdded: outcome.kittyRemoteControlAdded)
                : [:]
            var summary: String
            if succeeded {
                summary = "Applied \(outcome.written.count) file\(outcome.written.count == 1 ? "" : "s") to \(themeDir.path)."
            } else {
                summary = "Applied \(outcome.written.count) file\(outcome.written.count == 1 ? "" : "s"); \(outcome.failed.count) failed."
            }
            let reloadMessages = config.targets.compactMap { reloads[$0]?.message }
            if !reloadMessages.isEmpty {
                summary += " · " + reloadMessages.joined(separator: " · ")
            }
            var notes: [String] = []
            if !metadata.themeID.isEmpty {
                summary += " · \(metadata.theme) (\(metadata.themeID))"
                notes.append("Palette source: \(metadata.theme) [\(metadata.themeID)]")
            }
            if metadata.transparentBackgrounds, config.targets.contains(ThemingTarget.nvim.rawValue) {
                notes.append("nvim: transparent background (\(transparency.reason))")
            }
            if succeeded, config.systemAppearance == .auto {
                let dark = palette.appearance != "light"
                let switched = await setSystemAppearance(dark)
                Log.shared.info(
                    "System appearance: asked for \(dark ? "dark" : "light") — \(switched ? "switched" : "refused")",
                    source: "theming"
                )
                if switched {
                    notes.append("macOS appearance: \(dark ? "dark" : "light")")
                } else {
                    let message = "macOS appearance unchanged: allow Palette to control System Events in Automation, or set system_appearance = \"off\"."
                    notes.append(message)
                    summary += " · \(message)"
                }
            }
            notes += outcome.notices
            // One line, not a second card: the Recommendations card has the
            // file and the fix, the status only has to point at it.
            let conflicts = ThemingAdvice.scan(
                home: includes.home,
                enabledTargets: Set(config.targets.compactMap(ThemingTarget.init(rawValue:)))
            ).filter { $0.severity == .blocking }.count
            if conflicts > 0 {
                summary += " · \(conflicts) config conflict\(conflicts == 1 ? "" : "s")"
                    + " — see Theming → Recommendations"
            }
            let reports = outcome.reports.map { report -> TargetReport in
                var report = report
                if let reload = reloads[report.id] { report.note = reload.message }
                if report.id == ThemingTarget.starship.rawValue,
                   !config.targets.contains(ThemingTarget.fish.rawValue) {
                    report.note = "Set STARSHIP_CONFIG=\(includes.shortPath(includes.starshipThemeURL.path)) in your shell, or enable fish."
                }
                return report
            }
            let result = ApplyResult(
                status: summary,
                source: metadata.source,
                appearance: palette.appearance,
                written: outcome.written,
                skipped: outcome.skipped,
                includeLines: config.targets.compactMap { raw -> String? in
                    guard let target = ThemingTarget(rawValue: raw), target.isImplemented else { return nil }
                    return target.includeHint
                },
                notices: notes,
                changes: outcome.changed,
                targets: reports,
                error: succeeded ? nil : "Some files could not be written."
            )
            restartPrompt = succeeded
                ? await restartApps(for: config.targets, reloads: reloads)
                : nil
            status = summary
            lastResult = result
            onAppliedPalette?(palette, metadata)

            return result
        } catch {
            let message = "Could not write palette files: \(error.localizedDescription)"
            status = message
            restartPrompt = nil
            Log.shared.warn(message, source: "theming")
            let result = ApplyResult(
                status: message, source: metadata.source, appearance: palette.appearance,
                written: [], skipped: [], includeLines: [], notices: [], changes: [], targets: [], error: message
            )
            lastResult = result
            return result
        }
    }

    private struct WriteOutcome {
        var written: [String]
        var skipped: [String]
        var failed: [String]
        var changed: [String]
        var notices: [String]
        var reports: [TargetReport]
        /// This Apply first added kitty's remote-control directive; the running
        /// kitty only starts listening after one restart.
        var kittyRemoteControlAdded: Bool
    }

    private func write(
        palette: PalettePalette,
        metadata: PaletteMetadata,
        targets: [String]
    ) async throws -> WriteOutcome {
        try fileManager.createDirectory(at: themeDir, withIntermediateDirectories: true)
        // An identical re-apply must not replace the snapshot with the same
        // set, or Revert would restore what is already on screen.
        if !generatedSetMatchesDisk(
            renderedGeneratedFiles(palette: palette, metadata: metadata, targets: targets)
        ) {
            snapshotCurrentSet()
        }

        let selected = targets.compactMap(ThemingTarget.init(rawValue:))
        let selectedIDs = Set(selected.map(\.rawValue))

        // The pre-2.20 build wrote an unused `starship.toml` palette table next
        // to the real remapped copy. Remove it on every apply.
        try? fileManager.removeItem(at: themeDir.appendingPathComponent("starship.toml"))

        // Starship's files are written before the per-target loop so the fish
        // block can point at the snippet it just created (one block line).
        var starshipNotice: String?
        var starshipFailure: String?
        if selectedIDs.contains(ThemingTarget.starship.rawValue) {
            do {
                starshipNotice = try writeStarshipTheme(palette: palette, metadata: metadata)
            } catch {
                starshipFailure = error.localizedDescription
                Log.shared.warn("Could not write the Starship theme: \(error.localizedDescription)", source: "theming")
            }
        } else {
            try? fileManager.removeItem(at: includes.starshipThemeURL)
            try? fileManager.removeItem(at: includes.starshipSnippetURL)
        }

        var written: [String] = []
        var skipped: [String] = []
        var failed: [String] = []
        var changes: [String] = []
        var notices: [String] = []
        var kittyRemoteControlAdded = false
        var reports: [TargetReport] = []

        for target in ThemingTarget.allCases {
            let selected = selectedIDs.contains(target.rawValue)
            guard selected else {
                // A target turned off must stop affecting the app, so its
                // generated file and its managed include both go away.
                if target.isImplemented {
                    try? fileManager.removeItem(at: themeDir.appendingPathComponent(target.fileName))
                }
                _ = includes.remove(target)
                continue
            }
            if target == .starship, let starshipFailure {
                failed.append(target.fileName)
                reports.append(TargetReport(
                    id: target.rawValue,
                    title: target.title,
                    fileName: target.fileName,
                    includeHint: target.includeHint,
                    note: starshipFailure,
                    state: .failed
                ))
                continue
            }
            if target == .starship {
                // Both files were written above; there is no include line and
                // the user's own starship.toml is never edited.
                written += [StarshipTheme.fileName, StarshipTheme.snippetFileName]
                changes.append("Starship theme: \(includes.shortPath(includes.starshipThemeURL.path))")
                if let starshipNotice { notices.append("Starship: \(starshipNotice)") }
                if !selectedIDs.contains(ThemingTarget.fish.rawValue) {
                    notices.append(
                        "Starship: export STARSHIP_CONFIG=\(includes.shortPath(includes.starshipThemeURL.path)) in your shell, or enable fish to have Palette set it."
                    )
                }
                reports.append(TargetReport(
                    id: target.rawValue,
                    title: target.title,
                    fileName: target.fileName,
                    includeHint: target.includeHint,
                    note: ThemingReload.status(for: target).message,
                    state: .written
                ))
                continue
            }
            guard target.isImplemented,
                  let contents = ThemingRenderer.contents(for: target, palette: palette, metadata: metadata) else {
                skipped.append(target.fileName)
                reports.append(TargetReport(
                    id: target.rawValue,
                    title: target.title,
                    fileName: target.fileName,
                    includeHint: target.includeHint,
                    note: target.unavailableReason ?? "Not configured yet.",
                    state: .skipped
                ))
                continue
            }
            do {
                try Data(contents.utf8).write(
                    to: themeDir.appendingPathComponent(target.fileName),
                    options: .atomic
                )
                written.append(target.fileName)
                let include = includes.install(target, palette: palette, metadata: metadata)
                if let error = include.error {
                    failed.append(target.fileName)
                    Log.shared.warn(
                        "Could not install the \(target.title) include: \(error)",
                        source: "theming"
                    )
                    reports.append(TargetReport(
                        id: target.rawValue,
                        title: target.title,
                        fileName: target.fileName,
                        includeHint: target.includeHint,
                        note: "Wrote \(target.fileName) but could not update \(target.title)'s config: \(error)",
                        state: .failed
                    ))
                } else {
                    if include.addedRemoteControl { kittyRemoteControlAdded = true }
                    if let path = include.path, target != .starship {
                        changes.append("\(target.title) include: \(includes.shortPath(path))")
                    }
                    if target == .bat, let failure = await rebuildBatCache() {
                        let message = "bat cache --build failed: \(failure). Run it yourself after fixing bat."
                        notices.append(message)
                        Log.shared.warn(message, source: "theming")
                    }
                    reports.append(TargetReport(
                        id: target.rawValue,
                        title: target.title,
                        fileName: target.fileName,
                        includeHint: target.includeHint,
                        note: ThemingReload.status(for: target).message,
                        state: .written
                    ))
                }
            } catch {
                failed.append(target.fileName)
                Log.shared.warn("Could not write \(target.fileName): \(error.localizedDescription)", source: "theming")
                reports.append(TargetReport(
                    id: target.rawValue,
                    title: target.title,
                    fileName: target.fileName,
                    includeHint: target.includeHint,
                    note: error.localizedDescription,
                    state: .failed
                ))
            }
        }

        let json = ThemingRenderer.paletteJSON(palette: palette, metadata: metadata)
        try Data(json.utf8).write(
            to: themeDir.appendingPathComponent(ThemingRenderer.paletteJSONName),
            options: .atomic
        )
        written.append(ThemingRenderer.paletteJSONName)

        // The standard shapes are not targets: they are always written, on
        // every apply, so another tool reads one file instead of an adapter.
        for (name, contents) in ThemingRenderer.standardExports(palette: palette, metadata: metadata) {
            try Data(contents.utf8).write(
                to: themeDir.appendingPathComponent(name),
                options: .atomic
            )
            written.append(name)
        }

        if selectedIDs.contains(ThemingTarget.zellij.rawValue),
           reloadsEnabled,
           let zellij = ToolLocator.shared.path(for: "zellij") {
            let appearance = palette.appearance
            let switched = await ZellijThemeReload.reload(binary: zellij, appearance: appearance)
            if switched > 0 {
                notices.append("Zellij: switched the theme in \(switched) running session(s).")
            }
        }
        return WriteOutcome(
            written: written,
            skipped: skipped,
            failed: failed,
            changed: changes,
            notices: notices,
            reports: reports,
            kittyRemoteControlAdded: kittyRemoteControlAdded
        )
    }

    /// bat only sees a linked theme after its cache is rebuilt. The run is
    /// awaited (off the main thread inside ProcessRunner) so a failure can be
    /// reported; it returns nil on a clean build.
    private func rebuildBatCache() async -> String? {
        // Sandboxed test homes must not rewrite the real user's bat cache.
        guard reloadsEnabled else { return nil }
        do {
            let result = try await ProcessRunner.run(ThemingIncludes.batCacheArguments, timeout: 60)
            guard result.status != 0 else { return nil }
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "exit \(result.status)" : message
        } catch {
            return error.localizedDescription
        }
    }

    /// Writes the colour-remapped Starship config and the fish snippet that
    /// exports STARSHIP_CONFIG. The user's own starship.toml is only read.
    private func writeStarshipTheme(palette: PalettePalette, metadata: PaletteMetadata) throws -> String? {
        let userPath = includes.plan(for: .starship)?.path
        let userConfig = userPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let rendered = StarshipTheme.render(userConfig: userConfig, palette: palette, header: metadata.header)
        try Data(rendered.text.utf8).write(to: includes.starshipThemeURL, options: .atomic)
        let fishPath = themeDir.appendingPathComponent(ThemingTarget.fish.fileName).path
        let snippet = StarshipTheme.fishSnippet(
            themePath: includes.starshipThemeURL.path,
            fishPath: fishPath,
            header: metadata.header
        )
        try Data(snippet.utf8).write(to: includes.starshipSnippetURL, options: .atomic)
        return rendered.notice
    }

    /// The exact bytes the next Apply will leave in every managed file, so a
    /// no-op apply can be detected before the snapshot is replaced.
    private func renderedGeneratedFiles(
        palette: PalettePalette,
        metadata: PaletteMetadata,
        targets: [String]
    ) -> [String: String] {
        let selected = Set(targets)
        var files: [String: String] = [:]
        for target in ThemingTarget.allCases where selected.contains(target.rawValue) {
            if target == .starship {
                let userPath = includes.plan(for: .starship)?.path
                let userConfig = userPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
                let rendered = StarshipTheme.render(
                    userConfig: userConfig,
                    palette: palette,
                    header: metadata.header
                )
                files[StarshipTheme.fileName] = rendered.text
                files[StarshipTheme.snippetFileName] = StarshipTheme.fishSnippet(
                    themePath: includes.starshipThemeURL.path,
                    fishPath: themeDir.appendingPathComponent(ThemingTarget.fish.fileName).path,
                    header: metadata.header
                )
                continue
            }
            if let contents = ThemingRenderer.contents(for: target, palette: palette, metadata: metadata) {
                files[target.fileName] = contents
            }
        }
        files[ThemingRenderer.paletteJSONName] = ThemingRenderer.paletteJSON(palette: palette, metadata: metadata)
        for (name, contents) in ThemingRenderer.standardExports(palette: palette, metadata: metadata) {
            files[name] = contents
        }
        return files
    }

    private func generatedSetMatchesDisk(_ rendered: [String: String]) -> Bool {
        for name in managedFileNames {
            let path = themeDir.appendingPathComponent(name).path
            if let text = rendered[name] {
                guard let current = try? String(contentsOfFile: path, encoding: .utf8),
                      withoutStamp(current) == withoutStamp(text) else {
                    return false
                }
            } else if fileManager.fileExists(atPath: path) {
                return false
            }
        }
        return true
    }

    /// A generated header carries the apply's timestamp, so two applies of the
    /// same palette differ only there. Strip it before comparing.
    private func withoutStamp(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#,
            with: "",
            options: .regularExpression
        )
    }

    /// The previous generated set is a plain directory copy. App configs are
    /// never in it because Palette never writes them.
    private func snapshotCurrentSet() {
        let current = managedFileNames.filter {
            fileManager.fileExists(atPath: themeDir.appendingPathComponent($0).path)
        }
        guard !current.isEmpty else { return }
        do {
            try fileManager.createDirectory(at: previousDir, withIntermediateDirectories: true)
            // Only the generated palette files are swapped. Include backups
            // (`.orig` / `.created`) live in the same directory and must survive
            // every apply, or Revert would restore an already-themed file.
            for name in managedFileNames {
                try? fileManager.removeItem(at: previousDir.appendingPathComponent(name))
            }
            for name in current {
                try fileManager.copyItem(
                    at: themeDir.appendingPathComponent(name),
                    to: previousDir.appendingPathComponent(name)
                )
            }
        } catch {
            Log.shared.warn("Could not keep the previous palette set: \(error.localizedDescription)", source: "theming")
        }
    }

    /// Swap, rather than copy, so Revert stays a one-step toggle.
    private func swapWithPrevious() throws -> [String] {
        let temporary = themeDir.appendingPathComponent(".swap-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }

        let previousFiles = managedFileNames.filter {
            fileManager.fileExists(atPath: previousDir.appendingPathComponent($0).path)
        }
        for name in previousFiles {
            try fileManager.copyItem(
                at: previousDir.appendingPathComponent(name),
                to: temporary.appendingPathComponent(name)
            )
        }

        // Only the generated set is swapped; include backups stay so a failed
        // restore can be retried.
        try fileManager.createDirectory(at: previousDir, withIntermediateDirectories: true)
        for name in managedFileNames {
            try? fileManager.removeItem(at: previousDir.appendingPathComponent(name))
        }
        let currentFiles = managedFileNames.filter {
            fileManager.fileExists(atPath: themeDir.appendingPathComponent($0).path)
        }
        for name in currentFiles {
            try fileManager.copyItem(
                at: themeDir.appendingPathComponent(name),
                to: previousDir.appendingPathComponent(name)
            )
            try fileManager.removeItem(at: themeDir.appendingPathComponent(name))
        }
        for name in previousFiles {
            try fileManager.moveItem(
                at: temporary.appendingPathComponent(name),
                to: themeDir.appendingPathComponent(name)
            )
        }
        return previousFiles
    }

    // MARK: - Wallpaper

    private func extractWallpaperPalette(
        appearance: String,
        saturation: Double,
        contrast: Double
    ) async -> PalettePalette? {
        guard let url = wallpaperURLs.first else { return nil }
        guard let palette = await Self.wallpaperPalette(
            from: url,
            appearance: appearance,
            saturation: saturation,
            contrast: contrast
        ) else {
            Log.shared.warn("Could not read wallpaper at \(url.path)", source: "theming")
            return nil
        }
        previewPalette = palette
        return palette
    }

    /// Decoding and downsampling a 6K wallpaper is expensive, so it runs with
    /// the clustering on a background task instead of blocking the main actor.
    /// `readPixels` is injected so a test can prove where the read runs.
    nonisolated static func wallpaperPalette(
        from url: URL,
        appearance: String,
        saturation: Double,
        contrast: Double,
        readPixels: @escaping @Sendable (URL) -> WallpaperPixels? = { ThemingEngine.readWallpaperPixels($0) }
    ) async -> PalettePalette? {
        await Task.detached(priority: .userInitiated) {
            guard let pixels = readPixels(url) else { return nil }
            let resolved = appearance == "auto"
                ? WallpaperPalette.suggestedAppearance(pixels: pixels)
                : appearance
            return WallpaperPalette.extract(
                pixels: pixels,
                appearance: resolved,
                saturation: saturation,
                contrast: contrast
            )
        }.value
    }

    nonisolated static func readWallpaperPixels(_ url: URL) -> WallpaperPixels? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return WallpaperPalette.pixels(from: image)
    }

    // MARK: - Restart prompt

    private func restartApps(
        for targets: [String],
        reloads: [String: ThemingReload.Status]
    ) async -> RestartPrompt? {
        let selected = Set(targets)
        let kittyNeedsRestart = selected.contains(ThemingTarget.kitty.rawValue)
            && reloads[ThemingTarget.kitty.rawValue]?.state != .reloaded
        let apps = await appRestart.appsToRestart(
            kittyNeedsRestart: kittyNeedsRestart,
            neovideNeedsRestart: selected.contains(ThemingTarget.nvim.rawValue),
            ghosttyNeedsRestart: selected.contains(ThemingTarget.ghostty.rawValue)
        )
        return apps.isEmpty ? nil : RestartPrompt(apps: apps)
    }

    /// Quits and reopens the apps the prompt named, then reports what happened.
    /// The quit is graceful; nothing is force-killed.
    @discardableResult
    public func restartAppsNow() async -> String? {
        guard let prompt = restartPrompt else { return nil }
        restartPrompt = nil
        busy = true
        defer { busy = false }
        let report = await appRestart.restart(prompt.apps)
        if let report { status = report }
        return report
    }

    public func dismissRestartPrompt() {
        restartPrompt = nil
    }

    // MARK: - Reload

    /// Reload one target now and publish the answer. Only kitty has a reload
    /// Palette can perform; every other target returns what the user must do.
    @discardableResult
    public func reload(_ target: ThemingTarget) async -> ThemingReload.Status {
        let status = await liveReloadStatus(for: target)
        reloadStatuses[target.rawValue] = status
        return status
    }

    public func reloadStatus(for target: ThemingTarget) -> ThemingReload.Status {
        reloadStatuses[target.rawValue] ?? ThemingReload.status(for: target)
    }

    private func liveReloadStatus(
        for target: ThemingTarget,
        addedRemoteControl: Bool = false
    ) async -> ThemingReload.Status {
        guard ThemingReload.canAttempt(target) else { return ThemingReload.status(for: target) }
        return await kitty.reload(
            themeFile: themeDir.appendingPathComponent(target.fileName).path,
            configPath: includes.plan(for: target)?.path,
            addedRemoteControl: addedRemoteControl
        )
    }

    /// Launch: paint a running kitty with the palette already on disk. One
    /// socket command — no files written, no config changed and no restart
    /// prompt. Silence when there is nothing to push or no kitty listening.
    public func pushKittyPaletteOnLaunch(config: ThemingConfig) async {
        guard config.enabled, reloadsEnabled else { return }
        let themeFile = themeDir.appendingPathComponent(ThemingTarget.kitty.fileName)
        guard fileManager.fileExists(atPath: themeFile.path) else { return }
        guard let status = await kitty.pushExisting(
            themeFile: themeFile.path,
            configPath: includes.plan(for: .kitty)?.path
        ) else { return }
        Log.shared.info(
            status.state == .reloaded
                ? "Launch palette push: \(status.message)"
                : "Launch palette push failed: \(status.message)",
            source: "theming"
        )
    }

    private func reloadAll(
        _ targets: [String],
        kittyRemoteControlAdded: Bool
    ) async -> [String: ThemingReload.Status] {
        var statuses: [String: ThemingReload.Status] = [:]
        for raw in targets {
            guard let target = ThemingTarget(rawValue: raw), target.isImplemented else {
                continue
            }
            statuses[raw] = await liveReloadStatus(
                for: target,
                addedRemoteControl: target == .kitty && kittyRemoteControlAdded
            )
        }
        reloadStatuses = statuses
        return statuses
    }
}
