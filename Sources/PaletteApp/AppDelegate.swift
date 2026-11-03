import AppKit
import Combine
import Foundation
import PaletteCore
import PalettePlatform
import PaletteProviders
import PaletteRuntime
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
    private var searchController: SearchController!
    private var panel: PanelController!
    private var hotkey: HotKeyManager!
    private var clipboardHotkey: HotKeyManager!
    private var statusItem: NSStatusItem!
    private var hostProxy: HostBridgeProxy!
    private var appIndex: AppIndex!
    private var currentHotKey: HotKeySpec?
    private var currentClipboardHotKey: HotKeySpec?
    private var startupDiagnostics: [Diagnostic] = []
    private var themeObserver: NSObjectProtocol?
    private var watcherTimer: Timer?
    private var lastConfigModification: Date?
    private var lastThemesSignature: Date?
    private var lastProvidersSignature: Date?
    private var reloadInFlight = false
    private var settingsWindow: NSWindow?
    private var positionMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        paths = PalettePaths.resolve()
        do {
            try paths.createDirectories()
        } catch {
            fputs("Palette: could not create directories: \(error)\n", stderr)
        }
        Log.shared.configure(url: paths.logFile)
        Log.shared.info("Palette launching from \(Bundle.main.bundlePath)", source: "app")

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
        launcher = LauncherService()
        pasteboard = PasteboardService()
        appIndex = AppIndex()
        hostProxy = HostBridgeProxy()

        themeManager = ThemeManager(paths: paths, selection: configuration.theme, store: store)
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
        wireControllerCallbacks()
        buildPanel()
        buildMainMenu()
        installHotKey()
        configureClipboard()
        buildStatusItem()
        installThemeObserver()

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
                } else if step == "settings" {
                    self.showSettings()
                } else if step == "clipboard" {
                    self.showClipboard()
                } else if step == "exit" {
                    NSApp.terminate(nil)
                    return
                } else if let value = step.dropPrefix("query=") {
                    self.searchController.query = value
                } else if let value = step.dropPrefix("snapshot=") {
                    self.writeSnapshot(to: value)
                } else if let value = step.dropPrefix("settings_snapshot=") {
                    self.writeSettingsSnapshot(to: value)
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
        guard let view = settingsWindow?.contentView else { return }
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
            "r": (15, "r"), "w": (13, "w"),
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

        providers.append(AppProvider(index: appIndex, launcher: launcher))
        providers.append(CalculatorProvider())
        providers.append(EmojiProvider())
        providers.append(WebSearchProvider(
            engines: configuration.webSearchEngines,
            enabled: configuration.webSearchEnabled,
            launcher: launcher
        ))
        providers.append(PinProvider(store: store, bridge: hostProxy))
        providers.append(ClipboardProvider(store: store, bridge: hostProxy))
        providers.append(WebAppProvider(store: store, bridge: hostProxy, browser: configuration.webAppBrowser, onChange: { [weak self] in
            await self?.exportWebApps()
        }))
        providers.append(ZellijProvider(terminal: configuration.terminal, launcher: launcher, bridge: hostProxy))
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
        let controller = PanelController(theme: themeManager.theme, content: hosting)
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

    private func seedUserProviders() {
        let neof = paths.providersDir.appendingPathComponent("neof", isDirectory: true)
        let manifest = neof.appendingPathComponent("provider.toml")
        let oldContent = """
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
        let content = """
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

        let manager = FileManager.default
        if manager.fileExists(atPath: manifest.path) {
            // Migrate only the seed we wrote earlier; never touch a user edit.
            guard let existing = try? String(contentsOf: manifest, encoding: .utf8),
                  existing == oldContent else { return }
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
        themeManager.updateSelection(configuration.theme)
        panel?.anchorOverride = configuration.searchPosition.rawValue
        updatePositionMenu()

        let oldRegistry = registry
        let newRegistry = buildRegistry()
        registry = newRegistry
        searchController.replace(registry: newRegistry, configuration: configuration)

        if currentHotKey?.display.lowercased() != configuration.hotkey.lowercased()
            || currentClipboardHotKey?.display.lowercased() != configuration.clipboardHotkey.lowercased() {
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
                settingsWindow.contentViewController = NSHostingController(rootView: makeSettingsView())
            }
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            settingsWindow.orderFrontRegardless()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Palette Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: makeSettingsView())
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeSettingsView() -> SettingsView {
        SettingsView(
            config: configuration,
            themesDirectory: paths.themesDir,
            onSave: { [weak self] updated in
                self?.saveSettings(updated)
            },
            onOpen: { [weak self] url in
                self?.launcher.openPath(url.path)
            }
        )
    }

    /// Keep an open Settings window in sync when config.toml is reloaded.
    private func refreshSettingsWindow() {
        guard let settingsWindow, settingsWindow.isVisible else { return }
        settingsWindow.contentViewController = NSHostingController(rootView: makeSettingsView())
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
