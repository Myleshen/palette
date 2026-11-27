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
    }

    public struct PolicyResult: Sendable, Equatable {
        public var status: String
        public var error: String?
        public var command: String
        public var states: [String: Bool]
    }

    /// Injected so tests can answer "is this browser installed / running / is
    /// its managed policy present?" without touching the real machine.
    public struct ChromiumProbe: Sendable {
        public var installed: @Sendable () -> Set<String>
        public var policyInstalled: @Sendable (String) async -> Bool
        public var isRunning: @Sendable (String) async -> Bool
        /// The `BrowserThemeColor` an installed profile forces, so a profile
        /// approved for the previous palette can be called stale.
        public var themeColor: @Sendable (String) async -> String?

        public init(
            installed: @escaping @Sendable () -> Set<String>,
            policyInstalled: @escaping @Sendable (String) async -> Bool,
            isRunning: @escaping @Sendable (String) async -> Bool,
            themeColor: @escaping @Sendable (String) async -> String? = { _ in nil }
        ) {
            self.installed = installed
            self.policyInstalled = policyInstalled
            self.isRunning = isRunning
            self.themeColor = themeColor
        }

        public static let live = ChromiumProbe(
            installed: {
                var ids = Set<String>()
                for browser in ChromiumBrowser.catalog {
                    let candidates = [
                        "/Applications/\(browser.appName).app",
                        NSHomeDirectory() + "/Applications/\(browser.appName).app",
                    ]
                    for candidate in candidates {
                        guard let bundle = Bundle(path: candidate),
                              bundle.bundleIdentifier == browser.bundleID else { continue }
                        ids.insert(browser.bundleID)
                        break
                    }
                }
                return ids
            },
            policyInstalled: { bundleID in
                for path in ChromiumPolicy.managedPreferencePaths(bundleID: bundleID)
                where FileManager.default.fileExists(atPath: path) {
                    if path.hasSuffix("complete.plist") {
                        guard let data = FileManager.default.contents(atPath: path),
                              ChromiumPolicy.carriesDomain(bundleID, in: data) else { continue }
                    }
                    return true
                }
                guard let result = try? await ProcessRunner.run(["profiles", "-P"], timeout: 3) else {
                    return false
                }
                return result.stdoutString.contains(ChromiumPolicy.identifier(for: bundleID))
            },
            isRunning: { processName in
                guard let result = try? await ProcessRunner.run(["pgrep", "-x", processName], timeout: 2) else {
                    return false
                }
                return result.status == 0
            },
            themeColor: { bundleID in
                for path in ChromiumPolicy.managedPreferencePaths(bundleID: bundleID) {
                    guard let data = FileManager.default.contents(atPath: path),
                          let colour = ChromiumPolicy.themeColor(in: data, bundleID: bundleID) else { continue }
                    return colour
                }
                return nil
            }
        )
    }

    @Published public private(set) var status = "No palette applied yet."
    @Published public private(set) var lastResult: ApplyResult?
    @Published public private(set) var previewPalette: PalettePalette?
    @Published public private(set) var busy = false
    @Published public private(set) var policyBusy = false
    @Published public private(set) var policyStates: [String: Bool] = [:]
    @Published public private(set) var policyStatus: String?
    @Published public private(set) var policyError: String?
    @Published public private(set) var policyCommand: String?
    /// Last reload answer per target, so the Targets rows and the Apply result
    /// say what the app actually did rather than guessing.
    @Published public private(set) var reloadStatuses: [String: ThemingReload.Status] = [:]

    public let themeDir: URL
    public let previousDir: URL
    public let themesDirectory: URL
    public let includes: ThemingIncludes

    private let fileManager = FileManager.default
    private let chromiumProbe: ChromiumProbe
    private let kitty: KittyRemoteControl
    private let macOSMajorVersion: Int
    /// Tests generate files in a sandbox HOME; asking the user's kitty to
    /// reload colours from that sandbox would paint the live terminal.
    private let reloadsEnabled: Bool

    public init(
        paths: PalettePaths,
        themesDirectory: URL,
        chromiumProbe: ChromiumProbe = .live,
        kitty: KittyRemoteControl = KittyRemoteControl(),
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        reloadsEnabled: Bool = true
    ) {
        self.themeDir = paths.themeDir
        self.previousDir = paths.themeDir.appendingPathComponent("previous", isDirectory: true)
        self.themesDirectory = themesDirectory
        self.chromiumProbe = chromiumProbe
        self.kitty = kitty
        self.macOSMajorVersion = macOSMajorVersion
        self.reloadsEnabled = reloadsEnabled
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

    public var supportsLegacyPolicyCLI: Bool {
        ChromiumPolicy.installFlow(majorVersion: macOSMajorVersion) == .legacyProfiles
    }

    /// The master switch going off removes every marked block, leaving each
    /// app's own config otherwise untouched.
    public func removeAllIncludes() -> [ThemingIncludes.Outcome] {
        includes.removeAll()
    }

    /// Helium is always offered; every other browser only when it is installed.
    public func browserRows() -> [ChromiumBrowser] {
        let installed = chromiumProbe.installed()
        return ChromiumBrowser.catalog.filter {
            $0.target == .helium || installed.contains($0.bundleID)
        }
    }

    public func installedBrowserIDs() -> Set<String> { chromiumProbe.installed() }

    public func policyURL(for browser: ChromiumBrowser) -> URL {
        themeDir.appendingPathComponent(browser.mobileConfigFileName)
    }

    public func refreshPolicyStates() async {
        var states: [String: Bool] = [:]
        for browser in ChromiumBrowser.catalog {
            states[browser.bundleID] = await chromiumProbe.policyInstalled(browser.bundleID)
        }
        policyStates = states
    }

    public static func shouldAutoApply(_ config: ThemingConfig, wallpaperChanged: Bool = true) -> Bool {
        config.enabled && config.source == .wallpaper && config.followWallpaper && wallpaperChanged
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

    /// A wallpaper card may change the desktop picture regardless; the palette
    /// engine only runs when cross-app theming is already on. Passing through
    /// here also means a card never writes `enabled = true` behind the user.
    public static func shouldApplyWallpaperCard(_ config: ThemingConfig) -> Bool {
        config.enabled
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
        Self.managedFileNames() + [ThemingRenderer.paletteJSONName]
    }

    private func disabledResult() -> ApplyResult {
        let removed = includes.removeAll()
        reloadStatuses.removeAll()
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
        // id, and only a genuinely missing theme falls back to Default Dark.
        let resolvedID = ThemeLoader.themeID(for: name, themesDirectory: themesDirectory)
        let id = resolvedID ?? "default-dark"
        value.theme = id
        let fallback = Theme.defaultDark
        let loaded = ThemeLoader.load(name: id, themesDirectory: themesDirectory, fallback: fallback)
        let palette = PalettePalette(theme: loaded.theme)
        let metadata = PaletteMetadata(
            source: "theme",
            theme: loaded.theme.name,
            appearance: palette.appearance,
            themeID: id,
            targets: value.targets
        )
        Log.shared.info(
            "Applying '\(loaded.theme.name)' (\(id)) · bg \(palette.background) fg \(palette.foreground)",
            source: "theming"
        )
        var result = await finish(palette: palette, metadata: metadata, config: value)
        if resolvedID == nil {
            let message = name.isEmpty
                ? "No theme name was given; applied Default Dark."
                : "Theme '\(name)' was not found; applied Default Dark."
            Log.shared.warn(message, source: "theming")
            result.notices.insert(message, at: 0)
            result.status += " · " + message
            status = result.status
            lastResult = result
        }
        return result
    }

    public func applyWallpaper(_ config: ThemingConfig) async -> ApplyResult {
        guard config.enabled else { return disabledResult() }
        busy = true
        defer { busy = false }
        var value = config.normalized()
        value.source = .wallpaper
        let appearance = PalettePalette.appearance(darkMode: value.darkMode)
        guard let palette = await extractWallpaperPalette(appearance: appearance) else {
            let message = Self.missingWallpaperMessage(
                path: wallpaperURLs.first.map { includes.shortPath($0.path) }
            )
            status = message
            let result = ApplyResult(
                status: message, source: "wallpaper", appearance: appearance,
                written: [], skipped: [], includeLines: [], notices: [], changes: [], targets: [], error: message
            )
            lastResult = result
            return result
        }
        let metadata = PaletteMetadata(
            source: "wallpaper",
            theme: "Wallpaper",
            appearance: appearance,
            targets: value.targets
        )
        return await finish(palette: palette, metadata: metadata, config: value)
    }

    /// Extracts without writing, so the Settings pane can show the swatches
    /// before the user commits.
    public func previewWallpaper(darkMode: String = "auto") async -> PalettePalette? {
        let appearance = PalettePalette.appearance(darkMode: darkMode)
        let palette = await extractWallpaperPalette(appearance: appearance)
        previewPalette = palette
        return palette
    }

    public var wallpaperURLs: [URL] {
        var seen = Set<String>()
        return NSScreen.screens.compactMap { screen in
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
            return seen.insert(url.path).inserted ? url : nil
        }
    }

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
            let includeOutcomes = includes.revert()
            reloadStatuses.removeAll()
            let restored = try swapWithPrevious()
            let failures = includeOutcomes.filter { $0.action == .failed }
            let includeCount = includeOutcomes.filter { $0.action != .failed }.count
            var message = "Restored the previous palette set (\(restored.count) file\(restored.count == 1 ? "" : "s"))"
            if includeCount > 0 {
                message += " and \(includeCount) app config\(includeCount == 1 ? "" : "s")"
            }
            message += "."
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
            let message = "Could not revert: \(error.localizedDescription)"
            status = message
            return ApplyResult(
                status: message, source: "", appearance: "",
                written: [], skipped: [], includeLines: [], notices: [], changes: [], targets: [], error: message
            )
        }
    }

    // MARK: - Managed policy install / remove

    /// macOS 27 removed `profiles install`, so the profile is opened in System
    /// Settings instead of being installed by the CLI. Opening works on older
    /// macOS too, where double-clicking a .mobileconfig prompts the same way.
    public func installPolicies(_ config: ThemingConfig) async -> PolicyResult {
        let selected = selectedBrowsers(config)
        let files = selected.compactMap { browser -> String? in
            let url = policyURL(for: browser)
            return fileManager.fileExists(atPath: url.path) ? url.path : nil
        }
        let legacyCommand = ChromiumPolicy.installFlow(majorVersion: macOSMajorVersion) == .legacyProfiles
            ? ChromiumPolicy.installCommand(paths: files)
            : nil
        guard !files.isEmpty else {
            let message = "Nothing to install. Apply Palette first to generate the policy files."
            policyStatus = message
            policyError = message
            policyCommand = legacyCommand
            return PolicyResult(status: message, error: message, command: legacyCommand ?? "", states: policyStates)
        }
        policyBusy = true
        defer { policyBusy = false }
        var opened = 0
        for file in files {
            if let result = try? await ProcessRunner.run(["open", file], timeout: 10), result.status == 0 {
                opened += 1
            }
        }
        await refreshPolicyStates()
        policyCommand = legacyCommand
        guard opened == files.count else {
            let message = opened == 0
                ? "Could not open the profile file. Use Reveal file and double-click it."
                : "Opened \(opened) of \(files.count) profile files."
            policyError = message
            policyStatus = "Could not open every managed policy."
            return PolicyResult(status: policyStatus ?? "", error: message, command: legacyCommand ?? "", states: policyStates)
        }
        policyError = nil
        policyStatus = ChromiumPolicy.installSteps(files: files)
        return PolicyResult(status: policyStatus ?? "", error: nil, command: legacyCommand ?? "", states: policyStates)
    }

    public func removePolicies(_ config: ThemingConfig) async -> PolicyResult {
        // Removal is not scoped to the current selection: unchecking a browser
        // leaves its installed profile behind, so every browser Palette can
        // manage is targeted.
        let identifiers = ChromiumPolicy.allPolicyIdentifiers()
        let command = ChromiumPolicy.removeCommand(identifiers: identifiers)
        guard !identifiers.isEmpty else {
            let message = "Nothing to remove."
            policyStatus = message
            policyError = message
            policyCommand = command
            return PolicyResult(status: message, error: message, command: command, states: policyStates)
        }
        guard ChromiumPolicy.installFlow(majorVersion: macOSMajorVersion) == .legacyProfiles else {
            let message = "Remove Palette under System Settings → General → Device Management, then Refresh."
            policyStatus = message
            policyError = nil
            policyCommand = nil
            return PolicyResult(status: message, error: nil, command: "", states: policyStates)
        }
        policyBusy = true
        defer { policyBusy = false }
        let shell = identifiers.map { "/usr/bin/profiles remove -identifier \(ChromiumPolicy.token($0))" }
            .joined(separator: " && ")
        do {
            let result = try await runWithAdministratorPrivileges(shell)
            guard result.status == 0 else {
                let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                policyError = message.isEmpty ? "Removal failed or was cancelled." : message
                policyStatus = "Could not remove the managed policies."
                policyCommand = command
                return PolicyResult(status: policyStatus ?? "", error: policyError, command: command, states: policyStates)
            }
            await refreshPolicyStates()
            let refreshed = await refreshRunningBrowsers(ChromiumBrowser.catalog.filter(\.supportsThemePolicy))
            policyStatus = "Removed \(identifiers.count) managed polic\(identifiers.count == 1 ? "y" : "ies")."
            if !refreshed.isEmpty {
                policyStatus = (policyStatus ?? "") + " Restart may still be needed."
            }
            policyError = nil
            policyCommand = command
            return PolicyResult(status: policyStatus ?? "", error: nil, command: command, states: policyStates)
        } catch {
            policyError = error.localizedDescription
            policyStatus = "Could not remove the managed policies."
            policyCommand = command
            return PolicyResult(status: policyStatus ?? "", error: policyError, command: command, states: policyStates)
        }
    }

    private func selectedBrowsers(_ config: ThemingConfig) -> [ChromiumBrowser] {
        config.targets.compactMap { raw in
            guard let target = ThemingTarget(rawValue: raw),
                  let browser = ChromiumBrowser.browser(for: target),
                  browser.supportsThemePolicy else { return nil }
            return browser
        }
    }

    private func runWithAdministratorPrivileges(_ shell: String) async throws -> ProcessResult {
        let script = "do shell script \(Self.appleScriptQuote(shell)) with administrator privileges"
        return try await ProcessRunner.run(["/usr/bin/osascript", "-e", script], timeout: 180)
    }

    private func refreshRunningBrowsers(_ browsers: [ChromiumBrowser]) async -> [String] {
        var refreshed: [String] = []
        for browser in browsers {
            guard await chromiumProbe.isRunning(browser.processName) else { continue }
            _ = try? await ProcessRunner.run(
                ["open", "-a", browser.appName, "--args", "--refresh-platform-policy", "--no-startup-window"],
                timeout: 4
            )
            refreshed.append(browser.name)
        }
        return refreshed
    }

    private static func appleScriptQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - Writing

    private func finish(
        palette: PalettePalette,
        metadata: PaletteMetadata,
        config: ThemingConfig
    ) async -> ApplyResult {
        do {
            let outcome = try await write(palette: palette, metadata: metadata, targets: config.targets)
            let succeeded = outcome.failed.isEmpty
            let reloads = succeeded ? await reloadAll(config.targets) : [:]
            var summary: String
            if succeeded {
                summary = "Applied \(outcome.written.count) file\(outcome.written.count == 1 ? "" : "s") to \(themeDir.path)."
            } else {
                summary = "Applied \(outcome.written.count) file\(outcome.written.count == 1 ? "" : "s"); \(outcome.failed.count) failed."
            }
            if let suffix = outcome.statusSuffix {
                summary += " · \(suffix)"
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
            if outcome.policySelected {
                notes.append("Managed policies: open the profile in System Settings and approve it under General → Device Management.")
            }
            notes += outcome.notices
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
            status = summary
            lastResult = result

            return result
        } catch {
            let message = "Could not write palette files: \(error.localizedDescription)"
            status = message
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
        var statusSuffix: String?
        var policySelected: Bool
        var reports: [TargetReport]
    }

    private struct ChromiumOutcome {
        var state: TargetReport.State
        var note: String
        var changes: [String]
        var needsInstall: Bool
    }

    private func write(
        palette: PalettePalette,
        metadata: PaletteMetadata,
        targets: [String]
    ) async throws -> WriteOutcome {
        try fileManager.createDirectory(at: themeDir, withIntermediateDirectories: true)
        snapshotCurrentSet()

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
        var statusSuffix: String?
        var policySelected = false
        var anyNeedsInstall = false
        var anyPolicyWritten = false
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
            if let browser = target.browser {
                policySelected = true
                let outcome = await applyChromiumPolicy(browser: browser, palette: palette)
                switch outcome.state {
                case .written:
                    written.append(target.fileName)
                    changes.append(contentsOf: outcome.changes)
                    anyPolicyWritten = true
                    if outcome.needsInstall { anyNeedsInstall = true }
                case .skipped:
                    skipped.append(target.fileName)
                case .failed:
                    failed.append(target.fileName)
                }
                reports.append(TargetReport(
                    id: target.rawValue,
                    title: target.title,
                    fileName: target.fileName,
                    includeHint: target.includeHint,
                    note: outcome.note,
                    state: outcome.state
                ))
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

        if policySelected {
            if anyNeedsInstall {
                statusSuffix = "Awaiting install in System Settings"
            } else if anyPolicyWritten {
                statusSuffix = "Managed policies installed"
            } else {
                statusSuffix = "No browser policy written"
            }
        }
        return WriteOutcome(
            written: written,
            skipped: skipped,
            failed: failed,
            changed: changes,
            notices: notices,
            statusSuffix: statusSuffix,
            policySelected: policySelected,
            reports: reports
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

    private func applyChromiumPolicy(
        browser: ChromiumBrowser,
        palette: PalettePalette
    ) async -> ChromiumOutcome {
        guard browser.supportsThemePolicy else {
            return ChromiumOutcome(
                state: .skipped,
                note: "\(browser.name) does not implement BrowserThemeColor.",
                changes: [],
                needsInstall: false
            )
        }
        guard chromiumProbe.installed().contains(browser.bundleID) else {
            return ChromiumOutcome(
                state: .skipped,
                note: "\(browser.name) is not installed.",
                changes: [],
                needsInstall: false
            )
        }
        let xml = ChromiumPolicy.mobileConfig(browser: browser, palette: palette)
        do {
            try Data(xml.utf8).write(to: policyURL(for: browser), options: .atomic)
        } catch {
            return ChromiumOutcome(
                state: .failed,
                note: "Could not write the \(browser.name) policy: \(error.localizedDescription)",
                changes: [],
                needsInstall: false
            )
        }
        let installed = await chromiumProbe.policyInstalled(browser.bundleID)
        policyStates[browser.bundleID] = installed
        let installedColour = installed ? await chromiumProbe.themeColor(browser.bundleID) : nil
        let stale = installedColour.map {
            $0.caseInsensitiveCompare(palette.background) != .orderedSame
        } ?? false
        if installed, await chromiumProbe.isRunning(browser.processName) {
            _ = try? await ProcessRunner.run(
                ["open", "-a", browser.appName, "--args", "--refresh-platform-policy", "--no-startup-window"],
                timeout: 4
            )
        }
        let note: String
        if stale {
            note = "Installed — re-approve the updated profile"
        } else if installed {
            note = "Installed — all \(browser.name) profiles."
        } else {
            note = "Not installed — open the profile in System Settings."
        }
        let changes = [
            "\(browser.mobileConfigFileName): \(policyURL(for: browser).path)",
            "\(browser.policyIdentifier): BrowserThemeColor = \(palette.background)",
        ]
        return ChromiumOutcome(state: .written, note: note, changes: changes, needsInstall: !installed || stale)
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

    private func extractWallpaperPalette(appearance: String) async -> PalettePalette? {
        guard let url = wallpaperURLs.first else { return nil }
        guard let image = NSImage(contentsOf: url) else {
            Log.shared.warn("Could not read wallpaper at \(url.path)", source: "theming")
            return nil
        }
        // AppKit drawing stays on the main actor; only the clustering moves off.
        guard let pixels = WallpaperPalette.pixels(from: image) else {
            Log.shared.warn("Could not sample wallpaper at \(url.path)", source: "theming")
            return nil
        }
        let palette = await Task.detached(priority: .userInitiated) {
            WallpaperPalette.extract(pixels: pixels, appearance: appearance)
        }.value
        previewPalette = palette
        return palette
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

    private func liveReloadStatus(for target: ThemingTarget) async -> ThemingReload.Status {
        guard ThemingReload.canAttempt(target) else { return ThemingReload.status(for: target) }
        return await kitty.reload(themeFile: themeDir.appendingPathComponent(target.fileName).path)
    }

    private func reloadAll(_ targets: [String]) async -> [String: ThemingReload.Status] {
        var statuses: [String: ThemingReload.Status] = [:]
        for raw in targets {
            // Browsers report through the managed policy, not a file include.
            guard let target = ThemingTarget(rawValue: raw), target.isImplemented, !target.isBrowser else {
                continue
            }
            statuses[raw] = await liveReloadStatus(for: target)
        }
        reloadStatuses = statuses
        return statuses
    }
}
