import AppKit
import Combine
import Foundation
import PaletteCore
import PalettePlatform
import PaletteProviders
import PaletteRuntime
import ServiceManagement
import SwiftUI

final class HostBridgeProxy: HostBridge, @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: SearchController?

    func setTarget(_ target: SearchController) {
        lock.lock()
        self.target = target
        lock.unlock()
    }

    private func current() -> SearchController? {
        lock.lock()
        defer { lock.unlock() }
        return target
    }

    func prompt(kind: PromptKind, title: String, placeholder: String?) async -> String? {
        guard let target = current() else { return nil }
        return await target.prompt(kind: kind, title: title, placeholder: placeholder)
    }

    func prompt(
        kind: PromptKind,
        title: String,
        placeholder: String?,
        validation: PromptValidation
    ) async -> String? {
        guard let target = current() else { return nil }
        return await target.prompt(
            kind: kind,
            title: title,
            placeholder: placeholder,
            validation: validation
        )
    }

    func notify(_ message: String) async {
        guard let target = current() else { return }
        await target.notify(message)
    }

    func beginProgress(_ message: String) async {
        guard let target = current() else { return }
        await target.beginProgress(message)
    }

    func copyToClipboard(_ text: String, concealed: Bool, clearAfterMs: Int?) async {
        guard let target = current() else { return }
        await target.copyToClipboard(text, concealed: concealed, clearAfterMs: clearAfterMs)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var paths: PalettePaths!
    private var configuration: PaletteConfig!
    private var store: PaletteStore!
    private var themeManager: ThemeManager!
    private var launcher: LauncherService!
    private var pasteboard: PasteboardService!
    private var clipboardMonitor: ClipboardMonitor?
    private var registry: ProviderRegistry!
    /// Every loaded provider, including disabled ones, so Settings can edit
    /// their aliases and show their real names and triggers.
    private var allProviderInfo: [ProviderSettingsInfo] = []
    private let bitwardenVault = BitwardenVault()
    private let keepAwake = KeepAwakeService()
    private let timerService = TimerService()
    private let captureService = CaptureService()
    private var clamshellObserver: NSObjectProtocol?
    private var searchController: SearchController!
    private var panel: PanelController!
    /// Every live manager, keyed by the row id Settings uses.
    private var hotkeyManagers: [String: HotKeyManager] = [:]
    private var currentHotKey: HotKeySpec?
    private var hotKeyInstallTask: Task<Void, Never>?
    private var statusItem: NSStatusItem!
    private var hostProxy: HostBridgeProxy!
    private var appIndex: AppIndex!
    /// Bindable catalogue, rebuilt with the registry so provider ids never lie.
    private var catalogCommands: [CatalogCommand] = []
    private var recordingTicker: Timer?
    private var recordingOptionsPanel: RecordingOptionsPanelController?
    private var captureMenuItems: [CaptureMenuCommand: NSMenuItem] = [:]
    private var lastCaptureURL: URL?
    private var lastRecordingURL: URL?
    private var lastScreenshotURL: URL?
    private var menuBarFlashTask: Task<Void, Never>?
    private let screenshotHUD = ScreenshotHUD()
    private var annotateWindows: [AnnotateWindowController] = []
    private var mediaPreviews: [MediaPreviewWindowController] = []
    private var askWindow: AskWindowController?
    private var aboutWindow: AboutWindowController?
    private var systemIsShuttingDown = false
    private var askService: AskService?
    private var startupDiagnostics: [Diagnostic] = []
    /// Set when config.toml cannot be parsed; auto-apply must not overwrite it.
    private var configErrorMessage: String?
    private var themeObserver: NSObjectProtocol?
    private var watcherTimer: Timer?
    private var maintenanceTimer: Timer?
    private var configChangeTask: DispatchWorkItem?
    private var maintenanceRunning = false
    private var pendingLaunchStatus: String?
    private var lastConfigModification: Date?
    private var lastThemesSignature: Date?
    private var lastProvidersSignature: Date?
    private var reloadInFlight = false
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var shouldShowOnboarding = false
    private var positionMenu: NSMenu?
    private var keepAwakeMenu: NSMenu?
    private var keepAwakeToggleItem: NSMenuItem?
    private var keepAwakeClamshellItem: NSMenuItem?
    private var keepAwakeStopItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Shutdown and logout must never be blocked by the ⌘Q guard below.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWillPowerOff),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )
        // Dock/undock or a resolution change must re-apply auto width and rows
        // immediately, not on the next open.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // Finder launches inherit launchd's minimal PATH. Give child CLIs
        // (devx, bw, zellij) the Homebrew directories without changing tools
        // that already use absolute paths.
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let toolPath = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/opt/local/bin"]
            .filter { !existingPath.split(separator: ":").map(String.init).contains($0) }
        if !toolPath.isEmpty {
            setenv("PATH", (toolPath + [existingPath]).joined(separator: ":"), 1)
        }
        paths = PalettePaths.resolve()
        do {
            try paths.createDirectories()
        } catch {
            fputs("Palette: could not create directories: \(error)\n", stderr)
        }
        Log.shared.configure(url: paths.logFile)
        Log.shared.info("Palette launching from \(Bundle.main.bundlePath)", source: "app")
        CrashReporter.install(url: paths.stateDir.appendingPathComponent("crash.log"))

        // One Palette at a time. A stale build or a second installed copy must
        // not leave two owners fighting over the global hotkeys.
        if ProcessInfo.processInfo.environment["PALETTE_SCRIPT"] == nil,
           let bundleID = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != getpid() }) {
            Log.shared.warn("Another Palette is already running; activating it instead", source: "app")
            other.activate(options: [])
            NSApp.terminate(nil)
            return
        }

        let configResult = ConfigLoader.load(paths: paths)
        configuration = configResult.config
        startupDiagnostics = configResult.diagnostics
        configErrorMessage = configResult.parseError
        captureService.stateFile = paths.stateDir.appendingPathComponent("recording.json")
        let recordingAdoption = captureService.adoptPendingRecording()
        let forceOnboarding = ProcessInfo.processInfo.environment["PALETTE_FORCE_ONBOARDING"] == "1"
        shouldShowOnboarding = (configResult.createdDefault || forceOnboarding)
            && (forceOnboarding || !UserDefaults.standard.bool(forKey: "onboardingCompleted"))
        if isScriptMode && !forceOnboarding {
            // A scripted run must never open a focus-stealing window or touch
            // the real onboarding flag. Forcing onboarding explicitly still
            // renders it so the harness can snapshot it.
            shouldShowOnboarding = false
        }
        ToolLocator.shared.configure(extraPaths: configuration.toolsPath)

        removeStaleLegacyFiles()
        let fallbackDatabase = paths.stateDir.appendingPathComponent("palette-fallback.sqlite")
        do {
            store = try PaletteStore(path: paths.databaseFile.path)
            // A fallback from an old failed launch is stale once the real file
            // opens. Keep it, renamed, rather than merging histories (out of
            // scope for this release) or deleting user data silently.
            if FileManager.default.fileExists(atPath: fallbackDatabase.path) {
                let kept = fallbackDatabase.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: kept)
                do {
                    try FileManager.default.moveItem(at: fallbackDatabase, to: kept)
                    Log.shared.warn("Recovered from a fallback database; old file kept at \(kept.path)", source: "storage")
                    pendingLaunchStatus = "Recovered from a fallback database; the old file is kept at \(kept.path)"
                } catch {
                    Log.shared.warn("Could not archive the fallback database: \(error.localizedDescription)", source: "storage")
                }
            }
        } catch {
            Log.shared.error("Database failed: \(error.localizedDescription)", source: "app")
            do {
                store = try PaletteStore(path: fallbackDatabase.path)
                startupDiagnostics.append(Diagnostic(.warning, "Primary database unavailable; using \(fallbackDatabase.lastPathComponent).", source: "storage"))
            } catch {
                fputs("Palette: database unavailable: \(error)\n", stderr)
                NSApp.terminate(nil)
                return
            }
        }

        seedUserProviders()
        seedCommandsFile()
        seedBookmarksFile()
        registerLoginItemOnFirstLaunch()
        launcher = LauncherService()
        pasteboard = PasteboardService()
        pasteboard.stateFile = paths.stateDir.appendingPathComponent("clipboard-clear.json")
        pasteboard.resumePendingClear()

        Log.shared.info("Accessibility trusted=\(pasteboard.isAccessibilityTrusted)", source: "app")
        if !pasteboard.isAccessibilityTrusted {
            // Make the permission gap visible instead of silently copying.
            pasteboard.requestAccessibility()
        }
        appIndex = AppIndex()
        hostProxy = HostBridgeProxy()

        themeManager = ThemeManager(paths: paths, selection: configuration.theme, store: store)
        // Config overrides must apply on launch, not only after a reload.
        themeManager.typography = configuration.typography
        themeManager.searchPlaceholder = configuration.searchPlaceholder
        timerService.configure(sound: configuration.timer.sound, notifications: configuration.timer.notify)
        captureService.requestsPermission = !isScriptMode
        captureService.config = configuration.capture
        // A timer that outlived a quit resumes here; one that expired while the
        // app was closed announces itself once and is cleared.
        let timerAdoption = timerService.adopt(stateDir: paths.stateDir)
        captureService.onConfigChanged = { [weak self] capture in
            guard let self, self.configuration.capture != capture else { return }
            self.configuration.capture = capture
            do {
                try self.writeConfig(self.configuration)
            } catch {
                Log.shared.warn("Could not save the recording target: \(error.localizedDescription)", source: "capture")
            }
        }
        themeManager.reload()
        themeManager.onChange = { [weak self] theme in
            guard let self else { return }
            self.panel?.apply(theme: theme)
            self.applyThemeToCaptureWindows(theme)
        }

        let builtRegistry = buildRegistry()
        registry = builtRegistry
        // A badge left by an answer that landed while Palette was quitting
        // comes back with the chat that owns it.
        Task { [weak self] in
            guard let self, let askService = self.askService,
                  await askService.unseenChatID() != nil else { return }
            NSApp.dockTile.badgeLabel = "1"
        }
        // Warm `/edit` and `/neo` off the main thread: the walk is cached to
        // disk, so the first bound query after this launch is instant. The
        // whole-home walk waits for the one-time consent below.
        let homeConsent = askForHomeIndexingConsent(registry: builtRegistry)
        if ProcessInfo.processInfo.environment["PALETTE_SCRIPT"] == nil {
            Task.detached(priority: .utility) {
                for case let provider as PathsProvider in builtRegistry.providers {
                    await provider.prewarm(homeConsent: homeConsent)
                }
            }
        }
        searchController = SearchController(
            registry: registry,
            configuration: configuration,
            paths: paths,
            store: store,
            launcher: launcher,
            pasteboard: pasteboard,
            themeManager: themeManager,
            clipboardMonitor: nil
        )
        hostProxy.setTarget(searchController)
        searchController.observeTimerTicks()
        if case .expired = timerAdoption {
            searchController.setStatus("Timer finished while Palette was closed", duration: 8)
        }
        captureService.onStatus = { [weak self] message in
            self?.captureFeedback(message)
        }
        captureService.onFailure = { [weak self] message in
            guard let self else { return }
            self.captureService.annotateNextCapture = false
            self.recordingTicker?.invalidate()
            self.recordingTicker = nil
            self.updateCaptureMenu()
            self.captureFeedback(message)
        }
        captureService.onScreenshot = { [weak self] url in
            guard let self else { return }
            self.rememberCapture(url, recording: false)
            let forced = self.captureService.annotateNextCapture
            self.captureService.annotateNextCapture = false
            if forced || self.configuration.capture.editAfterCapture {
                self.openAnnotator(url)
                return
            }
            self.confirmCapture(url)
        }
        captureService.onRecordingStopped = { [weak self] url in
            guard let self else { return }
            self.rememberCapture(url, recording: true)
            guard self.configuration.capture.previewRecording else { return }
            self.openMediaPreview(url)
        }
        NotificationCenter.default.addObserver(
            forName: .paletteAnnotateRequest,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let path = note.object as? String else { return }
            Task { @MainActor in self?.openAnnotator(URL(fileURLWithPath: path)) }
        }
        clamshellObserver = NotificationCenter.default.addObserver(
            forName: .paletteClamshellDropped,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.searchController.setStatus("Clamshell mode stopped; lid sleep is back on", duration: 6)
                self.searchController.refreshResults()
                await self.refreshKeepAwakeMenu()
            }
        }
        wireControllerCallbacks()
        buildPanel()
        buildMainMenu()
        installHotKey()
        checkDefaultProviderTools()
        configureClipboard()
        buildStatusItem()
        if case .adopted = recordingAdoption {
            updateCaptureMenu()
            startRecordingTicker()
            searchController?.setStatus("Recording in progress", duration: nil)
        }

        installThemeObserver()
        configureWatchers()
        scheduleDatabaseMaintenance()
        showOnboardingIfNeeded()

        if let firstError = startupDiagnostics.first(where: { $0.level == .error }) {
            searchController.setStatus(firstError.message, duration: nil)
        } else if let warning = startupDiagnostics.first(where: { $0.level == .warning }) {
            Log.shared.warn(warning.message, source: warning.source ?? "app")
        }
        if let pendingLaunchStatus {
            searchController.setStatus(pendingLaunchStatus, duration: nil)
        }

        Task { [weak self] in
            await self?.themeManager.restore()
        }
        // Adopt a caffeinate session and a clamshell guard that outlived the
        // last run, so Settings and the menu show what is really on.
        Task { [weak self] in
            await self?.keepAwake.restore()
            await self?.refreshKeepAwakeMenu()
            self?.searchController.refreshResults()
        }

        if ProcessInfo.processInfo.environment["PALETTE_SCRIPT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.runScriptIfRequested()
            }
        } else if ProcessInfo.processInfo.environment["PALETTE_SHOW_ON_LAUNCH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.panel.show()
                self?.captureSnapshotIfRequested()
            }
        }
    }

    /// Drives the real controller with synthetic key events for unattended
    /// smoke tests. Format: steps separated by ';', e.g.
    /// `show; query=/calc 2+2*3; wait=0.4; key=enter; wait=1; snapshot=/tmp/a.png`.
    /// `assert=`/`wait_until=`/`dump=`/`exit` make a run verifiable: the process
    /// exits non-zero when any assertion or step fails.
    private func runScriptIfRequested() {
        guard let script = ProcessInfo.processInfo.environment["PALETTE_SCRIPT"] else { return }
        var steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        // `wait_until=<cond>;timeout=<s>` carries its own semicolon.
        var merged: [String] = []
        for step in steps {
            if let last = merged.last, last.hasPrefix("wait_until="), step.hasPrefix("timeout=") {
                merged[merged.count - 1] = last + ";" + step
            } else if !step.isEmpty {
                merged.append(step)
            }
        }
        steps = merged
        Task { @MainActor [weak self] in
            for step in steps {
                guard let self else { return }
                if step == "show" {
                    self.panel.show()
                } else if step == "hide" {
                    self.panel.hide()
                } else if step == "toggle" {
                    self.panel.toggle()
                } else if step == "actions" {
                    self.searchController.toggleActions()
                } else if step == "shot" {
                    self.captureScreenshot()
                } else if step == "shot_region" {
                    self.captureScreenshot(mode: .region)
                } else if step == "rec" {
                    self.toggleRecording()
                } else if step == "clamshell" {
                    try? await self.keepAwake.setClamshell(true)
                } else if step == "awake_stop" {
                    await self.keepAwake.stop()
                } else if let value = step.dropPrefix("awake=") {
                    try? await self.keepAwake.start(duration: Double(value))
                } else if let value = step.dropPrefix("annotate=") {
                    self.openAnnotator(URL(fileURLWithPath: value))
                } else if let value = step.dropPrefix("annotate_export=") {
                    self.annotateExport(value)
                } else if let value = step.dropPrefix("cue=") {
                    self.confirmCapture(URL(fileURLWithPath: value))
                    try? await Task.sleep(nanoseconds: 400_000_000)
                } else if let value = step.dropPrefix("preview=") {
                    self.openMediaPreview(URL(fileURLWithPath: value))
                } else if let value = step.dropPrefix("ui_drag=") {
                    _ = await self.simulateDrag(value)
                } else if step == "close_windows" {
                    self.annotateWindows.forEach { $0.close() }
                    self.mediaPreviews.forEach { $0.close() }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                } else if step == "settings" {
                    self.showSettings()
                } else if step == "about" {
                    self.showAboutWindow()
                } else if let value = step.dropPrefix("settings_tab="), let index = Int(value) {
                    self.showSettings()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    NotificationCenter.default.post(name: .paletteSettingsTab, object: index)
                } else if let value = step.dropPrefix("settings_size=") {
                    let parts = value.lowercased().split(separator: "x").compactMap { Double($0) }
                    if parts.count == 2 {
                        self.showSettings()
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        self.settingsWindow?.setContentSize(NSSize(width: parts[0], height: parts[1]))
                        self.settingsWindow?.center()
                    }
                } else if let value = step.dropPrefix("settings_jump=") {
                    self.showSettings()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    NotificationCenter.default.post(name: .paletteSettingsJump, object: value)
                } else if let value = step.dropPrefix("settings_search=") {
                    self.showSettings()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    NotificationCenter.default.post(name: .paletteSettingsSearch, object: value)
                } else if let value = step.dropPrefix("config=") {
                    let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2, var updated: PaletteConfig = self.configuration {
                        switch parts[0] {
                        case "provider_bar":
                            updated.window.providerBar = ProviderBarPlacement(rawValue: parts[1])
                                ?? updated.window.providerBar
                        default:
                            break
                        }
                        _ = self.applySettings(updated)
                    }
                } else if let value = step.dropPrefix("export_backup=") {
                    if !self.writeBackup(to: URL(fileURLWithPath: value)) {
                        self.recordScriptFailure("backup export failed")
                    }
                } else if let value = step.dropPrefix("screen_override=") {
                    let parts = value.lowercased().split(separator: "x").compactMap { Double($0) }
                    if parts.count == 2 {
                        self.panel?.screenSizeOverride = CGSize(width: parts[0], height: parts[1])
                        NotificationCenter.default.post(
                            name: NSApplication.didChangeScreenParametersNotification,
                            object: nil
                        )
                    }
                } else if let value = step.dropPrefix("settings_edit=") {                    let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        NotificationCenter.default.post(
                            name: .paletteSettingsEdit,
                            object: [parts[0]: parts[1]]
                        )
                    }
                } else if step == "settings_clear_search" {
                    NotificationCenter.default.post(name: .paletteSettingsClearSearch, object: nil)
                } else if step == "clipboard" {
                    self.showClipboard()
                } else if let value = step.dropPrefix("clipboard_test=") {
                    // Script-only: exercises the persisted clear window.
                    let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
                    let clearAfterMs = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
                    self.pasteboard.write(text: parts[0], concealed: true, clearAfterMs: clearAfterMs)
                } else if step == "scratchpad" {
                    self.searchController.openScratchpad()
                } else if step == "scratchlist" {
                    self.toggleScratchpad()
                } else if let value = step.dropPrefix("focus=") {
                    if let zone = LauncherZone(rawValue: value) {
                        self.searchController.focusZone = zone
                    } else {
                        self.recordScriptFailure("unknown focus zone '\(value)'")
                    }
                } else if let question = step.dropPrefix("askwindow=") {
                    self.showAskWindow(question: question)
                } else if step == "chatwindow" {
                    self.showAskWindow(question: "")
                } else if let value = step.dropPrefix("chatopen="), let index = Int(value) {
                    self.openSavedChat(at: index)
                } else if step == "ask_cancel" {
                    self.askWindow?.cancelRequest()
                } else if step == "asktoggle" {
                    self.toggleAskWindow()
                } else if step == "askclose" {
                    self.askWindow?.window?.close()
                } else if step == "quit" {
                    NSApp.terminate(nil)
                } else if step == "exit" {
                    self.finishScript()
                } else if let value = step.dropPrefix("dump=") {
                    self.writeScriptDump(to: value)
                } else if let value = step.dropPrefix("assert=") {
                    self.recordScriptFailure(self.scriptConditionFailure(value))
                } else if let value = step.dropPrefix("wait_until=") {
                    let parts = value.split(separator: ";").map(String.init)
                    let condition = parts.first ?? ""
                    let timeout = parts.dropFirst()
                        .first { $0.hasPrefix("timeout=") }
                        .flatMap { Double($0.dropFirst("timeout=".count)) } ?? 5
                    let deadline = Date().addingTimeInterval(timeout)
                    var failure = self.scriptConditionFailure(condition)
                    while failure != nil, Date() < deadline {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        failure = self.scriptConditionFailure(condition)
                    }
                    self.recordScriptFailure(
                        failure.map { "wait_until '\(condition)' timed out after \(timeout)s: \($0)" }
                    )
                } else if let value = step.dropPrefix("binding=") {
                    self.fireBinding(keys: value)
                } else if let value = step.dropPrefix("query=") {
                    self.searchController.query = value
                } else if let value = step.dropPrefix("rail=") {
                    self.searchController.selectRail(value)
                } else if step == "railfocus" {
                    self.searchController.railFocused = true
                } else if step == "refresh" {
                    self.searchController.refreshResults()
                } else if let value = step.dropPrefix("snapshot=") {
                    self.writeSnapshot(to: value)
                } else if let value = step.dropPrefix("probe=") {
                    self.scriptProbeResult = self.probeShortcut(value)
                } else if step == "record_options" {
                    self.presentRecordingOptions()
                } else if let value = step.dropPrefix("last_capture=") {
                    let url = URL(fileURLWithPath: value)
                    self.rememberCapture(
                        url,
                        recording: ["mov", "mp4"].contains(url.pathExtension.lowercased())
                    )
                } else if let value = step.dropPrefix("capture_menu=") {
                    self.writeCaptureMenu(to: value)
                } else if let value = step.dropPrefix("window_snapshot=") {
                    if let ask = self.askWindow?.window {
                        // Include the titlebar: it is transparent, so only the
                        // frame view shows whether the title is legible.
                        self.write(view: ask.contentView?.superview ?? NSView(), to: value)
                    } else if let options = self.recordingOptionsPanel?.window {
                        self.write(view: options.contentView ?? NSView(), to: value)
                    } else if let hud = self.annotateWindows.last?.window
                        ?? self.mediaPreviews.last?.window {
                        self.write(view: hud.contentView ?? NSView(), to: value)
                    } else if let hudView = self.screenshotHUD.view {
                        self.write(view: hudView, to: value)
                    } else if let about = self.aboutWindow?.window {
                        // Include the titlebar, as the ask window does above.
                        self.write(view: about.contentView?.superview ?? NSView(), to: value)
                    } else if let other = NSApp.keyWindow ?? NSApp.windows.last(where: { $0.isVisible }) {
                        self.write(view: other.contentView ?? NSView(), to: value)
                    }
                } else if let value = step.dropPrefix("settings_snapshot=") {
                    self.writeSettingsSnapshot(to: value)
                } else if let value = step.dropPrefix("onboarding_snapshot=") {
                    self.writeOnboardingSnapshot(to: value)
                } else if step == "onboarding_skip" {
                    self.skipOnboarding()
                } else if let value = step.dropPrefix("term=") {
                    self.searchController.openTerminalPanel(command: value.isEmpty ? nil : value)
                } else if step == "term_restart" {
                    self.searchController.restartTerminal()
                } else if let value = step.dropPrefix("prompt=") {
                    self.searchController.promptValue = value
                } else if let value = step.dropPrefix("wait=") {
                    let seconds = Double(value) ?? 0.3
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } else if let value = step.dropPrefix("key=") {
                    if let event = self.syntheticKey(value) {
                        _ = self.searchController.handleKey(event)
                    }
                } else {
                    Log.shared.warn("Unknown script step: \(step)", source: "app")
                    self.recordScriptFailure("unknown step '\(step)'")
                }
            }
        }
    }

    /// Script hook: fires a configured binding by its key, through the same
    /// `performBinding` path the Carbon hotkey uses.
    private func fireBinding(keys: String) {
        let normalized = keys.trimmingCharacters(in: .whitespaces).lowercased()
        guard let binding = configuration.bindings.first(where: {
            $0.keys.trimmingCharacters(in: .whitespaces).lowercased() == normalized
        }) else {
            recordScriptFailure("binding '\(keys)' not found")
            return
        }
        performBinding(binding)
    }

    // MARK: - Script assertions

    private var scriptProbeResult = ""

    /// Script hook: run the same availability check a recorder uses against
    /// the configured keys, including the nine built-ins.
    private func probeShortcut(_ keys: String) -> String {
        guard let spec = HotKeySpec.parse(keys) else { return "Invalid shortcut" }
        let owned = [
            configuration.hotkey, configuration.clipboardHotkey,
            configuration.terminalHotkey, configuration.scratchpadHotkey,
            configuration.askHotkey, configuration.screenshotHotkey,
            configuration.regionScreenshotHotkey, configuration.windowScreenshotHotkey,
            configuration.recordingHotkey,
        ] + configuration.bindings.map(\.keys)
            + configuration.shortcuts.map(\.keys)
        return ShortcutAvailability.message(for: spec, ownedKeys: owned) ?? "Available"
    }

    /// Everything an `assert=` or `dump=` can observe, read from the live
    /// controller and panel.
    private struct ScriptObservation {
        var panelVisible: Bool
        var query: String
        var scopeLabel: String
        var selectionIndex: Int
        var itemCount: Int
        var actionsMode: Bool
        var previewEnabled: Bool
        var railFocused: Bool
        var stripFocused: Bool
        var focusZone: String
        var railID: String
        var scratchpadActive: Bool
        var terminalActive: Bool
        var terminalExited: Bool
        var askWindows: Int
        var askStreaming: Bool
        var askTurns: Int
        var askChats: Int
        var askBadge: String
        var statusMessage: String
        var promptTitle: String
        var promptError: String
        var probeResult: String
        var panelHeight: CGFloat
        var panelWidth: CGFloat
        var derivedPanelHeight: CGFloat
        var providerCount: Int
        var providerBarMode: String
        var items: [PaletteItem]
    }

    private var scriptFailure = false
    private var scriptFailureReasons: [String] = []

    private static let scriptKeys = [
        "panelVisible", "query", "scopeLabel", "selectionIndex", "itemCount",
        "actionsMode", "previewEnabled", "railFocused", "stripFocused",
        "focusZone", "railID",
        "scratchpadActive", "terminalActive", "terminalExited", "askWindows",
        "askStreaming", "askTurns", "askChats", "askBadge",
        "firstTitle", "firstProvider", "statusMessage", "probeResult",
        "promptTitle", "promptError",
        "panelHeight", "providerCount", "providerBarMode", "panelWidth",
    ]

    private func scriptObservation() -> ScriptObservation {
        ScriptObservation(
            panelVisible: panel?.isVisible == true,
            query: searchController?.query ?? "",
            scopeLabel: searchController?.scopeLabel ?? "",
            selectionIndex: searchController?.selectionIndex ?? 0,
            itemCount: searchController?.items.count ?? 0,
            actionsMode: searchController?.actionsMode ?? false,
            previewEnabled: searchController?.previewEnabled ?? false,
            railFocused: searchController?.railFocused ?? false,
            stripFocused: searchController?.stripFocused ?? false,
            focusZone: searchController?.focusZone.rawValue ?? "search",
            railID: searchController?.activeRailID ?? "",
            scratchpadActive: searchController?.scratchpadActive ?? false,
            terminalActive: searchController?.terminalActive ?? false,
            terminalExited: searchController?.terminalExitCode != nil,
            askWindows: askWindow == nil ? 0 : 1,
            askStreaming: askWindow?.isStreaming ?? false,
            askTurns: askWindow?.turnCount ?? 0,
            askChats: askWindow?.chatCount ?? 0,
            askBadge: NSApp.dockTile.badgeLabel ?? "",
            statusMessage: searchController?.statusMessage ?? "",
            promptTitle: searchController?.prompt?.title ?? "",
            promptError: searchController?.promptValidationMessage ?? "",
            probeResult: scriptProbeResult,
            panelHeight: panel?.panel.frame.height ?? 0,
            panelWidth: panel?.panel.frame.width ?? 0,
            derivedPanelHeight: panel?.panel.frame.height ?? 0,
            providerCount: searchController?.railEntries.count ?? 0,
            providerBarMode: searchController?.providerBar.rawValue ?? "",
            items: searchController?.items ?? []
        )
    }

    private func scriptValue(_ key: String, _ observation: ScriptObservation) -> String {
        switch key {
        case "panelVisible": return String(observation.panelVisible)
        case "selectionIndex": return String(observation.selectionIndex)
        case "itemCount": return String(observation.itemCount)
        case "actionsMode": return String(observation.actionsMode)
        case "previewEnabled": return String(observation.previewEnabled)
        case "railFocused": return String(observation.railFocused)
        case "stripFocused": return String(observation.stripFocused)
        case "focusZone": return observation.focusZone
        case "railID": return observation.railID
        case "scratchpadActive": return String(observation.scratchpadActive)
        case "terminalActive": return String(observation.terminalActive)
        case "terminalExited": return String(observation.terminalExited)
        case "askWindows": return String(observation.askWindows)
        case "askStreaming": return String(observation.askStreaming)
        case "askTurns": return String(observation.askTurns)
        case "askChats": return String(observation.askChats)
        case "askBadge": return observation.askBadge
        case "query": return observation.query
        case "scopeLabel": return observation.scopeLabel
        case "firstTitle": return observation.items.first?.title ?? ""
        case "firstProvider": return observation.items.first?.providerID ?? ""
        case "probeResult": return observation.probeResult
        case "promptTitle": return observation.promptTitle
        case "promptError": return observation.promptError
        case "panelHeight": return String(format: "%.2f", observation.panelHeight)
        case "panelWidth": return String(format: "%.2f", observation.panelWidth)
        case "derivedPanelHeight": return String(format: "%.2f", observation.derivedPanelHeight)
        case "providerCount": return String(observation.providerCount)
        case "providerBarMode": return observation.providerBarMode
        default: return observation.statusMessage
        }
    }

    /// Nil when the condition holds; otherwise why it did not.
    /// Grammar: `<key><op><value>`, op ∈ {=, !=, >, <, ~=}.
    private func scriptConditionFailure(_ condition: String) -> String? {
        let observation = scriptObservation()
        guard let key = Self.scriptKeys.first(where: { condition.hasPrefix($0) }) else {
            return "unknown condition '\(condition)'"
        }
        let rest = condition.dropFirst(key.count)
        guard let op = ["!=", "~=", "=", ">", "<"].first(where: { rest.hasPrefix($0) }) else {
            return "missing operator in '\(condition)'"
        }
        let expected = String(rest.dropFirst(op.count))
        let actual = scriptValue(key, observation)

        switch key {
        case "panelVisible", "actionsMode", "previewEnabled", "scratchpadActive", "terminalActive", "terminalExited":
            guard let want = Bool(expected) else {
                return "\(key) expects true/false, got '\(expected)'"
            }
            let have = actual == "true"
            switch op {
            case "=": return have == want ? nil : "\(key)=\(actual), expected \(want)"
            case "!=": return have != want ? nil : "\(key)=\(actual), expected != \(want)"
            default: return "'\(op)' is not supported for \(key)"
            }
        case "selectionIndex", "itemCount":
            guard let want = Int(expected), let have = Int(actual) else {
                return "\(key) expects a number, got '\(expected)'"
            }
            let ok: Bool
            switch op {
            case "=": ok = have == want
            case "!=": ok = have != want
            case ">": ok = have > want
            case "<": ok = have < want
            default: ok = false
            }
            return ok ? nil : "\(key)=\(actual), expected \(op) \(expected)"
        default:
            switch op {
            case "=": return actual == expected ? nil : "\(key)='\(actual)', expected '\(expected)'"
            case "!=": return actual != expected ? nil : "\(key)='\(actual)', expected != '\(expected)'"
            case "~=":
                guard let regex = try? NSRegularExpression(pattern: expected) else {
                    return "invalid regex '\(expected)'"
                }
                let range = NSRange(actual.startIndex..., in: actual)
                return regex.firstMatch(in: actual, range: range) != nil
                    ? nil
                    : "\(key)='\(actual)' does not match /\(expected)/"
            default: return "'\(op)' is not supported for \(key)"
            }
        }
    }

    private func recordScriptFailure(_ reason: String?) {
        guard let reason else { return }
        scriptFailure = true
        scriptFailureReasons.append(reason)
        fputs("SCRIPT: \(reason)\n", stderr)
    }

    private func writeScriptDump(to destination: String) {
        let observation = scriptObservation()
        let dump: [String: Any] = [
            "panelVisible": observation.panelVisible,
            "query": observation.query,
            "scopeLabel": observation.scopeLabel,
            "selectionIndex": observation.selectionIndex,
            "itemCount": observation.itemCount,
            "actionsMode": observation.actionsMode,
            "previewEnabled": observation.previewEnabled,
            "railFocused": observation.railFocused,
            "stripFocused": observation.stripFocused,
            "focusZone": observation.focusZone,
            "railID": observation.railID,
            "scratchpadActive": observation.scratchpadActive,
            "terminalActive": observation.terminalActive,
            "askWindows": observation.askWindows,
            "askStreaming": observation.askStreaming,
            "askTurns": observation.askTurns,
            "askChats": observation.askChats,
            "askBadge": observation.askBadge,
            "statusMessage": observation.statusMessage,
            "promptTitle": observation.promptTitle,
            "promptError": observation.promptError,
            "probeResult": observation.probeResult,
            "panelHeight": observation.panelHeight,
            "panelWidth": observation.panelWidth,
            "derivedPanelHeight": observation.derivedPanelHeight,
            "providerCount": observation.providerCount,
            "providerBarMode": observation.providerBarMode,
            "previewVisible": searchController?.previewVisible ?? false,
            "items": observation.items.map {
                [
                    "id": $0.id,
                    "title": $0.title,
                    "subtitle": $0.subtitle ?? "",
                    "badge": $0.badge ?? "",
                    "group": $0.group ?? "",
                    "providerID": $0.providerID,
                    "actions": $0.actions.map { "\($0.id):\($0.title)" },
                    "hasPreview": $0.preview != nil,
                ]
            },
            "firstTitle": observation.items.first?.title ?? "",
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: dump,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: URL(fileURLWithPath: destination))
        } catch {
            recordScriptFailure("dump to \(destination) failed: \(error.localizedDescription)")
        }
    }

    /// NSApp.terminate always exits 0, so a failed script exits directly.
    private func finishScript() -> Never {
        let reasons = scriptFailureReasons
        if reasons.isEmpty && !scriptFailure {
            print("SCRIPT OK")
        } else {
            print("SCRIPT FAILED: \(reasons.joined(separator: " | "))")
        }
        fflush(stdout)
        fflush(stderr)
        exit(scriptFailure ? 1 : 0)
    }

    private func writeSnapshot(to destination: String) {
        guard let view = panel.panel.contentView else { return }
        write(view: view, to: destination)
    }

    /// The status menu's capture section as text, so a scripted run can prove
    /// the enable/disable rules without opening the menu.
    private func writeCaptureMenu(to destination: String) {
        let lines = CaptureMenuCommand.allCases.compactMap { command -> String? in
            guard let item = captureMenuItems[command] else { return nil }
            return "\(item.title)|enabled=\(item.isEnabled)|hidden=\(item.isHidden)"
        }
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: destination, atomically: true, encoding: .utf8)
        Log.shared.info("Capture menu written to \(destination)", source: "app")
    }

    private func writeSettingsSnapshot(to destination: String) {
        // Drop the blinking caret: focused text fields made snapshot diffs
        // flicker by a percent between runs.
        settingsWindow?.makeFirstResponder(nil)
        // A key window draws accent controls red and a background one grey;
        // hide the window first so a shell-launched run always captures the
        // same (background) look.
        settingsWindow?.orderOut(nil)
        guard let view = settingsWindow?.contentView else { return }
        write(view: view, to: destination)
        settingsWindow?.orderFrontRegardless()
    }

    private func writeOnboardingSnapshot(to destination: String) {
        guard let view = onboardingWindow?.contentView?.superview ?? onboardingWindow?.contentView else { return }
        write(view: view, to: destination)
    }

    private func write(view: NSView, to destination: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: destination))
            Log.shared.info("Snapshot written to \(destination)", source: "app")
        }
    }

    private func syntheticKey(_ token: String) -> NSEvent? {
        var flags: NSEvent.ModifierFlags = []
        var name = token.lowercased()
        for (prefix, flag) in [("cmd+", NSEvent.ModifierFlags.command), ("opt+", .option), ("shift+", .shift)] {
            if name.hasPrefix(prefix) {
                flags.insert(flag)
                name = String(name.dropFirst(prefix.count))
            }
        }
        let codes: [String: (UInt16, String)] = [
            "up": (126, "\u{F700}"), "down": (125, "\u{F701}"),
            "left": (123, "\u{F702}"), "right": (124, "\u{F703}"),
            "enter": (36, "\r"), "esc": (53, "\u{1B}"), "tab": (48, "\t"),
            "space": (49, " "), "comma": (43, ","), "k": (40, "k"),
            "r": (15, "r"), "w": (13, "w"), "s": (1, "s"), "o": (31, "o"), "c": (8, "c"),
            "1": (18, "1"), "2": (19, "2"), "3": (20, "3"),
            "4": (21, "4"), "5": (23, "5"), "6": (22, "6"),
            "7": (26, "7"), "8": (28, "8"), "9": (25, "9"),
        ]
        guard let (code, characters) = codes[name] else { return nil }
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.panel.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )
    }

    private func captureSnapshotIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let destination = environment["PALETTE_SNAPSHOT"] else { return }
        if let query = environment["PALETTE_QUERY"] {
            searchController.query = query
        }
        if environment["PALETTE_ACTIONS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.searchController.toggleActions()
            }
        }
        let delay = Double(environment["PALETTE_SNAPSHOT_DELAY"] ?? "") ?? 1.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.writeSnapshot(to: destination)
            if environment["PALETTE_EXIT_AFTER_SNAPSHOT"] == "1" {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A raw screencapture child outlives us unless we stop it here; SIGINT
        // lets it finalise the file before the app disappears.
        captureService.stopRecordingOnQuit()
        watcherTimer?.invalidate()
        clipboardMonitor?.stop()
        hotkeyManagers.values.forEach { $0.unregister() }
        // A draft that was never explicitly closed must survive the quit.
        searchController?.saveScratchpadOnTerminate()
        // Keep the clamshell flag: the next launch reads it back and shows the
        // real state. The root guard itself restores normal lid sleep when this
        // process disappears. The caffeinate child is left running on purpose.
        if let themeObserver {
            DistributedNotificationCenter.default().removeObserver(themeObserver)
        }
        let registry = self.registry
        Task { await registry?.shutdown() }
    }

    @objc private func handleWillPowerOff() {
        systemIsShuttingDown = true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Spotlight is off for these users, so quitting with the launcher open
        // would leave them with nothing. The first ⌘Q dismisses instead, unless
        // the system is logging out or restarting.
        guard !systemIsShuttingDown,
              panel?.isVisible == true || askWindow?.window?.isVisible == true else {
            return .terminateNow
        }
        panel?.hide(activatePrevious: false)
        askWindow?.close()
        Log.shared.info("Quit intercepted: dismissed the launcher instead", source: "app")
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.show()
        return true
    }

    // MARK: - Composition

    private func buildRegistry() -> ProviderRegistry {
        var diagnostics = startupDiagnostics
        var providers: [any PaletteProvider] = []

        providers.append(AppProvider(index: appIndex, launcher: launcher, bridge: hostProxy))
        providers.append(CalculatorProvider())
        providers.append(EmojiProvider())
        providers.append(ScratchpadProvider(store: store, bridge: hostProxy))
        providers.append(TerminalProvider())
        providers.append(KeepAwakeProvider(service: keepAwake, bridge: hostProxy, launcher: launcher))
        providers.append(TimerProvider(service: timerService, presetMinutes: configuration.timer.presets))
        providers.append(ColorProvider(bridge: hostProxy))
        providers.append(StatsProvider(bridge: hostProxy))
        providers.append(SSHProvider(launcher: launcher, terminalApp: configuration.terminalApp))
        let docker = DockerProvider(launcher: launcher, terminalApp: configuration.terminalApp, bridge: hostProxy)
        docker.onRefresh = { [weak self] in self?.searchController?.refreshResults() }
        providers.append(docker)
        providers.append(UnitsProvider(bridge: hostProxy))
        providers.append(WindowProvider(launcher: launcher))
        providers.append(ShotsProvider(service: captureService, bridge: hostProxy))
        providers.append(CheatsheetProvider(config: configuration.cheatsheets))
        let hideForCapture: @MainActor () -> Void = { [weak self] in
            self?.screenshotHUD.dismiss()
            self?.panel?.hide(activatePrevious: false)
        }
        providers.append(ShotProvider(
            service: captureService,
            bridge: hostProxy,
            lastScreenshot: { [weak self] in self?.lastScreenshotURL },
            beforeCapture: hideForCapture
        ))
        providers.append(RecProvider(
            service: captureService,
            startRequest: { [weak self] in self?.presentRecordingOptions() }
        ))
        providers.append(WebSearchProvider(
            engines: configuration.webSearchEngines,
            enabled: configuration.webSearchEnabled,
            launcher: launcher
        ))
        providers.append(PinProvider(store: store, bridge: hostProxy))
        providers.append(ClipboardProvider(store: store, bridge: hostProxy))
        providers.append(OCRProvider(
            store: store,
            bridge: hostProxy,
            lastScreenshot: { [weak self] in self?.lastScreenshotURL }
        ))
        let askService = AskService(store: store, configuration: configuration.ask)
        self.askService = askService
        providers.append(WebAppProvider(store: store, bridge: hostProxy, browser: configuration.webAppBrowser, favicons: configuration.window.favicons, onChange: { [weak self] in
            await self?.installHotKey()
        }))
        providers.append(BookmarkProvider())
        providers.append(AtlasProvider(bridge: hostProxy))
        providers.append(ZellijProvider(terminal: configuration.terminal, launcher: launcher, bridge: hostProxy))
        providers.append(PortProvider(launcher: launcher, bridge: hostProxy))
        providers.append(CommandProvider(launcher: launcher, bridge: hostProxy, terminal: configuration.terminal))
        providers.append(ProjectProvider(launcher: launcher, bridge: hostProxy, terminal: configuration.terminal))
        providers.append(RecentProvider(store: store, launcher: launcher, editor: configuration.editorOpenWith))
        providers.append(SnippetProvider(bridge: hostProxy))
        providers.append(GitProvider(launcher: launcher, bridge: hostProxy))
        for kind in GitHubKind.allCases {
            providers.append(GitHubProvider(
                kind: kind,
                launcher: launcher,
                bridge: hostProxy,
                terminalApp: configuration.terminalApp,
                terminal: configuration.terminal
            ))
        }
        for kind in BitwardenKind.allCases {
            providers.append(BitwardenProvider(
                kind: kind,
                vault: bitwardenVault,
                bridge: hostProxy,
                launcher: launcher,
                terminalApp: configuration.terminalApp
            ))
        }
        let themes = ThemeProvider(
            themesDirectory: paths.themesDir,
            launcher: launcher,
            onSelect: { [weak self] name in self?.pickTheme(name) },
            currentName: { [weak self] in self?.themeManager.currentThemeID ?? "" }
        )
        providers.append(themes)

        let system = SystemProvider(launcher: launcher, bridge: hostProxy)
        system.onReload = { [weak self] in self?.reload(quiet: false) }
        system.onOpenSettings = { [weak self] in self?.showSettings() }
        system.onOpenConfig = { [weak self] in self?.openConfig() }
        system.onOpenProviders = { [weak self] in self?.openProviders() }
        system.onQuit = { NSApp.terminate(nil) }
        providers.append(system)

        let bundledProviders = paths.bundledResources()?.appendingPathComponent("Providers", isDirectory: true)
        let manifests = ManifestLoader.load(bundled: bundledProviders, user: paths.providersDir)
        diagnostics.append(contentsOf: manifests.diagnostics)
        Log.shared.info("Loaded \(manifests.manifests.count) provider manifest(s): \(manifests.manifests.map(\.id).joined(separator: ", "))", source: "providers")
        for diagnostic in manifests.diagnostics {
            Log.shared.warn(diagnostic.message, source: diagnostic.source ?? "providers")
        }
        for manifest in manifests.manifests {
            if let provider = ManifestProviderFactory.make(
                manifest: manifest,
                configuration: configuration,
                launcher: launcher,
                host: hostProxy,
                cacheDirectory: paths.cacheDir,
                diagnostics: &diagnostics
            ) {
                providers.append(provider)
            }
        }

        allProviderInfo = providers.map {
            ProviderSettingsInfo(
                id: $0.descriptor.id,
                name: $0.descriptor.name,
                trigger: $0.descriptor.trigger,
                isGlobal: $0.descriptor.isGlobal,
                requirements: ProviderToolRequirements.requirements(for: $0),
                group: $0.descriptor.group
            )
        }
        let registry = ProviderRegistry(
            providers: providers,
            prefix: configuration.providerPrefix,
            aliases: configuration.providerAliases,
            order: configuration.providerOrder,
            disabled: configuration.disabledProviders,
            global: configuration.globalProviders,
            diagnostics: diagnostics
        )
        Log.shared.info("Registered providers: \(registry.providers.map { "\($0.descriptor.id)/\($0.descriptor.trigger ?? "-")" }.joined(separator: ", "))", source: "providers")
        for diagnostic in registry.diagnostics where diagnostic.level == .error {
            Log.shared.error(diagnostic.message, source: diagnostic.source ?? "providers")
        }
        catalogCommands = CommandCatalog.commands(
            providers: registry.providers.map {
                CommandCatalog.ProviderEntry(id: $0.descriptor.id, trigger: $0.descriptor.trigger)
            },
            prefix: configuration.providerPrefix
        )
        return registry
    }

    private func buildPanel() {
        let root = LauncherRootView(controller: searchController)
            .environmentObject(themeManager!)
        let hosting = NSHostingView(rootView: root)
        // Without this the hosting view resizes the panel to its content height,
        // which lets a long list grow the window past the bottom of the screen.
        hosting.sizingOptions = []
        let controller = PanelController(theme: themeManager.theme, content: hosting)
        controller.windowConfig = configuration.window
        controller.onKeyDown = { [weak self] event in
            self?.searchController.handleKey(event) ?? false
        }
        controller.onShow = { [weak self] in
            self?.searchController.panelDidShow()
        }
        controller.onHide = { [weak self] in
            self?.searchController.panelDidHide()
        }
        panel = controller
        controller.anchorOverride = configuration.searchPosition.rawValue
        searchController.panel = controller
    }

    private func wireControllerCallbacks() {
        searchController.onReload = { [weak self] in self?.reload(quiet: false) }
        searchController.onOpenConfig = { [weak self] in self?.showSettings() }
        searchController.onOpenProviders = { [weak self] in self?.openProviders() }
        searchController.onQuit = { NSApp.terminate(nil) }
    }

    /// Scripted runs drive the controller directly; Carbon hotkeys would grab
    /// ⌘⇧3/4/5/6 and fight the test host.
    private var isScriptMode: Bool {
        ProcessInfo.processInfo.environment["PALETTE_SCRIPT"] != nil
    }

    /// Scripted runs skip Carbon by default. The opt-in exists so a snapshot
    /// can prove the unavailable rows Settings draws for a real registration.
    private var registersGlobalHotKeys: Bool {
        !isScriptMode || ProcessInfo.processInfo.environment["PALETTE_FORCE_HOTKEYS"] == "1"
    }

    private func installHotKey() {
        guard registersGlobalHotKeys else { return }
        hotKeyInstallTask?.cancel()
        hotKeyInstallTask = Task { [weak self] in
            guard let self else { return }
            let apps = (try? await self.store.webApps()) ?? []
            guard !Task.isCancelled else { return }
            self.applyHotKeys(webApps: apps)
        }
    }

    /// One ordered pass: built-ins, web apps, `[[binding]]`, catalogue. A later
    /// duplicate loses to the earlier owner, so launch, ⌘R and a web-app change
    /// all resolve the same way. Registration failures (another app owns the
    /// key) land in `HotKeyRegistry` for Settings.
    private func applyHotKeys(webApps: [WebApp]) {
        guard registersGlobalHotKeys else { return }
        hotkeyManagers.values.forEach { $0.unregister() }
        hotkeyManagers.removeAll()
        currentHotKey = nil

        struct Desired {
            var id: String
            var label: String
            var keys: String
            var press: () -> Void
            var isLauncher = false
        }

        var desired: [Desired] = [
            Desired(id: "launcher", label: "Launcher shortcut", keys: configuration.hotkey,
                    press: { [weak self] in self?.togglePalette() }, isLauncher: true),
            Desired(id: "clipboard", label: "Clipboard shortcut", keys: configuration.clipboardHotkey,
                    press: { [weak self] in self?.showClipboard() }),
            Desired(id: "terminal", label: "Terminal shortcut", keys: configuration.terminalHotkey,
                    press: { [weak self] in self?.toggleTerminalPanel() }),
            Desired(id: "scratchpad", label: "Scratchpad list shortcut", keys: configuration.scratchpadHotkey,
                    press: { [weak self] in self?.toggleScratchpad() }),
            Desired(id: "ask", label: "Ask shortcut", keys: configuration.askHotkey,
                    press: { [weak self] in self?.toggleAskWindow() }),
            Desired(id: "screen", label: "Screen shortcut", keys: configuration.screenshotHotkey,
                    press: { [weak self] in self?.captureScreenshot() }),
            Desired(id: "region", label: "Region shortcut", keys: configuration.regionScreenshotHotkey,
                    press: { [weak self] in self?.captureScreenshot(mode: .region) }),
            Desired(id: "window", label: "Window shortcut", keys: configuration.windowScreenshotHotkey,
                    press: { [weak self] in self?.captureScreenshot(mode: .window) }),
            Desired(id: "recording", label: "Recording shortcut", keys: configuration.recordingHotkey,
                    press: { [weak self] in self?.toggleRecording() }),
        ]

        for app in webApps {
            guard let raw = app.shortcut, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let browser = configuration.webAppBrowser
            Log.shared.info("Web app hotkey target: \(app.name) → \(browser.isEmpty ? "system default" : browser)", source: "hotkey")
            desired.append(Desired(id: "web:\(app.id)", label: app.name, keys: raw,
                                   press: { [weak self] in self?.launcher.openWebApp(app.url, browser: browser) }))
        }

        for (index, binding) in configuration.bindings.enumerated() {
            let keys = binding.keys.trimmingCharacters(in: .whitespaces)
            guard !keys.isEmpty else { continue }
            let value = binding.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                Log.shared.warn("Binding '\(keys)' skipped: keys and a value are required.", source: "hotkey")
                continue
            }
            desired.append(Desired(id: "binding-\(index)", label: "Custom hotkey \(index + 1)", keys: keys,
                                   press: { [weak self] in self?.performBinding(binding) }))
        }

        let byID = Dictionary(uniqueKeysWithValues: catalogCommands.map { ($0.id, $0) })
        for shortcut in configuration.shortcuts {
            let keys = shortcut.keys.trimmingCharacters(in: .whitespaces)
            guard !keys.isEmpty else { continue }
            guard let command = byID[shortcut.command] else {
                Log.shared.warn("Shortcut '\(shortcut.command)' skipped: unknown command.", source: "hotkey")
                continue
            }
            desired.append(Desired(id: shortcut.command, label: command.title, keys: keys,
                                   press: { [weak self] in self?.performCatalogCommand(command) }))
        }

        let plan = HotKeyPlan.resolve(desired.map {
            HotKeyRequest(id: $0.id, label: $0.label, keys: $0.keys)
        })
        var statuses: [HotKeyStatus] = []
        var nextID: UInt32 = 1
        for (index, result) in plan.enumerated() {
            let item = desired[index]
            guard !result.request.keys.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let unavailable = result.unavailable {
                statuses.append(HotKeyStatus(id: item.id, label: item.label, keys: item.keys, unavailable: unavailable))
                Log.shared.warn("Hotkey \(item.keys) for \(item.label): \(unavailable)", source: "hotkey")
                continue
            }
            let manager = HotKeyManager(hotKeyID: nextID)
            nextID += 1
            manager.onPressed = item.press
            do {
                let spec = try manager.register(item.keys)
                hotkeyManagers[item.id] = manager
                statuses.append(HotKeyStatus(id: item.id, label: item.label, keys: item.keys))
                if item.isLauncher { currentHotKey = spec }
                Log.shared.info("Hotkey registered: \(spec.prettyDisplay) → \(item.label)", source: "hotkey")
            } catch {
                statuses.append(HotKeyStatus(
                    id: item.id, label: item.label, keys: item.keys, unavailable: HotKeyUnavailable.anotherApp
                ))
                Log.shared.warn(
                    "Hotkey \(item.keys) for \(item.label) is unavailable: \(error.localizedDescription)",
                    source: "hotkey"
                )
                if item.isLauncher {
                    startupDiagnostics.append(Diagnostic(.error, error.localizedDescription, source: "hotkey"))
                    searchController?.setStatus("Hotkey unavailable: \(error.localizedDescription)", duration: nil)
                }
            }
        }
        HotKeyRegistry.replaceAll(statuses)
    }

    private func performCatalogCommand(_ command: CatalogCommand) {
        switch command.action {
        case .provider(let trigger):
            let prefix = configuration.providerPrefix
            panel.show()
            searchController.query = trigger.hasPrefix(prefix) ? trigger : prefix + trigger
        case .app(let app):
            switch app {
            case .settings: showSettings()
            case .reload: reload(quiet: false)
            case .quit: NSApp.terminate(nil)
            case .toggleLauncher: togglePalette()
            }
        }
    }

    private func performBinding(_ binding: HotkeyBinding) {
        switch binding.action {
        case .launch:
            launchBindingTarget(binding.value)
        case .command:
            runBindingCommand(binding.value)
        case .provider:
            let prefix = configuration.providerPrefix
            let trigger = binding.value.hasPrefix(prefix) ? binding.value : prefix + binding.value
            panel.show()
            searchController.query = trigger
        case .url:
            launcher.openURL(binding.value)
        }
    }

    private func launchBindingTarget(_ target: String) {
        if let url = URL(string: target), let scheme = url.scheme, !scheme.isEmpty {
            NSWorkspace.shared.open(url)
            return
        }
        if target.contains("/") {
            let expanded = PathExpansion.expand(target)
            guard FileManager.default.fileExists(atPath: expanded) else {
                Log.shared.warn("Binding launch target not found: \(target)", source: "binding")
                return
            }
            launcher.activateApp(path: expanded)
            return
        }
        guard let path = ToolLocator.shared.appPath(named: target) else {
            Log.shared.warn("Binding launch app not installed: \(target)", source: "binding")
            return
        }
        launcher.activateApp(path: path)
    }

    /// Runs `/bin/zsh -lc <command>` with no terminal and no inherited pipes.
    /// stderr goes to a temp file so a failed command can be reported in the log
    /// without blocking the child on a full pipe.
    private func runBindingCommand(_ command: String) {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-binding-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let errorLog = try? FileHandle(forWritingTo: logURL) else {
            Log.shared.warn("Binding command could not open its log: \(command)", source: "binding")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorLog
        process.terminationHandler = { finished in
            try? errorLog.close()
            defer { try? FileManager.default.removeItem(at: logURL) }
            guard finished.terminationStatus != 0 else { return }
            let output = (try? String(contentsOf: logURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = output.isEmpty ? command : String(output.suffix(600))
            Log.shared.error(
                "Binding command failed (\(finished.terminationStatus)): \(detail)",
                source: "binding"
            )
        }
        do {
            try process.run()
        } catch {
            try? errorLog.close()
            try? FileManager.default.removeItem(at: logURL)
            Log.shared.error("Binding command could not start: \(error.localizedDescription)", source: "binding")
        }
    }

    // MARK: - Capture actions

    /// Runs a capture with the launcher left open and key: the screenshot should
    /// include it, and `screencapture -i` must not look like the user clicked
    /// away. If the capture opens the annotator or a recording preview, that
    /// window keeps the focus instead of the launcher.
    private func captureKeepingPanel(_ body: @MainActor () async -> Void) async {
        let editorsBefore = annotateWindows.count + mediaPreviews.count
        let wasVisible = panel?.isVisible == true
        let previousSuppress = panel?.suppressAutoHide ?? false
        if wasVisible { panel?.suppressAutoHide = true }
        await body()
        if wasVisible,
           annotateWindows.count + mediaPreviews.count == editorsBefore,
           let panel {
            // The capture can trigger a system permission dialog and hide the
            // panel. show() also restores PanelController's own state, which
            // makeKeyAndOrderFront alone does not.
            if panel.isVisible {
                if !panel.panel.isKeyWindow { panel.panel.makeKeyAndOrderFront(nil) }
            } else {
                panel.show()
            }
        }
        panel?.suppressAutoHide = previousSuppress
    }

    private func captureScreenshot(mode: CaptureMode = .screen) {
        // A thumbnail from an earlier shot must not end up in this one.
        screenshotHUD.dismiss()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.captureKeepingPanel {
                do {
                    let result = try await self.captureService.screenshot(mode)
                    // The service reports a saved file itself; a copy-only shot
                    // has nothing on disk to name.
                    if !FileManager.default.fileExists(atPath: result.url.path) {
                        self.captureFeedback("Screenshot copied")
                    }
                } catch CaptureError.cancelled {
                    self.captureFeedback("Screenshot cancelled")
                } catch {
                    Log.shared.error("Screenshot failed: \(error.localizedDescription)", source: "capture")
                    self.captureFeedback("Screenshot failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// One place every capture action reports through: the panel when it is
    /// open, a banner and the menu-bar item when it is not.
    private func captureFeedback(_ message: String) {
        guard !message.isEmpty else { return }
        if panel?.isVisible == true {
            searchController.setStatus(message, duration: 4)
        } else {
            SystemNotification.post(title: "Palette", body: message)
            flashMenuBar(message)
        }
        Log.shared.info("Capture feedback: \(message)", source: "capture")
    }

    /// Keeps a short status visible in the menu bar while the panel is closed.
    private func flashMenuBar(_ message: String) {
        guard let button = statusItem?.button else { return }
        let text = message.count > 40 ? String(message.prefix(39)) + "…" : message
        menuBarFlashTask?.cancel()
        statusItem.length = NSStatusItem.variableLength
        button.title = " " + text
        button.toolTip = message
        menuBarFlashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.statusItem.length = NSStatusItem.squareLength
            self.statusItem.button?.title = ""
            self.statusItem.button?.toolTip = self.statusToolTip
        }
    }

    private var statusToolTip: String {
        "Palette — \(currentHotKey?.prettyDisplay ?? configuration.hotkey)"
    }

    /// Hotkey and `/rec` both land here: ask for audio, microphone, display and
    /// area before anything is recorded.
    private func presentRecordingOptions() {
        guard !captureService.isRecording else { return }
        if let existing = recordingOptionsPanel {
            recordingOptionsPanel = nil
            existing.discard()
        }
        let capture = captureService.config
        let controller = RecordingOptionsPanelController(
            options: RecordingOptions(capture: capture),
            displays: CaptureDisplays.active(),
            microphones: CaptureMicrophones.active(),
            format: capture.recordingFormat,
            themeManager: themeManager,
            onRecord: { [weak self] options in self?.beginRecording(options) },
            onCancel: { [weak self] in
                self?.recordingOptionsPanel = nil
                self?.captureFeedback("Recording cancelled")
            }
        )
        recordingOptionsPanel = controller
        // The launcher shares the screen with whatever is about to be recorded.
        panel?.hide(activatePrevious: false)
        controller.show()
    }

    private func beginRecording(_ options: RecordingOptions) {
        var capture = captureService.config
        options.apply(to: &capture)
        // Writing through the service persists the choice for the next press.
        captureService.config = capture
        recordingOptionsPanel?.discard()
        recordingOptionsPanel = nil
        // The confirmation thumbnail and the options panel must be gone before
        // screencapture looks at the screen.
        screenshotHUD.dismiss()
        if capture.hidePalette { panel?.hide(activatePrevious: false) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // One turn of the run loop plus a beat: closing a panel is not
            // synchronous with the window server.
            await Task.yield()
            try? await Task.sleep(nanoseconds: 200_000_000)
            do {
                try self.captureService.startRecording()
                self.startRecordingTicker()
            } catch {
                Log.shared.error("Recording failed: \(error.localizedDescription)", source: "capture")
                self.captureFeedback("Recording failed: \(error.localizedDescription)")
            }
            self.updateCaptureMenu()
        }
    }

    private func toggleRecording() {
        if captureService.isRecording {
            stopRecording()
        } else {
            presentRecordingOptions()
        }
    }

    private func stopRecording() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.captureService.stopRecording()
            } catch {
                Log.shared.error("Recording failed: \(error.localizedDescription)", source: "capture")
                self.captureFeedback("Recording failed: \(error.localizedDescription)")
            }
            self.recordingTicker?.invalidate()
            self.recordingTicker = nil
            self.updateCaptureMenu()
        }
    }

    private func startRecordingTicker() {
        recordingTicker?.invalidate()
        recordingTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateCaptureMenu() }
        }
    }

    // MARK: - Last capture

    private func rememberCapture(_ url: URL, recording: Bool) {
        lastCaptureURL = url
        if recording {
            lastRecordingURL = url
        } else {
            lastScreenshotURL = url
        }
        updateCaptureMenu()
    }

    private func copyLastPath() {
        guard let url = lastCaptureURL, FileManager.default.fileExists(atPath: url.path) else {
            captureFeedback("No capture to copy")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
        ClipboardMonitor.notePaletteWrite(pasteboard.changeCount)
        captureFeedback("Path copied")
    }

    private func revealLastCapture() {
        guard let url = lastCaptureURL else {
            captureFeedback("No capture to reveal")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        captureFeedback("Revealed \(url.lastPathComponent) in Finder")
    }

    private func showLastRecording() {
        guard let url = lastRecordingURL, FileManager.default.fileExists(atPath: url.path) else {
            captureFeedback("The last recording is no longer on disk")
            return
        }
        openMediaPreview(url)
    }

    private func showLastScreenshot() {
        guard let url = lastScreenshotURL, FileManager.default.fileExists(atPath: url.path) else {
            captureFeedback("The last screenshot is no longer on disk")
            return
        }
        openAnnotator(url)
    }

    /// On-device Vision read of the last screenshot, shared by the two menu
    /// commands. Nothing is uploaded.
    private func copyTextFromLastScreenshot() {
        Task { @MainActor in
            guard let recognition = await lastScreenshotText() else { return }
            guard !recognition.text.isEmpty else {
                captureFeedback("No text found")
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(recognition.text, forType: .string)
            ClipboardMonitor.notePaletteWrite(pasteboard.changeCount)
            captureFeedback("Text copied (\(recognition.text.count) chars)")
        }
    }

    private func openLastScreenshotLink() {
        Task { @MainActor in
            guard let recognition = await lastScreenshotText() else { return }
            guard let raw = recognition.firstLink,
                  ImageTextRecognition.isOpenable(raw),
                  let url = URL(string: raw) else {
                captureFeedback("No link found")
                return
            }
            NSWorkspace.shared.open(url)
            captureFeedback("Opened \(url.host ?? raw)")
        }
    }

    private func lastScreenshotText() async -> RecognizedImageText? {
        guard let url = lastScreenshotURL, FileManager.default.fileExists(atPath: url.path) else {
            captureFeedback("The last screenshot is no longer on disk")
            return nil
        }
        guard let image = NSImage(contentsOf: url) else {
            captureFeedback("Could not read \(url.lastPathComponent)")
            return nil
        }
        do {
            return try await ImageTextRecognition.recognize(image)
        } catch {
            captureFeedback("Text recognition failed")
            return nil
        }
    }

    // MARK: - Annotate and preview

    /// Palette is a menu-bar app. Editing and preview windows need a Dock icon
    /// and a normal app menu, so the policy follows them and nothing else —
    /// scanning NSApp.windows used to leave the Dock icon behind whenever any
    /// other window happened to be visible.
    private func updateActivationPolicy() {
        let askNeedsDock = askWindow?.window?.isVisible == true
            || askWindow?.isStreaming == true
            || (NSApp.dockTile.badgeLabel?.isEmpty == false)
        let editing = !annotateWindows.isEmpty || !mediaPreviews.isEmpty || askNeedsDock
        let policy: NSApplication.ActivationPolicy = editing ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        Log.shared.info("Activation policy: \(editing ? "regular" : "accessory")", source: "app")
    }

    private func openAnnotator(_ url: URL) {
        Log.shared.info("Annotator: opening \(url.path)", source: "capture")
        guard let image = NSImage(contentsOf: url) else {
            Log.shared.error("Annotator: could not read \(url.path)", source: "capture")
            Task { await searchController.notify("Could not open \(url.lastPathComponent) for editing") }
            return
        }
        let controller = AnnotateWindowController(image: image, url: url, themeManager: themeManager)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.annotateWindows.removeAll { $0 === controller }
            self.updateActivationPolicy()
        }
        annotateWindows.append(controller)
        updateActivationPolicy()
        Log.shared.info("Annotator: window \(annotateWindows.count) open", source: "capture")
        controller.show()
    }

    /// Headless check of the annotator: draws every shape, crops, and writes
    /// the result. Used by the script runner, not by the UI.
    private func annotateExport(_ spec: String) {
        let parts = spec.split(separator: "|").map(String.init)
        guard parts.count == 2, let image = NSImage(contentsOfFile: parts[0]) else {
            Log.shared.error("annotate_export needs source|destination", source: "capture")
            return
        }
        let editor = AnnotationEditor(image: image, url: nil)
        editor.add(.arrow(
            from: CGPoint(x: 0.1, y: 0.1),
            to: CGPoint(x: 0.4, y: 0.35),
            color: .systemRed,
            width: 0.004
        ))
        editor.add(.rectangle(
            rect: CGRect(x: 0.5, y: 0.1, width: 0.3, height: 0.2),
            color: .systemBlue,
            width: 0.004
        ))
        editor.color = .systemYellow
        editor.textSize = 0.06
        editor.addText(at: CGPoint(x: 0.1, y: 0.6), text: "Palette")
        editor.crop(to: CGRect(x: 0.05, y: 0.05, width: 0.8, height: 0.8))
        guard let data = editor.renderedPNG() else {
            Log.shared.error("annotate_export could not encode", source: "capture")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: parts[1]))
            Log.shared.info("Annotated sample written to \(parts[1])", source: "capture")
        } catch {
            Log.shared.error("annotate_export failed: \(error.localizedDescription)", source: "capture")
        }
    }

    /// Posts a real mouse drag into the annotator window. System-wide synthetic
    /// input needs Accessibility, but a window can always send itself events,
    /// and SwiftUI handles them exactly like a user's drag.
    private func simulateDrag(_ spec: String) async -> Int {
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return 0 }
        guard let window = annotateWindows.last?.window, let view = window.contentView else {
            Log.shared.error("ui_drag: no annotator window", source: "capture")
            return 0
        }
        let size = view.bounds.size
        func point(_ fx: Double, _ fy: Double) -> NSPoint {
            NSPoint(x: fx * size.width, y: (1 - fy) * size.height)
        }
        let start = point(parts[0], parts[1])
        let end = point(parts[2], parts[3])

        func send(_ type: NSEvent.EventType, _ location: NSPoint) {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else { return }
            // The run loop routes it like a real click; sendEvent alone misses
            // SwiftUI's gesture monitor.
            NSApp.postEvent(event, atStart: false)
        }

        window.makeKey()
        send(.leftMouseDown, start)
        try? await Task.sleep(nanoseconds: 50_000_000)
        for step in 1...10 {
            let t = Double(step) / 10
            send(.leftMouseDragged, NSPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            ))
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        send(.leftMouseUp, end)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let count = annotationShapeCount()
        Log.shared.info("ui_drag: \(spec) -> \(count) shape(s)", source: "capture")
        return count
    }

    private func annotationShapeCount() -> Int {
        annotateWindows.last?.shapeCount ?? 0
    }

    /// Sound plus a brief thumbnail: a capture must never look like nothing
    /// happened.
    private func confirmCapture(_ url: URL) {
        if configuration.capture.captureSound {
            NSSound(named: NSSound.Name("Tink"))?.play()
        }
        guard configuration.capture.captureThumbnail,
              let image = NSImage(contentsOf: url) else { return }
        screenshotHUD.show(image: image, title: url.lastPathComponent, theme: themeManager.theme) { [weak self] in
            self?.openAnnotator(url)
        }
    }

    private func openMediaPreview(_ url: URL) {
        // One preview at a time: a new recording replaces the old window
        // instead of stacking a second player exactly on top of it.
        let previous = mediaPreviews
        mediaPreviews.removeAll()
        for controller in previous { controller.close() }
        let controller = MediaPreviewWindowController(url: url, themeManager: themeManager)
        controller.onFeedback = { [weak self] message in self?.captureFeedback(message) }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.mediaPreviews.removeAll { $0 === controller }
            self.updateActivationPolicy()
        }
        mediaPreviews.append(controller)
        updateActivationPolicy()
        controller.show()
    }

    /// Opens the single ask chat window. A question starts a fresh chat; an
    /// empty question re-shows the existing transcript.
    private func showAskWindow(question: String, model: AskModel? = nil) {
        guard let askService else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, let existing = askWindow {
            let panelFrame = panel?.isVisible == true ? panel?.panel.frame : nil
            existing.show(below: panelFrame)
            updateActivationPolicy()
            return
        }
        if let existing = askWindow {
            existing.close()
            askWindow = nil
        }
        panel?.suppressAutoHide = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let selected = if let model { model } else { await askService.selectedModel() }
            let controller = AskWindowController(
                service: askService,
                question: trimmed,
                model: selected,
                themeManager: self.themeManager,
                notify: self.configuration.ask.notify,
                webSearch: self.configuration.ask.webSearch,
                onOpenSettings: { [weak self] in self?.openAskSettingsFromWindow() }
            )
            controller.onClose = { [weak self] in
                guard let self else { return }
                self.panel?.suppressAutoHide = self.askWindow?.window?.isVisible == true
                self.updateActivationPolicy()
            }
            controller.onStatusChange = { [weak self] in
                guard let self else { return }
                self.panel?.suppressAutoHide = self.askWindow?.window?.isVisible == true
                self.updateActivationPolicy()
            }
            self.askWindow = controller
            self.updateActivationPolicy()
            let panelFrame = self.panel?.isVisible == true ? self.panel?.panel.frame : nil
            controller.show(below: panelFrame)
            // Reopening with no question restores the last chat instead of an
            // empty transcript.
            if trimmed.isEmpty,
               let lastID = await askService.lastChatID(),
               let chat = (try? await askService.chats(limit: 200))?
                   .first(where: { $0.id == lastID }) {
                controller.open(chat: chat)
            }
        }
    }

    /// ⌘⌥A: show the existing chat or hide it. Hiding never cancels a request.
    private func toggleAskWindow() {
        if let controller = askWindow, let window = controller.window, window.isMiniaturized {
            let panelFrame = panel?.isVisible == true ? panel?.panel.frame : nil
            controller.show(below: panelFrame)
            updateActivationPolicy()
            return
        }
        if let controller = askWindow, let window = controller.window, window.isVisible {
            window.orderOut(nil)
            panel?.suppressAutoHide = false
            updateActivationPolicy()
            return
        }
        if let existing = askWindow {
            let panelFrame = panel?.isVisible == true ? panel?.panel.frame : nil
            existing.show(below: panelFrame)
            updateActivationPolicy()
            return
        }
        showAskWindow(question: "")
    }

    @objc private func showAskWindowFromMenu() {
        toggleAskWindow()
    }

    private func showAboutWindow() {
        if aboutWindow == nil {
            aboutWindow = AboutWindowController(themeManager: themeManager)
        }
        aboutWindow?.show()
    }

    @objc private func showAboutWindowFromMenu() {
        showAboutWindow()
    }

    /// Opens the Nth saved chat in the current ask window. Script-only hook so
    /// the relaunch test can restore a transcript without mouse input.
    private func openSavedChat(at index: Int) {
        guard let askService, let controller = askWindow else { return }
        Task { @MainActor in
            guard let chats = try? await askService.chats(limit: 200),
                  chats.indices.contains(index) else { return }
            controller.open(chat: chats[index])
        }
    }

    /// Capture windows outlive theme changes; their SwiftUI content observes the
    /// theme manager, but the AppKit window chrome needs this nudge.
    private func applyThemeToCaptureWindows(_ theme: Theme) {
        onboardingWindow?.appearance = theme.nsAppearance
        onboardingWindow?.backgroundColor = theme.nsColor(theme.palette.bg)
        for controller in annotateWindows { controller.apply(theme: theme) }
        for controller in mediaPreviews { controller.apply(theme: theme) }
        askWindow?.apply(theme: theme)
        aboutWindow?.apply(theme: theme)
    }

    @objc private func captureMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = CaptureMenuCommand(rawValue: raw) else { return }
        switch command {
        case .startRecording:
            presentRecordingOptions()
        case .stopRecording:
            stopRecording()
        case .copyLastPath:
            copyLastPath()
        case .revealLastCapture:
            revealLastCapture()
        case .showLastRecording:
            showLastRecording()
        case .showLastScreenshot:
            showLastScreenshot()
        case .copyTextFromLastScreenshot:
            copyTextFromLastScreenshot()
        case .openLastScreenshotLink:
            openLastScreenshotLink()
        }
    }

    /// Keeps the menu bar honest about a running recording and about the last
    /// capture, using the same rules the tests pin.
    private func updateCaptureMenu() {
        let states = CaptureMenu.items(
            isRecording: captureService.isRecording,
            elapsed: captureService.recordingElapsed,
            lastCapturePath: lastCaptureURL?.path,
            lastRecordingPath: lastRecordingURL?.path,
            lastScreenshotPath: lastScreenshotURL?.path
        )
        for state in states {
            guard let item = captureMenuItems[state.command] else { continue }
            item.title = state.title
            item.isEnabled = state.enabled
            item.isHidden = !state.visible
        }
    }

    private func toggleTerminalPanel() {
        guard let controller = searchController else { return }
        if controller.terminalActive {
            controller.closeTerminalPanel()
            return
        }
        if controller.scratchpadActive {
            controller.closeScratchpad(save: true)
        }
        controller.openTerminalPanel()
    }

    private func toggleScratchpad() {
        guard let controller = searchController else { return }
        switch HotkeyTargets.scratchpadAction(
            panelVisible: panel?.isVisible == true,
            listActive: controller.scratchpadListActive
        ) {
        case .hide:
            panel?.hide()
        case .showList:
            controller.openScratchpadList()
        }
    }

    private func configureClipboard() {
        guard !isScriptMode, configuration.clipboard.enabled else {
            clipboardMonitor?.stop()
            clipboardMonitor = nil
            return
        }
        let store = store!
        let limit = configuration.clipboard.maxEntries
        // A reload (including every Settings keystroke) must not drop a copy
        // that landed while the config was being applied, so an existing
        // monitor keeps its last change count.
        let monitor = clipboardMonitor ?? ClipboardMonitor()
        let controller = searchController
        monitor.onCapture = { capture in
            Task {
                switch capture {
                case .text(let text):
                    _ = try? await store.insertClipboard(text: text, maxEntries: limit)
                case .image(let png, let thumbnail, let width, let height):
                    _ = try? await store.insertClipboardImage(
                        png: png,
                        thumbnail: thumbnail,
                        width: width,
                        height: height,
                        maxEntries: limit
                    )
                case .files(let paths, let thumbnail):
                    _ = try? await store.insertClipboardFiles(
                        paths: paths,
                        thumbnail: thumbnail,
                        maxEntries: limit
                    )
                }
                await MainActor.run {
                    controller?.clipboardDidChange()
                }
            }
        }
        monitor.start(intervalMs: configuration.clipboard.pollMs, preserveChangeCount: clipboardMonitor != nil)
        clipboardMonitor = monitor
    }

    private func providerSettingsInfo() -> [ProviderSettingsInfo] {
        registry.providers.map {
            ProviderSettingsInfo(
                id: $0.descriptor.id,
                name: $0.descriptor.name,
                trigger: $0.descriptor.trigger,
                isGlobal: $0.descriptor.isGlobal,
                group: $0.descriptor.group
            )
        }
    }

    /// Skip means "Essentials", not "everything": the user declined setup, so
    /// keep the rail to the same small set Finish would.
    private func skipOnboarding() {
        let essentials = OnboardingView.applying(
            .essentials,
            to: configuration,
            providers: providerSettingsInfo()
        )
        do {
            try writeConfig(essentials)
        } catch {
            Log.shared.warn("Could not save the Essentials preset: \(error.localizedDescription)", source: "onboarding")
        }
        if !isScriptMode {
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        }
        onboardingWindow?.close()
        onboardingWindow = nil
        reload(quiet: false)
    }

    private func showOnboardingIfNeeded() {
        guard shouldShowOnboarding else { return }
        let view = OnboardingView(
            themeManager: themeManager,
            config: configuration,
            providers: providerSettingsInfo(),
            onFinish: { [weak self] updated in
                guard let self else { return }
                do {
                    try self.writeConfig(updated)
                } catch {
                    self.searchController.setStatus("Could not save setup: \(error.localizedDescription)", duration: 4)
                }
                if !self.isScriptMode {
                    UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                }
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
                self.reload(quiet: false)
            },
            onSkip: { [weak self] in self?.skipOnboarding() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set up Palette"
        window.appearance = themeManager.theme.nsAppearance
        // A clear background left the title bar area blank; match the content.
        window.isOpaque = false
        window.backgroundColor = themeManager.theme.nsColor(themeManager.theme.palette.bg)
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        onboardingWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func seedCommandsFile() {
        let file = paths.configDir.appendingPathComponent("commands.toml")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
            try CommandProvider.example.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            Log.shared.warn("Could not seed commands.toml: \(error.localizedDescription)", source: "providers")
        }
    }

    private func seedBookmarksFile() {
        let file = paths.bookmarksFile
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
            try BookmarkProvider.example.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            Log.shared.warn("Could not seed bookmarks.toml: \(error.localizedDescription)", source: "providers")
        }
    }

    private func registerLoginItemOnFirstLaunch() {
        // Seed once: after this the Settings toggle owns the login item, so
        // turning it off sticks.
        let bundlePath = Bundle.main.bundlePath
        let isInstalled = bundlePath.hasPrefix("/Applications/")
            || bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
        // A debug build must never become the login item or consume the seed.
        guard isInstalled else {
            Log.shared.info("Login item left alone: Palette is not running from /Applications", source: "app")
            return
        }
        let seeded = "loginItemSeeded"
        if !UserDefaults.standard.bool(forKey: seeded) {
            UserDefaults.standard.set(true, forKey: seeded)
            // mainApp reports .notFound until it has been registered at least once.
            if SMAppService.mainApp.status == .enabled {
                UserDefaults.standard.set(bundlePath, forKey: Self.loginItemPathKey)
            } else {
                do {
                    try SMAppService.mainApp.register()
                    UserDefaults.standard.set(bundlePath, forKey: Self.loginItemPathKey)
                    Log.shared.info("Registered login item to \(bundlePath)", source: "app")
                } catch {
                    Log.shared.warn("Could not register login item: \(error.localizedDescription)", source: "app")
                }
            }
        }
        reconcileLoginItem(currentPath: bundlePath)
    }

    private static let loginItemPathKey = "loginItemBundlePath"

    /// A login item can outlive the bundle it points at (a deleted worktree
    /// build). Re-register the running /Applications copy when the recorded
    /// path is different or gone; otherwise leave the user's setting alone.
    private func reconcileLoginItem(currentPath: String) {
        switch SMAppService.mainApp.status {
        case .enabled:
            break
        case .requiresApproval:
            Log.shared.info("Login item needs approval in System Settings; leaving it alone", source: "app")
            return
        default:
            Log.shared.info("Login item is off; leaving it alone", source: "app")
            return
        }
        guard let recorded = UserDefaults.standard.string(forKey: Self.loginItemPathKey)
            ?? recordedLoginItemPath() else {
            Log.shared.warn(
                "Login item is on but its recorded path is unknown; re-registering \(currentPath)",
                source: "app"
            )
            refreshLoginItem(currentPath: currentPath)
            return
        }
        UserDefaults.standard.set(recorded, forKey: Self.loginItemPathKey)
        if recorded == currentPath {
            Log.shared.info("Login item already points at \(currentPath)", source: "app")
            return
        }
        if FileManager.default.fileExists(atPath: recorded) {
            Log.shared.warn(
                "Login item points at \(recorded); re-registering \(currentPath)",
                source: "app"
            )
        } else {
            Log.shared.warn(
                "Login item points at a missing bundle \(recorded); re-registering \(currentPath)",
                source: "app"
            )
        }
        refreshLoginItem(currentPath: currentPath)
    }

    private func refreshLoginItem(currentPath: String) {
        // The login item stores the path LaunchServices resolves for the bundle
        // id. Repointing it first stops a stale worktree path from sticking.
        refreshLaunchServicesRecord(bundlePath: currentPath)
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            Log.shared.warn("Could not unregister the stale login item: \(error.localizedDescription)", source: "app")
        }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(currentPath, forKey: Self.loginItemPathKey)
            Log.shared.info("Login item now points at \(currentPath)", source: "app")
        } catch {
            Log.shared.warn("Could not register the login item: \(error.localizedDescription)", source: "app")
        }
    }

    /// `lsregister -f` re-associates the bundle id with this copy, which is what
    /// the background-task record follows after a worktree build is deleted.
    private func refreshLaunchServicesRecord(bundlePath: String) {
        let tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-f", bundlePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.shared.warn("Could not refresh the LaunchServices record: \(error.localizedDescription)", source: "app")
        }
    }

    /// Reads the path the system has on file. `SMAppService` does not expose it,
    /// so ask the same tool support uses to diagnose login items.
    private func recordedLoginItemPath() -> String? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sfltool")
        process.arguments = ["dumpbtm"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let identifier = "2." + bundleID
        var currentIdentifier: String?
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Identifier: ") {
                currentIdentifier = String(trimmed.dropFirst("Identifier: ".count))
            } else if trimmed.hasPrefix("URL: "), currentIdentifier == identifier {
                let path = String(trimmed.dropFirst("URL: ".count))
                return path == "(null)" ? nil : path
            }
        }
        return nil
    }

    // MARK: - First-run prompts

    /// One-time consent for the whole-home walk. A dismissed prompt means "no"
    /// until the user opts in from Settings; the narrow scopes still prewarm.
    private func askForHomeIndexingConsent(registry: ProviderRegistry) -> Bool {
        if let consent = configuration.indexingHomeConsent { return consent }
        let usesHome = registry.providers.contains { provider in
            guard let paths = provider as? PathsProvider else { return false }
            return paths.indexesHomeFolder
        }
        guard usesHome, !isScriptMode, !shouldShowOnboarding else { return false }
        let alert = NSAlert()
        alert.messageText = "Index your home folder for /edit?"
        alert.informativeText = """
        Palette will read file names under ~ so the file picker can find them. \
        macOS may ask for folder access; Desktop, Documents, Downloads, Library \
        and the other system folders are skipped. You can answer again in Settings.
        """
        alert.addButton(withTitle: "Index Home Folder")
        alert.addButton(withTitle: "Not Now")
        let consent = alert.runModal() == .alertFirstButtonReturn
        configuration.indexingHomeConsent = consent
        try? writeConfig(configuration)
        return consent
    }

    /// One prompt for a tool a default provider cannot run without. The answer
    /// is stored, so it is never asked twice — and never from inside a search.
    private func checkDefaultProviderTools() {
        guard !isScriptMode, !shouldShowOnboarding else { return }
        let acknowledged = Set(configuration.missingToolAcknowledged)
        let enabled = Set(configuration.globalProviders).union(["apps"])
        let pending: [(provider: any PaletteProvider, missing: [ProviderRequirement])] =
            registry.providers.compactMap { provider in
                let id = provider.descriptor.id
                guard enabled.contains(id), !acknowledged.contains(id) else { return nil }
                let missing = ProviderRequirements.missing(ProviderToolRequirements.requirements(for: provider))
                return missing.isEmpty ? nil : (provider, missing)
            }
        guard !pending.isEmpty else { return }
        let commands = pending.flatMap { $0.missing.map(\.install) }
        let alert = NSAlert()
        alert.messageText = pending.count == 1
            ? "A source needs a tool that is not installed"
            : "\(pending.count) sources need tools that are not installed"
        alert.informativeText = pending.map { provider, missing in
            "\(provider.descriptor.name) needs \(missing.map(\.tool).joined(separator: ", ")) — "
                + missing.map(\.why).joined(separator: " · ")
                + "\n"
                + missing.map(\.install).joined(separator: "\n")
        }.joined(separator: "\n\n")
        alert.addButton(withTitle: "Keep Enabled")
        alert.addButton(withTitle: "Copy Commands")
        alert.addButton(withTitle: "Disable")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commands.joined(separator: "\n"), forType: .string)
        }
        configuration.missingToolAcknowledged += pending.map { $0.provider.descriptor.id }
        if response == .alertThirdButtonReturn {
            configuration.disabledProviders += pending.map { $0.provider.descriptor.id }
            try? writeConfig(configuration)
            reload(quiet: true)
        } else if !commands.isEmpty {
            try? writeConfig(configuration)
        }
    }

    private func seedUserProviders() {
        let neof = paths.providersDir.appendingPathComponent("neof", isDirectory: true)
        let manifest = neof.appendingPathComponent("provider.toml")
        let oldFilesContent = """
        # Neovide file picker. This is a user-level copy of the bundled neo
        # provider, showing how to add your own provider manifest.
        id = "neof"
        name = "Neovide Files"
        trigger = "neof"
        engine = "paths"
        kind = "files"
        scope = "projects"
        open_with = "neovide"
        secondary = "reveal"
        max_results = 50
        priority = 60
        """
        let oldFoldersContent = """
        # Neovide folder picker: the same provider as the bundled neo, but
        # restricted to directories. Edit this file to make it yours.
        id = "neof"
        name = "Neovide Folders"
        trigger = "neof"
        engine = "paths"
        kind = "directories"
        scope = "home"
        open_with = "neovide"
        secondary = "reveal"
        max_results = 2000
        freeform = true
        priority = 60
        """
        let content = """
        # Editor folder picker: the same provider as the bundled edit
        # provider, but restricted to directories. Edit this file to make it
        # yours.
        id = "neof"
        name = "Editor Folders"
        trigger = "editf"
        engine = "paths"
        kind = "directories"
        scope = "home"
        open_with = "editor"
        secondary = "reveal"
        max_results = 2000
        freeform = true
        priority = 60
        """

        let manager = FileManager.default
        if manager.fileExists(atPath: manifest.path) {
            // Migrate only the seed we wrote earlier; never touch a user edit.
            guard let existing = try? String(contentsOf: manifest, encoding: .utf8),
                  existing == oldFilesContent || existing == oldFoldersContent else { return }
        } else {
            do {
                try manager.createDirectory(at: neof, withIntermediateDirectories: true)
            } catch {
                Log.shared.warn("Could not seed neof provider: \(error.localizedDescription)", source: "providers")
                return
            }
        }

        do {
            try content.write(to: manifest, atomically: true, encoding: .utf8)
        } catch {
            Log.shared.warn("Could not seed neof provider: \(error.localizedDescription)", source: "providers")
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let about = NSMenuItem(title: "About Palette", action: #selector(showAboutWindowFromMenu), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        let version = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))"
        let versionItem = NSMenuItem(title: "Version \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        appMenu.addItem(versionItem)
        let update = NSMenuItem(title: "Copy Update Command", action: #selector(copyUpdateCommandFromMenu), keyEquivalent: "")
        update.target = self
        appMenu.addItem(update)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let askItem = NSMenuItem(title: "Ask…", action: #selector(showAskWindowFromMenu), keyEquivalent: "a")
        askItem.keyEquivalentModifierMask = [.command, .option]
        askItem.target = self
        appMenu.addItem(askItem)
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Palette", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Palette", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        let readme = NSMenuItem(title: "Palette Help", action: #selector(openReadmeFromMenu), keyEquivalent: "?")
        readme.target = self
        helpMenu.addItem(readme)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    /// A monochrome flower-shaped palette, matching the app icon silhouette.
    private static func statusBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let center = NSPoint(x: 9, y: 9)
            NSColor.black.setFill()
            for index in 0..<6 {
                let angle = Double(index) * Double.pi / 3
                let petal = NSRect(
                    x: center.x + CGFloat(cos(angle)) * 4.1 - 3.7,
                    y: center.y + CGFloat(sin(angle)) * 4.1 - 3.7,
                    width: 7.4, height: 7.4
                )
                NSBezierPath(ovalIn: petal).fill()
            }
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 6.3, y: 6.3, width: 5.4, height: 5.4)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        return image
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Self.statusBarIcon()
            button.image?.isTemplate = true
            button.toolTip = statusToolTip
        }
        let menu = NSMenu()
        // Capture section first: starting or stopping a recording must never
        // need a trip through the launcher.
        for command in CaptureMenuCommand.allCases {
            let item = NSMenuItem(title: "", action: #selector(captureMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            if command == .stopRecording {
                item.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)
            }
            menu.addItem(item)
            captureMenuItems[command] = item
        }
        menu.addItem(.separator())
        updateCaptureMenu()

        let open = NSMenuItem(title: "Open Palette", action: #selector(togglePalette), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let reload = NSMenuItem(title: "Reload Configuration", action: #selector(reloadFromMenu), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        let positionItem = NSMenuItem(title: "Launcher Position", action: nil, keyEquivalent: "")
        let positionMenu = NSMenu(title: "Launcher Position")
        for position in SearchPosition.allCases {
            let item = NSMenuItem(
                title: position.rawValue.capitalized,
                action: #selector(setPositionFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = position.rawValue
            positionMenu.addItem(item)
        }
        positionItem.submenu = positionMenu
        menu.addItem(positionItem)
        self.positionMenu = positionMenu
        updatePositionMenu()

        let keepAwakeItem = NSMenuItem(title: "Keep Awake", action: nil, keyEquivalent: "")
        let keepAwakeSubmenu = NSMenu(title: "Keep Awake")
        let toggle = NSMenuItem(title: "Keep Mac Awake", action: #selector(toggleKeepAwakeFromMenu), keyEquivalent: "")
        toggle.target = self
        keepAwakeSubmenu.addItem(toggle)
        keepAwakeToggleItem = toggle
        let keepAwakeDurations: [(Double, String)] = [
            (15.0 * 60, "For 15 Minutes"),
            (30.0 * 60, "For 30 Minutes"),
            (60.0 * 60, "For 1 Hour"),
            (2.0 * 60 * 60, "For 2 Hours"),
            (4.0 * 60 * 60, "For 4 Hours"),
            (8.0 * 60 * 60, "For 8 Hours"),
        ]
        for (seconds, title) in keepAwakeDurations {
            let item = NSMenuItem(title: title, action: #selector(startKeepAwakeFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: seconds)
            keepAwakeSubmenu.addItem(item)
        }
        keepAwakeSubmenu.addItem(.separator())
        let clamshell = NSMenuItem(title: "Clamshell (Lid Closed)", action: #selector(toggleClamshellFromMenu), keyEquivalent: "")
        clamshell.target = self
        keepAwakeSubmenu.addItem(clamshell)
        keepAwakeClamshellItem = clamshell
        let stop = NSMenuItem(title: "Stop Keeping Awake", action: #selector(stopKeepAwakeFromMenu), keyEquivalent: "")
        stop.target = self
        keepAwakeSubmenu.addItem(stop)
        keepAwakeStopItem = stop
        keepAwakeItem.submenu = keepAwakeSubmenu
        menu.addItem(keepAwakeItem)
        self.keepAwakeMenu = keepAwakeSubmenu

        let refresh = NSMenuItem(title: "Refresh Bitwarden Cache", action: #selector(refreshBitwardenFromMenu), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let advancedItem = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        let advancedMenu = NSMenu(title: "Advanced")
        for (title, action) in [
            ("Open config.toml", #selector(openConfigFromMenu)),
            ("Open Providers Folder", #selector(openProvidersFromMenu)),
            ("Open Themes Folder", #selector(openThemesFromMenu)),
            ("Open Log", #selector(openLogFromMenu)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            advancedMenu.addItem(item)
        }
        advancedItem.submenu = advancedMenu
        menu.addItem(advancedItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Palette", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self
        statusItem.menu = menu
    }

    private func installThemeObserver() {
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.themeManager.systemAppearanceChanged()
            }
        }
    }

    // MARK: - Housekeeping

    /// Two paths only, both written by <= 2.15 and unread by 2.16: the old
    /// Hammerspoon exporter and its profile directory.
    private func removeStaleLegacyFiles() {
        guard !isScriptMode else { return }
        let home = NSHomeDirectory()
        let stale = [
            home + "/.hammerspoon/palette-webapps.lua",
            home + "/Library/Caches/Palette/WebApps",
        ]
        for path in stale where FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(atPath: path)
                Log.shared.info("Removed stale \(path)", source: "cleanup")
            } catch {
                Log.shared.warn("Could not remove stale \(path): \(error.localizedDescription)", source: "cleanup")
            }
        }
    }

    /// Every config write goes through here so the watcher can tell our save
    /// from an external edit and never reload in a loop.
    private func writeConfig(_ config: PaletteConfig) throws {
        try ConfigWriter.write(config, to: paths.configFile)
        lastConfigModification = modificationDate(paths.configFile)
    }

    private func scheduleDatabaseMaintenance() {
        runDatabaseMaintenance()
        maintenanceTimer?.invalidate()
        let timer = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runDatabaseMaintenance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer
    }

    private func runDatabaseMaintenance() {
        guard !maintenanceRunning else { return }
        maintenanceRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.maintenanceRunning = false }
            do {
                let report = try await self.store.maintain(
                    clipboardRetentionDays: self.configuration.clipboard.retentionDays,
                    maxImageBytes: self.configuration.clipboard.maxImageBytes,
                    askRetentionDays: self.configuration.ask.retentionDays
                )
                guard report.clipboardRemoved > 0 || report.chatsRemoved > 0 else { return }
                Log.shared.info(
                    "Retention removed \(report.clipboardRemoved) clip(s) and \(report.chatsRemoved) chat(s); \(report.bytesBefore) → \(report.bytesAfter) bytes\(report.vacuumed ? " (vacuumed)" : "")",
                    source: "storage"
                )
                self.searchController?.clipboardDidChange()
            } catch {
                Log.shared.warn("Database maintenance failed: \(error.localizedDescription)", source: "storage")
            }
        }
    }

    /// `/theme` is a real choice: store it in `[theme]` so a relaunch keeps it,
    /// instead of the old meta key that was written and deleted every launch.
    private func pickTheme(_ name: String) {
        themeManager.select(name)
        let appearance = themeManager.theme.appearance
        if appearance == "light" {
            configuration.theme.mode = .light
            configuration.theme.light = name
        } else {
            configuration.theme.mode = .dark
            configuration.theme.dark = name
        }
        themeManager.selection = configuration.theme
        do {
            try writeConfig(configuration)
        } catch {
            Log.shared.warn("Could not save the theme choice: \(error.localizedDescription)", source: "theme")
        }
    }

    private func configureWatchers() {
        lastConfigModification = modificationDate(paths.configFile)
        lastThemesSignature = themesSignature()
        lastProvidersSignature = providersSignature()
        watcherTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForFileChanges()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watcherTimer = timer
    }

    private func checkForFileChanges() {
        guard !reloadInFlight else { return }
        let configDate = modificationDate(paths.configFile)
        if configDate != lastConfigModification {
            lastConfigModification = configDate
            scheduleConfigReload()
            return
        }
        let signature = themesSignature()
        if signature != lastThemesSignature {
            lastThemesSignature = signature
            scheduleConfigReload()
            return
        }
        let providers = providersSignature()
        if providers != lastProvidersSignature {
            lastProvidersSignature = providers
            scheduleConfigReload()
        }
    }

    /// Editors touch a file several times per save; wait for the burst to end.
    private func scheduleConfigReload() {
        configChangeTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.reload(quiet: true) }
        }
        configChangeTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func themesSignature() -> Date? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: paths.themesDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        return files.compactMap { file in
            (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max()
    }

    private func providersSignature() -> Date? {
        var dates: [Date] = []
        if let date = modificationDate(paths.providersDir) { dates.append(date) }
        guard let enumerator = FileManager.default.enumerator(
            at: paths.providersDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return dates.max() }
        for case let file as URL in enumerator {
            if let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                dates.append(date)
            }
        }
        return dates.max()
    }

    // MARK: - Reload

    /// Dock/undock or a resolution change: the fixed frame follows the screen
    /// under the pointer, so reposition even if the panel is already open.
    @objc private func screenParametersChanged() {
        guard let panel else { return }
        panel.windowConfig = configuration.window
    }

    func reload(quiet: Bool, refreshSettings: Bool = true) {
        guard !reloadInFlight else { return }
        reloadInFlight = true
        defer { reloadInFlight = false }

        let result = ConfigLoader.load(paths: paths)
        configuration = result.config
        startupDiagnostics = result.diagnostics
        configErrorMessage = result.parseError
        ToolLocator.shared.configure(extraPaths: configuration.toolsPath)
        themeManager.typography = configuration.typography
        themeManager.searchPlaceholder = configuration.searchPlaceholder
        timerService.configure(sound: configuration.timer.sound, notifications: configuration.timer.notify)
        captureService.config = configuration.capture
        themeManager.updateSelection(configuration.theme)
        panel?.anchorOverride = configuration.searchPosition.rawValue
        panel?.windowConfig = configuration.window
        updatePositionMenu()

        let oldRegistry = registry
        let newRegistry = buildRegistry()
        registry = newRegistry
        searchController.replace(registry: newRegistry, configuration: configuration)
        // An open chat must follow the new config, not keep the old service.
        if let askService, let askWindow {
            askWindow.reconfigure(
                service: askService,
                notify: configuration.ask.notify,
                webSearch: configuration.ask.webSearch
            )
            Log.shared.info("Ask window reconfigured after reload", source: "ask")
        }

        // Rebuild every global key in one pass: built-ins, web apps (which also
        // picks up a changed `web_app_browser`), bindings and the catalogue.
        // Scripted runs leave Carbon alone.
        installHotKey()
        configureClipboard()
        if refreshSettings { refreshSettingsWindow() }
        if !quiet {
            searchController.setStatus("Configuration reloaded", duration: 2)
        }
        if let oldRegistry {
            Task { await oldRegistry.shutdown() }
        }
    }

    // MARK: - Actions

    @objc private func togglePalette() {
        panel.toggle()
    }

    private func showClipboard() {
        if panel.isVisible, searchController.previewEnabled {
            panel.hide()
            return
        }
        if !panel.isVisible {
            panel.show()
        }
        searchController.openClipboard()
    }

    @objc private func reloadFromMenu() {
        reload(quiet: false)
    }

    @objc private func setPositionFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let position = SearchPosition(rawValue: raw) else { return }
        configuration.searchPosition = position
        panel?.anchorOverride = position.rawValue
        do {
            try writeConfig(configuration)
        } catch {
            Log.shared.warn("Could not save launcher position: \(error.localizedDescription)", source: "app")
        }
        updatePositionMenu()
    }

    private func updatePositionMenu() {
        for item in positionMenu?.items ?? [] {
            item.state = (item.representedObject as? String) == configuration.searchPosition.rawValue ? .on : .off
        }
    }

    @objc private func openConfigFromMenu() {
        openConfig()
    }

    @objc private func openSettingsFromMenu() {
        showSettings()
    }

    @objc private func openReadmeFromMenu() {
        guard let url = URL(string: "https://github.com/Myleshen/palette/blob/main/README.md") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyUpdateCommandFromMenu() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew upgrade --cask palette", forType: .string)
        searchController.setStatus("Update command copied", duration: 2)
    }

    @objc private func openAskSettingsFromWindow() {
        showSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .paletteSettingsTab, object: SettingsTab.ask.rawValue)
        }
    }

    private func showSettings() {
        panel?.hide(activatePrevious: false)
        if let settingsWindow {
            // A closed window keeps its old SwiftUI state; rebuild it so the
            // values reflect config.toml after a reload or manual edit.
            if !settingsWindow.isVisible {
                settingsWindow.contentView = makeSettingsHostingView()
            }
            NSApp.activate()
            settingsWindow.makeKeyAndOrderFront(nil)
            settingsWindow.orderFrontRegardless()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Palette Settings"
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.contentMinSize = NSSize(width: 820, height: 560)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setFrameAutosaveName("PaletteSettings")
        // A themed (not transparent) titlebar keeps AppKit's native window drag.
        window.backgroundColor = themeManager.theme.nsColor(themeManager.theme.palette.bg)
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: themeManager.theme.appearance == "light" ? .aqua : .darkAqua)
        window.contentView = makeSettingsHostingView()
        if !window.setFrameUsingName("PaletteSettings") {
            window.center()
        }
        settingsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeSettingsHostingView() -> NSView {
        let host = NSHostingView(rootView: makeSettingsView())
        // Keep the window at its own size instead of the SwiftUI content height.
        host.sizingOptions = []
        return host
    }

    private func exportBackup() {
        let confirm = NSAlert()
        confirm.messageText = "Export a backup without clipboard text?"
        confirm.informativeText = """
        The backup includes config.toml, themes, providers, history and the encrypted Ask key files. \
        Plain-text clipboard entries are removed before zipping because they can hold pasted secrets. \
        Image and file entries stay because they hold paths and pictures, not the text you typed.
        """
        confirm.addButton(withTitle: "Export")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Palette-Backup-\(stamp).zip"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        writeBackup(to: destination)
    }

    /// The full user state: config, themes, providers, database and the small
    /// TOML files that used to be left out. The ask key files are encrypted.
    @discardableResult
    private func writeBackup(to destination: URL) -> Bool {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Palette-Backup-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        defer { try? manager.removeItem(at: temp) }
        do {
            try manager.createDirectory(at: temp, withIntermediateDirectories: true)
            var included: [String] = []

            func copy(_ source: URL, as name: String) {
                guard manager.fileExists(atPath: source.path) else { return }
                if (try? manager.copyItem(at: source, to: temp.appendingPathComponent(name))) != nil {
                    included.append(name)
                }
            }

            copy(paths.configFile, as: "config.toml")
            copy(paths.themesDir, as: "themes")
            copy(paths.providersDir, as: "providers")
            copy(paths.databaseFile, as: "palette.sqlite")
            for suffix in ["-wal", "-shm"] {
                copy(URL(fileURLWithPath: paths.databaseFile.path + suffix), as: "palette.sqlite" + suffix)
            }
            copy(paths.configDir.appendingPathComponent("ask-key.bin"), as: "ask-key.bin")
            copy(paths.configDir.appendingPathComponent("ask-keys.bin"), as: "ask-keys.bin")
            copy(paths.bookmarksFile, as: "bookmarks.toml")
            copy(paths.configDir.appendingPathComponent("commands.toml"), as: "commands.toml")
            copy(paths.configDir.appendingPathComponent("snippets.toml"), as: "snippets.toml")

            // Pasted text is the sensitive part of the clipboard history. Fold
            // the WAL into the copy, drop text rows, then vacuum so no deleted
            // page survives in the zip.
            let database = temp.appendingPathComponent("palette.sqlite")
            let sqlite = Process()
            sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            sqlite.arguments = [
                database.path,
                "PRAGMA journal_mode=DELETE; DELETE FROM clipboard WHERE kind = 'text'; VACUUM;",
            ]
            try sqlite.run()
            sqlite.waitUntilExit()
            guard sqlite.terminationStatus == 0 else {
                throw NSError(domain: "PaletteBackup", code: Int(sqlite.terminationStatus))
            }
            for suffix in ["-wal", "-shm"] {
                try? manager.removeItem(at: URL(fileURLWithPath: database.path + suffix))
            }

            let readme = """
            Palette backup
            ==============
            Included in this archive:
            \(included.map { "- \($0)" }.joined(separator: "\n"))

            ask-key.bin and ask-keys.bin hold API keys stored by Palette; they
            are encrypted. Everything else is plain text or a normal SQLite
            database. Clipboard history is included without its text entries.
            """
            try readme.write(to: temp.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", temp.path, destination.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "PaletteBackup", code: Int(process.terminationStatus))
            }
            searchController.setStatus("Backup exported to \(destination.lastPathComponent)", duration: 4)
            return true
        } catch {
            searchController.setStatus("Backup failed: \(error.localizedDescription)", duration: 5)
            return false
        }
    }

    private func makeSettingsView() -> SettingsView {
        SettingsView(
            config: configuration,
            keepAwake: keepAwake,
            themeManager: themeManager,
            themesDirectory: paths.themesDir,
            accessibilityTrusted: pasteboard.isAccessibilityTrusted,
            providers: allProviderInfo,
            commands: catalogCommands,
            diagnostics: startupDiagnostics.map { "\($0.level.rawValue): \($0.message)" },
            onApply: { [weak self] updated in
                self?.applySettings(updated)
            },
            onOpen: { [weak self] url in
                self?.launcher.openPath(url.path)
            },
            onExportBackup: { [weak self] in
                self?.exportBackup()
            }
        )
    }

    /// Keep an open Settings window in sync when config.toml is reloaded.
    private func refreshSettingsWindow() {
        guard let settingsWindow, settingsWindow.isVisible else { return }
        settingsWindow.contentView = makeSettingsHostingView()
    }

    /// Auto-apply writes the same canonical file the old Save button wrote, then
    /// reloads the app in place. The Settings view is not rebuilt, so the field
    /// the user is typing in keeps focus.
    private func applySettings(_ updated: PaletteConfig) -> String? {
        // A file Palette cannot parse is the user's, not ours: writing defaults
        // over it would erase comments and every unknown key.
        if let configErrorMessage {
            return configErrorMessage
        }
        do {
            try writeConfig(updated)
        } catch {
            return "Could not save settings: \(error.localizedDescription)"
        }
        reload(quiet: true, refreshSettings: false)
        updateSettingsWindowChrome()
        return nil
    }

    private func updateSettingsWindowChrome() {
        guard let settingsWindow else { return }
        settingsWindow.appearance = themeManager.theme.nsAppearance
        settingsWindow.backgroundColor = themeManager.theme.nsColor(themeManager.theme.palette.bg)
    }

    @objc private func openProvidersFromMenu() {
        openProviders()
    }

    @objc private func openThemesFromMenu() {
        launcher.openPath(paths.themesDir.path)
    }

    @objc private func openLogFromMenu() {
        launcher.openPath(paths.logFile.path)
    }

    @objc private func refreshBitwardenFromMenu() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.bitwardenVault.refresh()
            self.searchController.refreshResults()
            self.searchController.setStatus("Bitwarden cache refreshed", duration: 3)
        }
    }

    @objc private func toggleKeepAwakeFromMenu() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await self.keepAwake.snapshot()
            if status.active {
                await self.keepAwake.stop()
                self.searchController.setStatus("Normal sleep restored", duration: 2)
            } else {
                try? await self.keepAwake.start(duration: nil)
                self.searchController.setStatus("Keeping your Mac awake", duration: 2)
            }
            await self.refreshKeepAwakeMenu()
            self.searchController.refreshResults()
        }
    }

    @objc private func startKeepAwakeFromMenu(_ sender: NSMenuItem) {
        let seconds = (sender.representedObject as? NSNumber)?.doubleValue ?? 0
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.keepAwake.start(duration: seconds > 0 ? seconds : nil)
            self.searchController.setStatus("Keeping your Mac awake for \(sender.title.lowercased())", duration: 2)
            await self.refreshKeepAwakeMenu()
            self.searchController.refreshResults()
        }
    }

    @objc private func toggleClamshellFromMenu() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await self.keepAwake.snapshot()
            let enabled = !status.clamshell
            do {
                try await self.keepAwake.setClamshell(enabled)
                self.searchController.setStatus(
                    enabled ? "Clamshell mode on · AC power only" : "Clamshell mode off",
                    duration: 3
                )
            } catch {
                self.searchController.setStatus(error.localizedDescription, duration: 5)
            }
            await self.refreshKeepAwakeMenu()
            self.searchController.refreshResults()
        }
    }

    @objc private func stopKeepAwakeFromMenu() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.keepAwake.stop()
            await self.refreshKeepAwakeMenu()
            self.searchController.setStatus("Normal sleep restored", duration: 2)
            self.searchController.refreshResults()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        updateCaptureMenu()
        Task { @MainActor [weak self] in
            await self?.refreshKeepAwakeMenu()
        }
    }

    private func refreshKeepAwakeMenu() async {
        let status = await keepAwake.snapshot()
        keepAwakeToggleItem?.title = status.active ? "Stop Keeping Awake" : "Keep Mac Awake (Indefinitely)"
        keepAwakeToggleItem?.state = status.active ? .on : .off
        keepAwakeClamshellItem?.title = status.clamshell && status.clamshellRequiresPower
            ? "Clamshell (Lid Closed) — armed, inactive"
            : "Clamshell (Lid Closed)"
        keepAwakeClamshellItem?.state = status.clamshell ? .on : .off
        keepAwakeStopItem?.isEnabled = status.active
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    private func openConfig() {
        if !FileManager.default.fileExists(atPath: paths.configFile.path) {
            _ = ConfigLoader.load(paths: paths)
        }
        let editor = configuration.editorOpenWith.trimmingCharacters(in: .whitespaces)
        if !editor.isEmpty {
            do {
                try launcher.openPath(paths.configFile.path, with: editor)
                return
            } catch {
                Log.shared.warn("Could not open config with \(editor): \(error.localizedDescription)", source: "app")
            }
        }
        launcher.openPath(paths.configFile.path)
    }

    private func openProviders() {
        launcher.openPath(paths.providersDir.path)
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
