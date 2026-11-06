import AppKit
import ApplicationServices
import CoreGraphics
import ServiceManagement
import SwiftUI
import PaletteCore
import PalettePlatform

struct ProviderSettingsInfo: Identifiable, Equatable {
    var id: String
    var name: String
    var trigger: String?
}

private enum SettingsTab: Int, CaseIterable, Identifiable {
    case general, appearance, clipboard, search, ask, providers, advanced

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .clipboard: return "Clipboard"
        case .search: return "Search"
        case .ask: return "Ask"
        case .providers: return "Providers"
        case .advanced: return "Advanced"
        }
    }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .appearance: return "paintpalette"
        case .clipboard: return "doc.on.clipboard"
        case .search: return "magnifyingglass"
        case .ask: return "sparkles"
        case .providers: return "square.stack.3d.up"
        case .advanced: return "gearshape.2"
        }
    }
}

private struct SettingsDestination: Identifiable {
    var id: String { "\(tab)-\(title)" }
    var title: String
    var tab: Int
    var keywords: String
}

struct SettingsView: View {
    @State private var config: PaletteConfig
    @State private var engines: [WebSearchEngine]
    @State private var selectedTab = 0
    @State private var saveError: String?
    @State private var launcherRecordToken = 0
    @State private var clipboardRecordToken = 0
    @State private var terminalRecordToken = 0
    @State private var scratchpadRecordToken = 0
    @State private var askRecordToken = 0
    @State private var settingsSearch = ""
    @State private var accessibilityTrusted: Bool
    @State private var askKeyInput = ""
    @State private var askKeyStored: Bool
    @State private var askKeyMessage: String?
    @State private var providerOrder: [String]
    @State private var aliases: [String: String]
    @State private var disabledProviders: [String]
    @State private var terminalShellChoice: String
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var keepAwakeStatus = KeepAwakeStatus()
    @State private var keepAwakeMessage: String?
    @State private var defaultsMessage: String?

    private let keepAwake: KeepAwakeService
    private let theme: Theme
    private let themesDirectory: URL
    private let providerSummary: [String]
    private let providers: [ProviderSettingsInfo]
    private let diagnostics: [String]
    private let onSave: (PaletteConfig) -> Void
    private let onOpen: (URL) -> Void
    private let onExportBackup: () -> Void

    init(
        config: PaletteConfig,
        keepAwake: KeepAwakeService,
        theme: Theme,
        themesDirectory: URL,
        accessibilityTrusted: Bool,
        providerSummary: [String],
        providers: [ProviderSettingsInfo],
        diagnostics: [String],
        onSave: @escaping (PaletteConfig) -> Void,
        onOpen: @escaping (URL) -> Void,
        onExportBackup: @escaping () -> Void
    ) {
        _config = State(initialValue: config)
        _engines = State(initialValue: config.webSearchEngines)
        _accessibilityTrusted = State(initialValue: accessibilityTrusted)
        _askKeyStored = State(initialValue: AskKeychain.hasStoredKey(for: config.ask.endpoint))
        let order = config.providerOrder.isEmpty ? providers.map(\.id) : config.providerOrder
        let ordered = order.filter { id in providers.contains { $0.id == id } }
            + providers.map(\.id).filter { !order.contains($0) }
        _providerOrder = State(initialValue: ordered)
        var aliasState: [String: String] = [:]
        for provider in providers {
            aliasState[provider.id] = (config.providerAliases[provider.id] ?? []).joined(separator: ", ")
        }
        _aliases = State(initialValue: aliasState)
        _disabledProviders = State(initialValue: config.disabledProviders.filter { $0 != "apps" })
        let configuredShell = config.terminalSession.shell.trimmingCharacters(in: .whitespaces)
        let shellName = (configuredShell as NSString).lastPathComponent.lowercased()
        _terminalShellChoice = State(initialValue: configuredShell.isEmpty
            ? "auto"
            : (["fish", "zsh"].contains(shellName) ? shellName : "custom"))
        self.keepAwake = keepAwake
        self.theme = theme
        self.themesDirectory = themesDirectory
        self.providerSummary = providerSummary
        self.providers = providers
        self.diagnostics = diagnostics
        self.onSave = onSave
        self.onOpen = onOpen
        self.onExportBackup = onExportBackup
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search settings", text: $settingsSearch)
                    .textFieldStyle(.plain)
                if !settingsSearch.isEmpty {
                    Button {
                        settingsSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 30)
            .padding(.bottom, 4)

            if settingsSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                settingsTabs
                selectedSettingsContent
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                settingsSearchResults
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 780, height: 660)
        .background(
            ZStack {
                GlassBackdrop(material: .hudWindow)
                theme.color(theme.palette.bg).opacity(theme.window.glass ? theme.window.glassOpacity : 1)
            }
        )
        .preferredColorScheme(theme.appearance == "light" ? .light : .dark)
        .task {
            keepAwakeStatus = await keepAwake.snapshot()
        }
        .alert("Cannot Save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    /// 0 in config means "inherit the theme's `[list] visible_rows`".
    private var visibleRowsBinding: Binding<Int> {
        Binding(
            get: { config.visibleRows > 0 ? config.visibleRows : theme.list.visibleRows },
            set: { config.visibleRows = min(10, max(5, $0)) }
        )
    }

    private var settingsTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { tab in
                    let selected = selectedTab == tab.rawValue
                    Button {
                        selectedTab = tab.rawValue
                    } label: {
                        Label(tab.title, systemImage: tab.icon)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundColor(theme.color(selected ? theme.palette.accent : theme.palette.fgMuted))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(
                                    selected
                                        ? theme.color(theme.palette.accent).opacity(0.18)
                                        : theme.color(theme.palette.elevated).opacity(0.35)
                                )
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    selected
                                        ? theme.color(theme.palette.accent).opacity(0.55)
                                        : theme.color(theme.palette.border).opacity(0.25),
                                    lineWidth: 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color(theme.palette.separator)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch SettingsTab(rawValue: selectedTab) ?? .general {
        case .general: general
        case .appearance: appearance
        case .clipboard: clipboard
        case .search: search
        case .ask: ask
        case .providers: providerSettings
        case .advanced: advanced
        }
    }

    private var configURL: URL {
        PalettePaths.resolve().configFile
    }

    private var destinations: [SettingsDestination] {
        [
            .init(title: "Global shortcuts", tab: 0, keywords: "hotkey shortcut launcher clipboard terminal scratchpad ask record"),
            .init(title: "Apps and editor", tab: 0, keywords: "terminal editor neovide kitty external app"),
            .init(title: "Embedded terminal", tab: 0, keywords: "terminal session zellij tmux fish shell font"),
            .init(title: "Startup", tab: 0, keywords: "login start startup launch item"),
            .init(title: "Permissions", tab: 0, keywords: "accessibility permission paste automation"),
            .init(title: "Launcher position and app order", tab: 0, keywords: "top center alphabetical frequent layout"),
            .init(title: "Themes", tab: 1, keywords: "theme dark light catppuccin gruvbox aetheria"),
            .init(title: "Typography and fonts", tab: 1, keywords: "font family size mono typography"),
            .init(title: "Clipboard history", tab: 2, keywords: "clipboard history entries poll clear retention"),
            .init(title: "Web search", tab: 3, keywords: "web search engine google duckduckgo github youtube"),
            .init(title: "Web app browser", tab: 3, keywords: "browser helium chrome chromium web app"),
            .init(title: "Ask models and API key", tab: 4, keywords: "ask model api key token endpoint history retention"),
            .init(title: "Provider order and aliases", tab: 5, keywords: "provider order alias visibility trigger"),
            .init(title: "Backup and diagnostics", tab: 6, keywords: "backup export restore diagnostics crash log version"),
            .init(title: "Configuration files", tab: 6, keywords: "config providers themes log folder file"),
        ]
    }

    private var settingsSearchResults: some View {
        let query = settingsSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? [] : destinations.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.keywords.localizedCaseInsensitiveContains(query)
        }
        return List(matches) { destination in
            Button {
                selectedTab = destination.tab
                settingsSearch = ""
            } label: {
                HStack {
                    Text(destination.title)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
        .overlay {
            if matches.isEmpty {
                Text("No matching settings")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detectDefaults() {
        let editors = ["neovide", "Visual Studio Code", "Cursor", "Zed", "Sublime Text"]
        if let editor = editors.first(where: {
            ToolLocator.shared.appPath(named: $0) != nil
        }) {
            config.editorOpenWith = editor
        }
        if let browser = BrowserCatalog.chromiumChoices.first(where: {
            ToolLocator.shared.appPath(named: $0) != nil
        }) {
            config.webAppBrowser = browser
        }
        defaultsMessage = "Detected installed editor and browser where available."
    }

    private func resetDefaults() {
        config.editorOpenWith = "neovide"
        config.terminal = "kitty"
        config.terminalApp = "kitty"
        config.webAppBrowser = "Helium"
        config.theme = ThemeSelection()
        config.ask = AskConfig()
        config.terminalSession = TerminalSessionConfig()
        config.appSort = .alphabetical
        config.searchPosition = .top
        defaultsMessage = "App, theme, Ask, and terminal defaults reset. Hotkeys and scopes were left alone."
    }

    private var keepAwakeBinding: Binding<Bool> {
        Binding(
            get: { keepAwakeStatus.active },
            set: { enabled in
                Task { @MainActor in
                    do {
                        try await keepAwake.setKeepAwake(enabled)
                        keepAwakeMessage = nil
                    } catch {
                        keepAwakeMessage = error.localizedDescription
                    }
                    keepAwakeStatus = await keepAwake.snapshot()
                }
            }
        )
    }

    private var clamshellBinding: Binding<Bool> {
        Binding(
            get: { keepAwakeStatus.clamshell },
            set: { enabled in
                Task { @MainActor in
                    do {
                        try await keepAwake.setClamshell(enabled)
                        keepAwakeMessage = nil
                    } catch {
                        keepAwakeMessage = error.localizedDescription
                    }
                    keepAwakeStatus = await keepAwake.snapshot()
                }
            }
        )
    }

    private var keepAwakeSummary: String {
        if keepAwakeStatus.active {
            let left = keepAwakeStatus.endsAt == nil
                ? "indefinitely"
                : "\(keepAwakeStatus.remainingLabel) left"
            return "Keeping awake \(left) · Clamshell \(keepAwakeStatus.clamshell ? "on" : "off")."
        }
        if keepAwakeStatus.clamshell {
            return "Clamshell armed · AC power only."
        }
        return "Off."
    }

    private var shortcutSummary: String {
        let entries = [
            ("Launcher", config.hotkey),
            ("Clipboard", config.clipboardHotkey),
            ("Terminal", config.terminalHotkey),
            ("Scratchpad", config.scratchpadHotkey),
            ("Ask", config.askHotkey),
        ].filter { !$0.1.isEmpty }
        let values = entries.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        return hasShortcutConflict ? "Conflict: each global shortcut must be unique." : values
    }

    private var hasShortcutConflict: Bool {
        let values = [
            config.hotkey,
            config.clipboardHotkey,
            config.terminalHotkey,
            config.scratchpadHotkey,
            config.askHotkey,
        ].filter { !$0.isEmpty }.map { $0.lowercased() }
        return Set(values).count != values.count
    }

    private var general: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Launcher shortcut") {
                    HStack(spacing: 6) {
                        ShortcutRecorder(
                            value: $config.hotkey,
                            label: "Launcher hotkey",
                            recordToken: launcherRecordToken
                        )
                        .frame(width: 170, height: 26)
                        Button("Record") { launcherRecordToken += 1 }
                            .controlSize(.small)
                            .accessibilityLabel("Record launcher hotkey")
                    }
                }
                LabeledContent("Clipboard shortcut") {
                    HStack(spacing: 6) {
                        ShortcutRecorder(
                            value: $config.clipboardHotkey,
                            label: "Clipboard hotkey",
                            recordToken: clipboardRecordToken
                        )
                        .frame(width: 170, height: 26)
                        Button("Record") { clipboardRecordToken += 1 }
                            .controlSize(.small)
                            .accessibilityLabel("Record clipboard hotkey")
                    }
                }
                LabeledContent("Terminal shortcut") {
                    HStack(spacing: 6) {
                        ShortcutRecorder(
                            value: $config.terminalHotkey,
                            label: "Terminal hotkey",
                            recordToken: terminalRecordToken
                        )
                        .frame(width: 170, height: 26)
                        Button("Record") { terminalRecordToken += 1 }
                            .controlSize(.small)
                            .accessibilityLabel("Record terminal hotkey")
                    }
                }
                LabeledContent("Scratchpad shortcut") {
                    HStack(spacing: 6) {
                        ShortcutRecorder(
                            value: $config.scratchpadHotkey,
                            label: "Scratchpad hotkey",
                            recordToken: scratchpadRecordToken
                        )
                        .frame(width: 170, height: 26)
                        Button("Record") { scratchpadRecordToken += 1 }
                            .controlSize(.small)
                            .accessibilityLabel("Record scratchpad hotkey")
                    }
                }
                LabeledContent("Ask shortcut") {
                    HStack(spacing: 6) {
                        ShortcutRecorder(
                            value: $config.askHotkey,
                            label: "Ask hotkey",
                            recordToken: askRecordToken
                        )
                        .frame(width: 170, height: 26)
                        Button("Record") { askRecordToken += 1 }
                            .controlSize(.small)
                            .accessibilityLabel("Record Ask hotkey")
                    }
                }
                Text("Click Record, then press the shortcut you want. Save applies it immediately; clear an optional shortcut to disable it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(shortcutSummary)
                    .font(.caption)
                    .foregroundStyle(hasShortcutConflict ? .red : .secondary)
            }
            Section("Keep Awake") {
                Toggle("Keep Mac Awake", isOn: keepAwakeBinding)
                Toggle("Clamshell Mode (Lid Closed)", isOn: clamshellBinding)
                Text(keepAwakeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let keepAwakeMessage {
                    Text(keepAwakeMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Clamshell uses the standard administrator prompt and keeps working with the lid shut only on AC power. Turning it off leaves an active keep-awake timer alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Defaults") {
                TextField("Editor", text: $config.editorOpenWith)
                TextField("Terminal", text: $config.terminalApp)
                Picker("Web app browser", selection: $config.webAppBrowser) {
                    ForEach(BrowserCatalog.chromiumChoices, id: \.self) { browser in
                        Text(browser).tag(browser)
                    }
                }
                Picker("Theme", selection: $config.theme.dark) {
                    ForEach(themeNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Picker("Ask model", selection: $config.ask.model) {
                    ForEach(AskModel.models(for: config.ask.endpoint)) { model in
                        Text(model.free ? "FREE · \(model.name)" : "\(model.name) · \(model.note)")
                            .tag(model.id)
                    }
                }
                HStack {
                    Button("Detect Installed Apps") { detectDefaults() }
                    Button("Reset App and Theme Defaults") { resetDefaults() }
                }
                if let defaultsMessage {
                    Text(defaultsMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("These are Palette's opinionated defaults. Change them here or in the sections below; reset only affects app, theme, Ask, and terminal-session settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Apps") {
                TextField("Terminal", text: $config.terminalApp)
                TextField("Editor", text: $config.editorOpenWith)
                Text("Used by projects, commands, Zellij, and Bitwarden. Examples: kitty, Terminal, neovide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Embedded terminal") {
                Picker("Session", selection: $config.terminalSession.multiplexer) {
                    Text("Auto").tag(TerminalMultiplexer.auto)
                    Text("Zellij").tag(TerminalMultiplexer.zellij)
                    Text("tmux").tag(TerminalMultiplexer.tmux)
                    Text("Plain shell").tag(TerminalMultiplexer.none)
                }
                TextField("Session name", text: $config.terminalSession.name)
                Picker("Shell", selection: $terminalShellChoice) {
                    Text("Auto (fish, then zsh)").tag("auto")
                    Text("Fish").tag("fish")
                    Text("Zsh").tag("zsh")
                    Text("Custom…").tag("custom")
                }
                if terminalShellChoice == "custom" {
                    TextField("Custom shell executable", text: $config.terminalSession.shell)
                }
                TextField("Font family", text: $config.terminalSession.font)
                Stepper(
                    "Font size: \(config.terminalSession.fontSize == 0 ? "auto" : "\(Int(config.terminalSession.fontSize)) pt")",
                    value: $config.terminalSession.fontSize,
                    in: 0...48,
                    step: 1
                )
                Text("Empty font and size auto-detect Kitty's font, then the theme mono font. Use a Nerd Font for icons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Auto uses Zellij, then tmux, then a plain shell. Plain shell sessions end when the panel closes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Permissions") {
                HStack {
                    Image(systemName: accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityTrusted ? .green : .orange)
                    Text("Accessibility")
                    Spacer()
                    Text(accessibilityTrusted ? "Enabled" : "Not granted")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open Accessibility Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Check Again") {
                        accessibilityTrusted = AXIsProcessTrusted()
                    }
                    .controlSize(.small)
                }
                Text("Needed for direct paste and recording system shortcuts. A new install may require granting once; subsequent updates keep the same signature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Text("Applies immediately. If macOS asks for approval, allow Palette under System Settings > General > Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Launcher") {
                Picker("Opens at", selection: $config.searchPosition) {
                    Text("Top").tag(SearchPosition.top)
                    Text("Center").tag(SearchPosition.center)
                }
                .pickerStyle(.segmented)
                Text("Top drops down from the menu bar; Center opens in the middle of the screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("App order", selection: $config.appSort) {
                    Text("Alphabetical").tag(AppSort.alphabetical)
                    Text("Most used").tag(AppSort.frequent)
                }
                Stepper(value: visibleRowsBinding, in: 5...10) {
                    LabeledContent("Visible rows", value: "\(visibleRowsBinding.wrappedValue)")
                }
                Text("Rows shown before scrolling. This sets the panel height for every provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var appearance: some View {
        Form {
            Section("Theme") {
                Picker("Mode", selection: $config.theme.mode) {
                    Text("Auto").tag(ThemeMode.auto)
                    Text("Dark").tag(ThemeMode.dark)
                    Text("Light").tag(ThemeMode.light)
                }
                .pickerStyle(.segmented)
                Picker("Dark theme", selection: $config.theme.dark) {
                    ForEach(themeNames, id: \.self) { Text(displayName($0)).tag($0) }
                }
                Picker("Light theme", selection: $config.theme.light) {
                    ForEach(themeNames, id: \.self) { Text(displayName($0)).tag($0) }
                }
                Button("Open Themes Folder") { onOpen(PalettePaths.resolve().themesDir) }
            }
            Section("Typography") {
                Picker("UI family", selection: $config.typography.uiFamily) {
                    Text("Inherit from theme").tag("")
                    ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                TextField("Or type a family name", text: $config.typography.uiFamily)
                Stepper(
                    "UI size: \(config.typography.uiSize == 0 ? "theme" : "\(Int(config.typography.uiSize)) pt")",
                    value: $config.typography.uiSize,
                    in: 0...48,
                    step: 1
                )
                Picker("Mono family", selection: $config.typography.monoFamily) {
                    Text("Inherit from theme").tag("")
                    ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                TextField("Or type a mono family name", text: $config.typography.monoFamily)
                Stepper(
                    "Mono size: \(config.typography.monoSize == 0 ? "theme" : "\(Int(config.typography.monoSize)) pt")",
                    value: $config.typography.monoSize,
                    in: 0...48,
                    step: 1
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview").font(.caption).foregroundStyle(.secondary)
                    Text("Palette — quick, local, yours")
                        .font(.custom(
                            config.typography.uiFamily.isEmpty ? "SF Pro Text" : config.typography.uiFamily,
                            size: config.typography.uiSize == 0 ? 14 : config.typography.uiSize
                        ))
                    Text("mono: glitch in the matrix")
                        .font(.custom(
                            config.typography.monoFamily.isEmpty ? "Menlo" : config.typography.monoFamily,
                            size: config.typography.monoSize == 0 ? 12 : config.typography.monoSize
                        ))
                        .foregroundStyle(.secondary)
                }
                Button("Reset to Theme") {
                    config.typography = TypographyConfig()
                }
            }
            Section {
                Text("Theme files use TOML. See THEMING.md; saving this window reloads the active theme.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var clipboard: some View {
        Form {
            Section("History") {
                Toggle("Record clipboard history", isOn: $config.clipboard.enabled)
                Stepper("Keep \(config.clipboard.maxEntries) entries", value: $config.clipboard.maxEntries, in: 50...50_000, step: 500)
                Stepper("Poll every \(config.clipboard.pollMs) ms", value: $config.clipboard.pollMs, in: 200...2_000, step: 50)
                Stepper("Clear secrets after \(config.clipboard.clearAfterMs / 1_000) s", value: $config.clipboard.clearAfterMs, in: 0...300_000, step: 5_000)
            }
            Section {
                Text("Text and PNG images are stored. Anything marked concealed by another app is never recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var search: some View {
        Form {
            Section("Web search") {
                Toggle("Show web results in search", isOn: $config.webSearchEnabled)
                Text("When a query does not match an app or file, Palette offers a browser search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(webSearchChoices) { engine in
                    Toggle(engine.name, isOn: Binding(
                        get: { engines.contains { $0.id == engine.id } },
                        set: { enabled in
                            if enabled {
                                if !engines.contains(where: { $0.id == engine.id }) {
                                    engines.append(engine)
                                }
                            } else {
                                engines.removeAll { $0.id == engine.id }
                            }
                        }
                    ))
                }
            }
            DisclosureGroup("Advanced: custom engines") {
                ForEach($engines) { $engine in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: $engine.name)
                        TextField("Search URL with {query}", text: $engine.urlTemplate)
                        Button("Remove", role: .destructive) {
                            engines.removeAll { $0.id == engine.id }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 3)
                }
                Button("Add Engine") {
                    engines.append(WebSearchEngine(
                        name: "New Engine",
                        urlTemplate: "https://example.com/?q={query}"
                    ))
                }
            }
            Section("Web apps") {
                Picker("Open web apps in", selection: $config.webAppBrowser) {
                    ForEach(BrowserCatalog.chromiumChoices, id: \.self) { Text($0).tag($0) }
                }
                Text("Chromium-based browsers only. Helium is the default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var ask: some View {
        Form {
            Section("Model") {
                Picker("Provider", selection: $config.ask.endpoint) {
                    ForEach(AskEndpoint.allCases, id: \.self) { endpoint in
                        Text(endpoint.displayName).tag(endpoint)
                    }
                }
                .onChange(of: config.ask.endpoint) { _, _ in
                    normalizeAskModel()
                    askKeyStored = AskKeychain.hasStoredKey(for: config.ask.endpoint)
                    askKeyMessage = nil
                }
                Picker("Model", selection: $config.ask.model) {
                    ForEach(AskModel.models(for: config.ask.endpoint)) { model in
                        Text(model.free ? "FREE · \(model.name)" : "\(model.name) · \(model.note)")
                            .tag(model.id)
                    }
                }
                TextField("Max answer tokens", value: $config.ask.maxTokens, format: .number)
                Toggle("Fall back to free or small models when quota runs out", isOn: $config.ask.fallback)
                Text("Free models are listed first. If a free model is rate-limited, Ask tries the next free option, then the cheapest paid model from an endpoint where you have a key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("API key") {
                if askKeyStored {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Key saved locally (encrypted, user-only)")
                        Spacer()
                        Button("Clear Key", role: .destructive) {
                            AskKeychain.delete(endpoint: config.ask.endpoint)
                            askKeyStored = false
                            askKeyInput = ""
                            askKeyMessage = "Key removed."
                        }
                    }
                    Text("The saved value is never shown in Palette or written to config.toml.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    SecureField("Paste \(config.ask.endpoint.displayName) API key", text: $askKeyInput)
                    HStack {
                        Button("Save Key") {
                            saveAskKey()
                        }
                        .disabled(askKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                    }
                    Text("The key is saved immediately in an encrypted user-only file. After saving, Palette only shows that a key exists.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let askKeyMessage {
                    Text(askKeyMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("History") {
                Stepper("Keep \(config.ask.maxHistory) questions and answers", value: $config.ask.maxHistory, in: 10...20_000, step: 10)
                Stepper("Delete answers older than \(config.ask.retentionDays) days", value: $config.ask.retentionDays, in: 1...3_650, step: 1)
                Text("Ask History is the History sub-tab under /ask. Rows show the model, endpoint, age, duration, and token count.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Keys can also come from OPENCODE_API_KEY, OPENCODE_GO_API_KEY, or OPENAI_API_KEY for a shell-launched build. The app never logs a key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            normalizeAskModel()
            askKeyStored = AskKeychain.hasStoredKey(for: config.ask.endpoint)
        }
    }

    private var providerSettings: some View {
        Form {
            Section("Visible tabs") {
                Text("Turn off providers you do not use. Hidden providers disappear from the tab bar and Tab cycling; apps always stay visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(allProviderIDs, id: \.self) { id in
                    Toggle(providerName(id), isOn: Binding(
                        get: { !disabledProviders.contains(id) },
                        set: { enabled in
                            if enabled {
                                disabledProviders.removeAll { $0 == id }
                            } else if !disabledProviders.contains(id) {
                                disabledProviders.append(id)
                            }
                        }
                    ))
                }
            }
            Section("Order") {
                Text("Use the arrows to move a provider left or right in the tab bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(providerOrder.enumerated()), id: \.element) { index, id in
                    HStack {
                        Text(providerName(id))
                        Spacer()
                        Button {
                            guard index > 0 else { return }
                            providerOrder.swapAt(index, index - 1)
                        } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                        Button {
                            guard index + 1 < providerOrder.count else { return }
                            providerOrder.swapAt(index, index + 1)
                        } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.borderless)
                            .disabled(index + 1 == providerOrder.count)
                    }
                }
            }
            DisclosureGroup("Aliases (optional)") {
                Text("An alias is another word that opens the same provider. Commas separate aliases.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(providers) { provider in
                    TextField(
                        "\(provider.name) aliases",
                        text: Binding(
                            get: { aliases[provider.id] ?? "" },
                            set: { aliases[provider.id] = $0 }
                        )
                    )
                }
            }
            Section("Files") {
                Button("Open Providers Folder") { onOpen(PalettePaths.resolve().providersDir) }
                Button("Open commands.toml") {
                    onOpen(PalettePaths.resolve().configDir.appendingPathComponent("commands.toml"))
                }
                Text("Add your own provider by creating a folder under providers/ with a provider.toml. User providers override bundled ones with the same id. Press ⌘R after editing files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var advanced: some View {
        Form {
            Section("Configuration") {
                TextField("Command prefix", text: $config.providerPrefix)
                Text("Prefix for provider commands such as /clip and /port. Usually /.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open config.toml") { onOpen(configURL) }
                Button("Open Themes Folder") { onOpen(PalettePaths.resolve().themesDir) }
                Button("Open Log") { onOpen(PalettePaths.resolve().logFile) }
                Text("Settings writes this file for you. Edit it directly only for options that are not in this window, then press ⌘R.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Backup & diagnostics") {
                Button("Export Backup…") { onExportBackup() }
                Button("Open Crash Log") {
                    onOpen(PalettePaths.resolve().stateDir.appendingPathComponent("crash.log"))
                }
                if diagnostics.isEmpty {
                    Text("No startup diagnostics.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(diagnostics, id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("About") {
                LabeledContent("Version") {
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                }
                Button("Copy Update Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew upgrade --cask palette", forType: .string)
                }
                Text("Update with the Homebrew cask; the app has no self-updater.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var webSearchChoices: [WebSearchEngine] {
        var result = WebSearchEngine.defaults
        for engine in engines where !result.contains(where: { $0.id == engine.id }) {
            result.append(engine)
        }
        return result
    }

    private var themeNames: [String] {
        ThemeLoader.catalog(themesDirectory: themesDirectory).map(\.name)
    }

    private var fontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    private func providerName(_ id: String) -> String {
        providers.first(where: { $0.id == id })?.name ?? id
    }

    private var allProviderIDs: [String] {
        (providerOrder + disabledProviders).reduce(into: [String]()) { result, id in
            if id != "apps", !result.contains(id) { result.append(id) }
        }
    }

    private func displayName(_ name: String) -> String {
        ThemeLoader.catalog(themesDirectory: themesDirectory).first(where: { $0.name == name })?.displayName
            ?? name.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    private func saveAskKey() {
        let trimmed = askKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if AskKeychain.save(trimmed, for: config.ask.endpoint) {
            askKeyStored = true
            askKeyInput = ""
            askKeyMessage = "Key saved. It will not be shown again."
        } else {
            askKeyMessage = "Could not save the key to the local key file."
        }
    }

    private func normalizeAskModel() {
        let models = AskModel.models(for: config.ask.endpoint)
        if !models.contains(where: { $0.id == config.ask.model }) {
            config.ask.model = models.first?.id ?? AskModel.defaultModel.id
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            saveError = "Could not update the login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func save() {
        guard HotKeySpec.parse(config.hotkey) != nil else {
            saveError = "The launcher hotkey is not a valid shortcut. Click the field and press the keys you want."
            return
        }
        guard HotKeySpec.parse(config.clipboardHotkey) != nil else {
            saveError = "The clipboard hotkey is not a valid shortcut. Click the field and press the keys you want."
            return
        }
        let optional = [
            ("terminal", config.terminalHotkey),
            ("scratchpad", config.scratchpadHotkey),
            ("Ask", config.askHotkey),
        ]
        for (name, value) in optional where !value.isEmpty {
            guard HotKeySpec.parse(value) != nil else {
                saveError = "The \(name) hotkey is not a valid shortcut. Click the field and press the keys you want."
                return
            }
        }
        let shortcuts = [
            config.hotkey,
            config.clipboardHotkey,
            config.terminalHotkey,
            config.scratchpadHotkey,
            config.askHotkey,
        ].filter { !$0.isEmpty }.map { $0.lowercased() }
        if Set(shortcuts).count != shortcuts.count {
            saveError = "Each global shortcut must be unique."
            return
        }
        let browser = config.webAppBrowser
        if let error = BrowserCatalog.validationError(for: browser) {
            saveError = error
            return
        }
        config.webSearchEngines = engines.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && $0.urlTemplate.contains("{query}")
        }
        normalizeAskModel()
        var aliasMap: [String: [String]] = [:]
        var used = Set(providers.compactMap { $0.trigger?.lowercased() })
        for provider in providers {
            let words = (aliases[provider.id] ?? "")
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map(String.init)
                .filter { !$0.isEmpty }
            var accepted: [String] = []
            for word in words {
                guard word.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
                    saveError = "Alias “\(word)” is not a valid trigger word."
                    return
                }
                let key = word.lowercased()
                guard used.insert(key).inserted else {
                    saveError = "Alias “\(word)” is already used by another trigger."
                    return
                }
                accepted.append(word)
            }
            if !accepted.isEmpty { aliasMap[provider.id] = accepted }
        }
        config.providerAliases = aliasMap
        config.providerOrder = providerOrder
        config.disabledProviders = disabledProviders.filter { $0 != "apps" }
        switch terminalShellChoice {
        case "auto": config.terminalSession.shell = ""
        case "fish", "zsh": config.terminalSession.shell = terminalShellChoice
        default:
            if config.terminalSession.shell.trimmingCharacters(in: .whitespaces).isEmpty {
                config.terminalSession.shell = ""
            }
        }
        onSave(config)
    }
}

/// Borderless AppKit field that records a real key press instead of asking the
/// user to type something like "opt+space".
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var value: String
    var label: String
    var recordToken: Int = 0

    final class Coordinator {
        var lastToken: Int = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.label = label
        view.value = value
        view.onChange = { recorded in
            value = recorded
        }
        context.coordinator.lastToken = recordToken
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.label = label
        nsView.value = value
        guard recordToken != context.coordinator.lastToken else { return }
        context.coordinator.lastToken = recordToken
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

final class RecorderView: NSView {
    var value: String = "" {
        didSet {
            needsDisplay = true
            setAccessibilityValue(value)
        }
    }
    var label: String = "Shortcut" {
        didSet { setAccessibilityLabel(label) }
    }
    var onChange: ((String) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Press the shortcut keys you want to use")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    deinit {
        stopRecording()
    }

    override var acceptsFirstResponder: Bool { true }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        return true
    }

    override func becomeFirstResponder() -> Bool {
        startRecording()
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    /// A local key monitor never sees reserved combinations such as ⌘Space:
    /// macOS consumes them before AppKit dispatches keyDown. A session event
    /// tap at the head of the stream can record and suppress the combination
    /// while the recorder is active, which is how shortcut recorders capture
    /// system-reserved keys.
    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        needsDisplay = true

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: recorderEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Without Accessibility the local keyDown path still records
            // ordinary combinations; reserved system keys will not arrive.
            Log.shared.warn("Shortcut recorder could not create an event tap; Accessibility is required for system shortcuts", source: "settings")
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.shared.info("Shortcut recorder event tap started", source: "settings")

        NotificationCenter.default.addObserver(
            self, selector: #selector(recordingContextLost),
            name: NSWindow.didResignKeyNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(recordingContextLost),
            name: NSApplication.didResignActiveNotification, object: nil
        )
    }

    @objc private func recordingContextLost() {
        finishRecording(nil)
    }

    private func stopRecording() {
        guard isRecording || eventTap != nil || runLoopSource != nil else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        isRecording = false
        Log.shared.info("Shortcut recorder event tap stopped", source: "settings")
    }

    fileprivate func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isRecording, type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }
        // Consume the matching key-up as well, so a reserved shortcut cannot
        // fire after we record its key-down.
        guard type == .keyDown else { return nil }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if code == 53 {
            finishRecording(nil)
            return nil
        }
        guard let nsEvent = NSEvent(cgEvent: event),
              let spec = HotKeySpec.from(event: nsEvent) else {
            NSSound.beep()
            return nil
        }
        finishRecording(spec.display)
        return nil
    }

    private func finishRecording(_ display: String?) {
        stopRecording()
        if let display {
            value = display
            onChange?(display)
        }
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            finishRecording(nil)
            return
        }
        guard let spec = HotKeySpec.from(event: event) else {
            NSSound.beep()
            return
        }
        finishRecording(spec.display)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let focused = window?.firstResponder === self
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        (focused ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        path.lineWidth = focused ? 2 : 1
        path.stroke()

        let text = focused && value.isEmpty ? "Press shortcut…" : (value.isEmpty ? "Click to record" : value)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: value.isEmpty ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: 9, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}

private func recorderEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let view = Unmanaged<RecorderView>.fromOpaque(refcon).takeUnretainedValue()
    return view.handleEventTap(type: type, event: event)
}