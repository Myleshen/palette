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

    func notify(_ message: String) async {
        guard let target = current() else { return }
        await target.notify(message)
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
    private let bitwardenVault = BitwardenVault()
    private let keepAwake = KeepAwakeService()
    private let timerService = TimerService()
    private let captureService = CaptureService()
    private var clamshellObserver: NSObjectProtocol?
    private var searchController: SearchController!
    private var panel: PanelController!
    private var hotkey: HotKeyManager!
    private var clipboardHotkey: HotKeyManager!
    private var terminalHotkey: HotKeyManager!
    private var scratchpadHotkey: HotKeyManager!
    private var screenshotHotkey: HotKeyManager!
    private var regionHotkey: HotKeyManager!
    private var windowHotkey: HotKeyManager!
    private var recordingHotkey: HotKeyManager!
    private var currentScreenshotHotKey: HotKeySpec?
    private var currentRegionHotKey: HotKeySpec?
    private var currentWindowHotKey: HotKeySpec?
    private var currentRecordingHotKey: HotKeySpec?
    private var statusItem: NSStatusItem!
    private var hostProxy: HostBridgeProxy!
    private var appIndex: AppIndex!
    private var currentHotKey: HotKeySpec?
    private var currentClipboardHotKey: HotKeySpec?
    private var currentTerminalHotKey: HotKeySpec?
    private var currentScratchpadHotKey: HotKeySpec?
    private var askHotkey: HotKeyManager!
    private var currentAskHotKey: HotKeySpec?
    private var recordingMenuItem: NSMenuItem?
    private var recordingTicker: Timer?
    private let screenshotHUD = ScreenshotHUD()
    private var annotateWindows: [AnnotateWindowController] = []
    private var mediaPreviews: [MediaPreviewWindowController] = []
    private var startupDiagnostics: [Diagnostic] = []
    private var themeObserver: NSObjectProtocol?
    private var watcherTimer: Timer?
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
        let forceOnboarding = ProcessInfo.processInfo.environment["PALETTE_FORCE_ONBOARDING"] == "1"
        shouldShowOnboarding = (configResult.createdDefault || forceOnboarding)
            && (forceOnboarding || !UserDefaults.standard.bool(forKey: "onboardingCompleted"))
        ToolLocator.shared.configure(extraPaths: configuration.toolsPath)

        do {
            store = try PaletteStore(path: paths.databaseFile.path)
        } catch {
            Log.shared.error("Database failed: \(error.localizedDescription)", source: "app")
            let fallback = paths.stateDir.appendingPathComponent("palette-fallback.sqlite")
            do {
                store = try PaletteStore(path: fallback.path)
                startupDiagnostics.append(Diagnostic(.warning, "Primary database unavailable; using \(fallback.lastPathComponent).", source: "storage"))
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
        themeManager.window = configuration.window
        timerService.configure(sound: configuration.timer.sound, notifications: configuration.timer.notify)
        captureService.config = configuration.capture
        themeManager.reload()
        themeManager.onChange = { [weak self] theme in
            guard let self else { return }
            self.panel?.apply(theme: theme)
            self.searchController?.refreshTheme()
        }

        registry = buildRegistry()
        Task { await exportWebApps() }
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
        captureService.onStatus = { [weak self] message in
            self?.searchController.setStatus(message, duration: 4)
        }
        captureService.onFailure = { [weak self] message in
            self?.captureService.annotateNextCapture = false
            Task { await self?.searchController.notify(message) }
        }
        captureService.onScreenshot = { [weak self] url in
            guard let self else { return }
            let forced = self.captureService.annotateNextCapture
            self.captureService.annotateNextCapture = false
            if forced || self.configuration.capture.editAfterCapture {
                self.openAnnotator(url)
                return
            }
            self.confirmCapture(url)
        }
        captureService.onRecordingStopped = { [weak self] url in
            guard let self, self.configuration.capture.previewRecording else { return }
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
        configureClipboard()
        buildStatusItem()
        installThemeObserver()
        showOnboardingIfNeeded()

        if let firstError = startupDiagnostics.first(where: { $0.level == .error }) {
            searchController.setStatus(firstError.message, duration: nil)
        } else if let warning = startupDiagnostics.first(where: { $0.level == .warning }) {
            Log.shared.warn(warning.message, source: warning.source ?? "app")
        }

        Task { [weak self] in
            await self?.themeManager.restore()
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
    private func runScriptIfRequested() {
        guard let script = ProcessInfo.processInfo.environment["PALETTE_SCRIPT"] else { return }
        let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        Task { @MainActor [weak self] in
            for step in steps where !step.isEmpty {
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
                    await self.simulateDrag(value)
                } else if step == "close_windows" {
                    self.annotateWindows.forEach { $0.close() }
                    self.mediaPreviews.forEach { $0.close() }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                } else if step == "settings" {
                    self.showSettings()
                } else if let value = step.dropPrefix("settings_tab="), let index = Int(value) {
                    self.showSettings()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    NotificationCenter.default.post(name: .paletteSettingsTab, object: index)
                } else if step == "clipboard" {
                    self.showClipboard()
                } else if step == "exit" {
                    NSApp.terminate(nil)
                    return
                } else if let value = step.dropPrefix("query=") {
                    self.searchController.query = value
                } else if let value = step.dropPrefix("snapshot=") {
                    self.writeSnapshot(to: value)
                } else if let value = step.dropPrefix("window_snapshot=") {
                    if let hud = self.annotateWindows.last?.window
                        ?? self.mediaPreviews.last?.window {
                        self.write(view: hud.contentView ?? NSView(), to: value)
                    } else if let hudView = self.screenshotHUD.view {
                        self.write(view: hudView, to: value)
                    } else if let other = NSApp.keyWindow ?? NSApp.windows.last(where: { $0.isVisible }) {
                        self.write(view: other.contentView ?? NSView(), to: value)
                    }
                } else if let value = step.dropPrefix("settings_snapshot=") {
                    self.writeSettingsSnapshot(to: value)
                } else if let value = step.dropPrefix("onboarding_snapshot=") {
                    self.writeOnboardingSnapshot(to: value)
                } else if let value = step.dropPrefix("prompt=") {
                    self.searchController.promptValue = value
                } else if let value = step.dropPrefix("wait=") {
                    let seconds = Double(value) ?? 0.3
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } else if let value = step.dropPrefix("key=") {
                    if let event = self.syntheticKey(value) {
                        _ = self.searchController.handleKey(event)
                    }
                }
            }
        }
    }

    private func writeSnapshot(to destination: String) {
        guard let view = panel.panel.contentView else { return }
        write(view: view, to: destination)
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
        watcherTimer?.invalidate()
        clipboardMonitor?.stop()
        hotkey?.unregister()
        // Restore normal lid sleep even if the async cleanup does not finish.
        ClamshellGuard.clearFlag()
        if let themeObserver {
            DistributedNotificationCenter.default().removeObserver(themeObserver)
        }
        let registry = self.registry
        Task { await registry?.shutdown() }
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
        providers.append(ScratchpadProvider(store: store))
        providers.append(TerminalProvider())
        providers.append(KeepAwakeProvider(service: keepAwake, bridge: hostProxy, launcher: launcher))
        providers.append(TimerProvider(service: timerService, presetMinutes: configuration.timer.presets))
        providers.append(ColorProvider())
        providers.append(StatsProvider())
        providers.append(SSHProvider(launcher: launcher, terminalApp: configuration.terminalApp))
        providers.append(DockerProvider(launcher: launcher, terminalApp: configuration.terminalApp))
        providers.append(GitHubProvider(launcher: launcher, terminalApp: configuration.terminalApp))
        providers.append(UnitsProvider())
        providers.append(WindowProvider(launcher: launcher))
        providers.append(ShotsProvider(service: captureService))
        let hideForCapture: @MainActor () -> Void = { [weak self] in
            self?.panel?.hide(activatePrevious: false)
        }
        providers.append(ShotProvider(service: captureService, beforeCapture: hideForCapture))
        providers.append(RecProvider(service: captureService, beforeStart: hideForCapture))
        providers.append(WebSearchProvider(
            engines: configuration.webSearchEngines,
            enabled: configuration.webSearchEnabled,
            launcher: launcher
        ))
        providers.append(PinProvider(store: store, bridge: hostProxy))
        providers.append(ClipboardProvider(store: store, bridge: hostProxy))
        let askService = AskService(store: store, configuration: configuration.ask)
        providers.append(AskProvider(service: askService, bridge: hostProxy))
        providers.append(AskHistoryProvider(service: askService, bridge: hostProxy))
        providers.append(WebAppProvider(store: store, bridge: hostProxy, browser: configuration.webAppBrowser, onChange: { [weak self] in
            await self?.exportWebApps()
        }))
        providers.append(BookmarkProvider())
        providers.append(ZellijProvider(terminal: configuration.terminal, launcher: launcher, bridge: hostProxy))
        providers.append(PortProvider(launcher: launcher, bridge: hostProxy))
        providers.append(CommandProvider(launcher: launcher, bridge: hostProxy, terminal: configuration.terminal))
        providers.append(ProjectProvider(launcher: launcher, bridge: hostProxy, terminal: configuration.terminal))
        providers.append(RecentProvider(store: store, launcher: launcher, editor: configuration.editorOpenWith))
        providers.append(SnippetProvider(bridge: hostProxy))
        providers.append(GitProvider(launcher: launcher, bridge: hostProxy))
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
            onSelect: { [weak self] name in self?.themeManager.select(name) },
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
                diagnostics: &diagnostics
            ) {
                providers.append(provider)
            }
        }

        let registry = ProviderRegistry(
            providers: providers,
            prefix: configuration.providerPrefix,
            aliases: configuration.providerAliases,
            order: configuration.providerOrder,
            disabled: configuration.disabledProviders,
            diagnostics: diagnostics
        )
        Log.shared.info("Registered providers: \(registry.providers.map { "\($0.descriptor.id)/\($0.descriptor.trigger ?? "-")" }.joined(separator: ", "))", source: "providers")
        for diagnostic in registry.diagnostics where diagnostic.level == .error {
            Log.shared.error(diagnostic.message, source: diagnostic.source ?? "providers")
        }
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

    private func installHotKey() {
        installLauncherHotKey()
        installClipboardHotKey()
        installTerminalHotKey()
        installScratchpadHotKey()
        installAskHotKey()
        installScreenshotHotKey()
        installRegionHotKey()
        installWindowHotKey()
        installRecordingHotKey()
    }

    private func installLauncherHotKey() {
        let previous = currentHotKey
        if hotkey == nil {
            hotkey = HotKeyManager()
            hotkey.onPressed = { [weak self] in self?.togglePalette() }
        }
        let manager = hotkey!
        do {
            currentHotKey = try manager.register(configuration.hotkey)
            Log.shared.info("Hotkey registered: \(currentHotKey?.display ?? configuration.hotkey)", source: "hotkey")
        } catch {
            currentHotKey = nil
            if let previous, (try? manager.register(previous.display)) != nil {
                currentHotKey = previous
                Log.shared.warn("Hotkey '\(configuration.hotkey)' unavailable; kept '\(previous.display)'", source: "hotkey")
                searchController?.setStatus("Hotkey unavailable; kept \(previous.display)", duration: 4)
                return
            }
            startupDiagnostics.append(Diagnostic(.error, error.localizedDescription, source: "hotkey"))
            Log.shared.error("Hotkey registration failed: \(error.localizedDescription)", source: "hotkey")
            searchController?.setStatus("Hotkey unavailable: \(error.localizedDescription)", duration: nil)
        }
    }

    private func installClipboardHotKey() {
        guard !configuration.clipboardHotkey.isEmpty else {
            clipboardHotkey?.unregister()
            currentClipboardHotKey = nil
            return
        }
        if clipboardHotkey == nil {
            clipboardHotkey = HotKeyManager(hotKeyID: 2)
            clipboardHotkey.onPressed = { [weak self] in self?.showClipboard() }
        }
        do {
            currentClipboardHotKey = try clipboardHotkey.register(configuration.clipboardHotkey)
            Log.shared.info("Clipboard hotkey registered: \(currentClipboardHotKey?.display ?? configuration.clipboardHotkey)", source: "hotkey")
        } catch {
            currentClipboardHotKey = nil
            Log.shared.warn(
                "Clipboard hotkey '\(configuration.clipboardHotkey)' unavailable: \(error.localizedDescription)",
                source: "hotkey"
            )
        }
    }

    private func installScreenshotHotKey() {
        guard !configuration.screenshotHotkey.isEmpty else {
            screenshotHotkey?.unregister()
            currentScreenshotHotKey = nil
            return
        }
        if screenshotHotkey == nil {
            screenshotHotkey = HotKeyManager(hotKeyID: 6)
            screenshotHotkey.onPressed = { [weak self] in self?.captureScreenshot() }
        }
        do {
            currentScreenshotHotKey = try screenshotHotkey.register(configuration.screenshotHotkey)
            Log.shared.info("Screenshot hotkey registered: \(currentScreenshotHotKey?.display ?? configuration.screenshotHotkey)", source: "hotkey")
        } catch {
            currentScreenshotHotKey = nil
            Log.shared.warn("Screenshot hotkey '\(configuration.screenshotHotkey)' unavailable: \(error.localizedDescription)", source: "hotkey")
            searchController?.setStatus(hotkeyTaken("\u{2318}\u{21E7}3"), duration: 8)
        }
    }

    private func installRegionHotKey() {
        guard !configuration.regionScreenshotHotkey.isEmpty else {
            regionHotkey?.unregister()
            currentRegionHotKey = nil
            return
        }
        if regionHotkey == nil {
            regionHotkey = HotKeyManager(hotKeyID: 8)
            regionHotkey.onPressed = { [weak self] in self?.captureScreenshot(mode: .region) }
        }
        do {
            currentRegionHotKey = try regionHotkey.register(configuration.regionScreenshotHotkey)
            Log.shared.info("Region hotkey registered: \(currentRegionHotKey?.display ?? configuration.regionScreenshotHotkey)", source: "hotkey")
        } catch {
            currentRegionHotKey = nil
            Log.shared.warn("Region hotkey '\(configuration.regionScreenshotHotkey)' unavailable: \(error.localizedDescription)", source: "hotkey")
            searchController?.setStatus(hotkeyTaken(configuration.regionScreenshotHotkey), duration: 8)
        }
    }

    private func installWindowHotKey() {
        guard !configuration.windowScreenshotHotkey.isEmpty else {
            windowHotkey?.unregister()
            currentWindowHotKey = nil
            return
        }
        if windowHotkey == nil {
            windowHotkey = HotKeyManager(hotKeyID: 9)
            windowHotkey.onPressed = { [weak self] in self?.captureScreenshot(mode: .window) }
        }
        do {
            currentWindowHotKey = try windowHotkey.register(configuration.windowScreenshotHotkey)
            Log.shared.info("Window hotkey registered: \(currentWindowHotKey?.display ?? configuration.windowScreenshotHotkey)", source: "hotkey")
        } catch {
            currentWindowHotKey = nil
            Log.shared.warn("Window hotkey '\(configuration.windowScreenshotHotkey)' unavailable: \(error.localizedDescription)", source: "hotkey")
            searchController?.setStatus(hotkeyTaken(configuration.windowScreenshotHotkey), duration: 8)
        }
    }

    private func installRecordingHotKey() {
        guard !configuration.recordingHotkey.isEmpty else {
            recordingHotkey?.unregister()
            currentRecordingHotKey = nil
            return
        }
        if recordingHotkey == nil {
            recordingHotkey = HotKeyManager(hotKeyID: 7)
            recordingHotkey.onPressed = { [weak self] in self?.toggleRecording() }
        }
        do {
            currentRecordingHotKey = try recordingHotkey.register(configuration.recordingHotkey)
            Log.shared.info("Recording hotkey registered: \(currentRecordingHotKey?.display ?? configuration.recordingHotkey)", source: "hotkey")
        } catch {
            currentRecordingHotKey = nil
            Log.shared.warn("Recording hotkey '\(configuration.recordingHotkey)' unavailable: \(error.localizedDescription)", source: "hotkey")
            searchController?.setStatus(hotkeyTaken(configuration.recordingHotkey), duration: 8)
        }
    }

    /// A taken shortcut is not an error the user can fix silently: say which key
    /// and where to change it.
    private func hotkeyTaken(_ key: String) -> String {
        "\(key) is already used by another app (Shottr, Raycast…). Pick another in Settings → Shortcuts."
    }

    // MARK: - Capture actions

    private func captureScreenshot(mode: CaptureMode = .screen) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.panel?.isVisible == true {
                self.panel?.hide(activatePrevious: false)
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
            do {
                let result = try await self.captureService.screenshot(mode)
                self.searchController.setStatus("Saved \(result.url.lastPathComponent)", duration: 4)
            } catch CaptureError.cancelled {
                self.searchController.setStatus("Screenshot cancelled", duration: 3)
            } catch {
                // The panel is hidden during a capture, so a plain status
                // message would never be seen.
                Log.shared.error("Screenshot failed: \(error.localizedDescription)", source: "capture")
                await self.searchController.notify("Screenshot failed: \(error.localizedDescription)")
            }
        }
    }

    private func toggleRecording() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.captureService.isRecording {
                do {
                    let url = try await self.captureService.stopRecording()
                    self.searchController.setStatus("Saved \(url.lastPathComponent)", duration: 4)
                } catch {
                    await self.searchController.notify("Recording failed: \(error.localizedDescription)")
                }
                self.recordingTicker?.invalidate()
                self.recordingTicker = nil
                self.updateRecordingMenuItem()
            } else {
                if self.panel?.isVisible == true {
                    self.panel?.hide(activatePrevious: false)
                }
                do {
                    try self.captureService.startRecording()
                    self.searchController.setStatus("Recording started", duration: 3)
                } catch {
                    await self.searchController.notify("Recording failed: \(error.localizedDescription)")
                }
                self.updateRecordingMenuItem()
                self.recordingTicker?.invalidate()
                self.recordingTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.updateRecordingMenuItem() }
                }
            }
        }
    }

    // MARK: - Annotate and preview

    /// Palette is a menu-bar app. Editing and preview windows need a Dock icon
    /// and a normal app menu, so the policy follows them and nothing else —
    /// scanning NSApp.windows used to leave the Dock icon behind whenever any
    /// other window happened to be visible.
    private func updateActivationPolicy() {
        let editing = !annotateWindows.isEmpty || !mediaPreviews.isEmpty
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
        let controller = AnnotateWindowController(image: image, url: url)
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
        editor.add(.text(at: CGPoint(x: 0.1, y: 0.6), text: "Palette", size: 0.06, color: .systemYellow))
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
        screenshotHUD.show(image: image, title: url.lastPathComponent) { [weak self] in
            self?.openAnnotator(url)
        }
    }

    private func openMediaPreview(_ url: URL) {
        let controller = MediaPreviewWindowController(url: url)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.mediaPreviews.removeAll { $0 === controller }
            self.updateActivationPolicy()
        }
        mediaPreviews.append(controller)
        controller.show()
    }

    @objc private func stopRecordingFromMenu() {
        toggleRecording()
    }

    /// Keeps the menu bar honest about a running recording.
    private func updateRecordingMenuItem() {
        guard let menu = statusItem?.menu else { return }
        if captureService.isRecording {
            if recordingMenuItem == nil {
                Log.shared.info("Recording indicator shown in the menu bar", source: "capture")
                let item = NSMenuItem(title: "Stop recording", action: #selector(stopRecordingFromMenu), keyEquivalent: "")
                item.target = self
                item.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)
                menu.insertItem(item, at: 0)
                menu.insertItem(.separator(), at: 1)
                recordingMenuItem = item
            }
            recordingMenuItem?.title = "Stop recording · \(TimerDuration.format(captureService.recordingElapsed))"
        } else if let item = recordingMenuItem {
            let index = menu.index(of: item)
            if index >= 0 {
                menu.removeItem(at: index)
                if index < menu.numberOfItems, menu.item(at: index)?.isSeparatorItem == true {
                    menu.removeItem(at: index)
                }
            }
            recordingMenuItem = nil
            Log.shared.info("Recording indicator removed from the menu bar", source: "capture")
        }
    }

    private func installTerminalHotKey() {
        guard !configuration.terminalHotkey.isEmpty else {
            terminalHotkey?.unregister()
            currentTerminalHotKey = nil
            return
        }
        if terminalHotkey == nil {
            terminalHotkey = HotKeyManager(hotKeyID: 3)
            terminalHotkey.onPressed = { [weak self] in self?.toggleTerminalPanel() }
        }
        do {
            currentTerminalHotKey = try terminalHotkey.register(configuration.terminalHotkey)
            Log.shared.info("Terminal hotkey registered: \(currentTerminalHotKey?.display ?? configuration.terminalHotkey)", source: "hotkey")
        } catch {
            currentTerminalHotKey = nil
            Log.shared.warn(
                "Terminal hotkey '\(configuration.terminalHotkey)' unavailable: \(error.localizedDescription)",
                source: "hotkey"
            )
        }
    }

    private func installScratchpadHotKey() {
        guard !configuration.scratchpadHotkey.isEmpty else {
            scratchpadHotkey?.unregister()
            currentScratchpadHotKey = nil
            return
        }
        if scratchpadHotkey == nil {
            scratchpadHotkey = HotKeyManager(hotKeyID: 4)
            scratchpadHotkey.onPressed = { [weak self] in self?.toggleScratchpad() }
        }
        do {
            currentScratchpadHotKey = try scratchpadHotkey.register(configuration.scratchpadHotkey)
            Log.shared.info("Scratchpad hotkey registered: \(currentScratchpadHotKey?.display ?? configuration.scratchpadHotkey)", source: "hotkey")
        } catch {
            currentScratchpadHotKey = nil
            Log.shared.warn(
                "Scratchpad hotkey '\(configuration.scratchpadHotkey)' unavailable: \(error.localizedDescription)",
                source: "hotkey"
            )
        }
    }

    private func installAskHotKey() {
        guard !configuration.askHotkey.isEmpty else {
            askHotkey?.unregister()
            currentAskHotKey = nil
            return
        }
        if askHotkey == nil {
            askHotkey = HotKeyManager(hotKeyID: 5)
            askHotkey.onPressed = { [weak self] in self?.showAsk() }
        }
        do {
            currentAskHotKey = try askHotkey.register(configuration.askHotkey)
            Log.shared.info("Ask hotkey registered: \(currentAskHotKey?.display ?? configuration.askHotkey)", source: "hotkey")
        } catch {
            currentAskHotKey = nil
            Log.shared.warn(
                "Ask hotkey '\(configuration.askHotkey)' unavailable: \(error.localizedDescription)",
                source: "hotkey"
            )
        }
    }

    private func showAsk() {
        guard let panel, let controller = searchController else { return }
        if panel.isVisible, controller.activeTabID == "ask" {
            panel.hide()
            return
        }
        panel.show()
        controller.openAsk()
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
        if controller.scratchpadActive {
            controller.closeScratchpad(save: true)
            return
        }
        if controller.terminalActive {
            controller.closeTerminalPanel()
        }
        controller.openScratchpad()
    }

    private func configureClipboard() {
        clipboardMonitor?.stop()
        guard configuration.clipboard.enabled else {
            clipboardMonitor = nil
            return
        }
        let store = store!
        let limit = configuration.clipboard.maxEntries
        let monitor = ClipboardMonitor()
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
        monitor.start(intervalMs: configuration.clipboard.pollMs)
        clipboardMonitor = monitor
    }

    private func showOnboardingIfNeeded() {
        guard shouldShowOnboarding else { return }
        let view = OnboardingView(
            config: configuration,
            providers: registry.providers.map {
                ProviderSettingsInfo(id: $0.descriptor.id, name: $0.descriptor.name, trigger: $0.descriptor.trigger)
            },
            onFinish: { [weak self] updated in
                guard let self else { return }
                do {
                    try ConfigWriter.render(updated).write(to: self.paths.configFile, atomically: true, encoding: .utf8)
                } catch {
                    self.searchController.setStatus("Could not save setup: \(error.localizedDescription)", duration: 4)
                }
                UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
                self.reload(quiet: false)
            },
            onSkip: { [weak self] in
                UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set up Palette"
        window.appearance = NSAppearance(named: .darkAqua)
        // A clear background left the title bar area blank; match the content.
        window.isOpaque = true
        window.backgroundColor = NSColor(white: 0.10, alpha: 1)
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
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
        guard isInstalled else { return }
        let seeded = "loginItemSeeded"
        guard !UserDefaults.standard.bool(forKey: seeded) else { return }
        UserDefaults.standard.set(true, forKey: seeded)
        // mainApp reports .notFound until it has been registered at least once.
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            Log.shared.info("Registered login item", source: "app")
        } catch {
            Log.shared.warn("Could not register login item: \(error.localizedDescription)", source: "app")
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
        appMenu.addItem(withTitle: "About Palette", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
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
            button.toolTip = "Palette — \(currentHotKey?.display ?? configuration.hotkey)"
        }
        let menu = NSMenu()
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
            reload(quiet: true)
            return
        }
        let signature = themesSignature()
        if signature != lastThemesSignature {
            lastThemesSignature = signature
            themeManager.reload()
        }
        let providers = providersSignature()
        if providers != lastProvidersSignature {
            lastProvidersSignature = providers
            reload(quiet: true)
        }
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

    private func exportWebApps() async {
        do {
            let apps = try await store.webApps()
            if let url = try HammerspoonExport.write(apps, browser: configuration.webAppBrowser) {
                Log.shared.info("Exported \(apps.count) web app(s) to \(url.path)", source: "hammerspoon")
            }
        } catch {
            Log.shared.warn("Could not export web apps to Hammerspoon: \(error.localizedDescription)", source: "hammerspoon")
        }
    }

    func reload(quiet: Bool) {
        guard !reloadInFlight else { return }
        reloadInFlight = true
        defer { reloadInFlight = false }

        let result = ConfigLoader.load(paths: paths)
        configuration = result.config
        startupDiagnostics = result.diagnostics
        ToolLocator.shared.configure(extraPaths: configuration.toolsPath)
        themeManager.typography = configuration.typography
        themeManager.window = configuration.window
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

        if currentHotKey?.display.lowercased() != configuration.hotkey.lowercased()
            || currentClipboardHotKey?.display.lowercased() != configuration.clipboardHotkey.lowercased()
            || currentTerminalHotKey?.display.lowercased() != configuration.terminalHotkey.lowercased()
            || currentScratchpadHotKey?.display.lowercased() != configuration.scratchpadHotkey.lowercased()
            || currentAskHotKey?.display.lowercased() != configuration.askHotkey.lowercased()
            || currentScreenshotHotKey?.display.lowercased() != configuration.screenshotHotkey.lowercased()
            || currentRegionHotKey?.display.lowercased() != configuration.regionScreenshotHotkey.lowercased()
            || currentWindowHotKey?.display.lowercased() != configuration.windowScreenshotHotkey.lowercased()
            || currentRecordingHotKey?.display.lowercased() != configuration.recordingHotkey.lowercased() {
            installHotKey()
        }
        configureClipboard()
        refreshSettingsWindow()
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
            try ConfigWriter.render(configuration).write(to: paths.configFile, atomically: true, encoding: .utf8)
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

    private func showSettings() {
        panel?.hide(activatePrevious: false)
        if let settingsWindow {
            // A closed window keeps its old SwiftUI state; rebuild it so the
            // values reflect config.toml after a reload or manual edit.
            if !settingsWindow.isVisible {
                settingsWindow.contentView = makeSettingsHostingView()
            }
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            settingsWindow.orderFrontRegardless()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Palette Settings"
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        // A themed (not transparent) titlebar keeps AppKit's native window drag.
        window.backgroundColor = themeManager.theme.nsColor(themeManager.theme.palette.bg)
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: themeManager.theme.appearance == "light" ? .aqua : .darkAqua)
        window.contentView = makeSettingsHostingView()
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
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
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Palette-Backup-\(stamp).zip"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Palette-Backup-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: temp, withIntermediateDirectories: true)
            try? manager.copyItem(at: paths.configFile, to: temp.appendingPathComponent("config.toml"))
            try? manager.copyItem(at: paths.themesDir, to: temp.appendingPathComponent("themes"))
            try? manager.copyItem(at: paths.providersDir, to: temp.appendingPathComponent("providers"))
            try? manager.copyItem(at: paths.databaseFile, to: temp.appendingPathComponent("palette.sqlite"))
            for suffix in ["-wal", "-shm"] {
                let source = URL(fileURLWithPath: paths.databaseFile.path + suffix)
                if manager.fileExists(atPath: source.path) {
                    try? manager.copyItem(at: source, to: temp.appendingPathComponent("palette.sqlite" + suffix))
                }
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", temp.path, destination.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "PaletteBackup", code: Int(process.terminationStatus))
            }
            searchController.setStatus("Backup exported to \(destination.lastPathComponent)", duration: 4)
        } catch {
            searchController.setStatus("Backup failed: \(error.localizedDescription)", duration: 5)
        }
        try? manager.removeItem(at: temp)
    }

    private func makeSettingsView() -> SettingsView {
        SettingsView(
            config: configuration,
            keepAwake: keepAwake,
            theme: themeManager.theme,
            themesDirectory: paths.themesDir,
            accessibilityTrusted: pasteboard.isAccessibilityTrusted,
            providerSummary: registry.providers.map {
                "\($0.descriptor.name)  ·  \($0.descriptor.trigger.map { "/\($0)" } ?? "global")"
            },
            providers: registry.providers.map {
                ProviderSettingsInfo(
                    id: $0.descriptor.id,
                    name: $0.descriptor.name,
                    trigger: $0.descriptor.trigger
                )
            },
            diagnostics: startupDiagnostics.map { "\($0.level.rawValue): \($0.message)" },
            onSave: { [weak self] updated in
                self?.saveSettings(updated)
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

    private func saveSettings(_ updated: PaletteConfig) {
        do {
            try ConfigWriter.render(updated).write(to: paths.configFile, atomically: true, encoding: .utf8)
        } catch {
            searchController.setStatus("Could not save settings: \(error.localizedDescription)", duration: 4)
            return
        }
        settingsWindow?.close()
        settingsWindow = nil
        reload(quiet: false)
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
        Task { @MainActor [weak self] in
            await self?.refreshKeepAwakeMenu()
        }
    }

    private func refreshKeepAwakeMenu() async {
        let status = await keepAwake.snapshot()
        keepAwakeToggleItem?.title = status.active ? "Stop Keeping Awake" : "Keep Mac Awake (Indefinitely)"
        keepAwakeToggleItem?.state = status.active ? .on : .off
        keepAwakeClamshellItem?.title = "Clamshell (Lid Closed)"
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
