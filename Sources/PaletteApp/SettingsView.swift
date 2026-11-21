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
    var isGlobal: Bool
}

/// One editable alias row. `enabled` is the effective set written to config;
/// unchecked rows stay visible so a removed built-in alias can come back.
private struct ProviderAliasEntry: Identifiable, Equatable {
    var id = UUID()
    var word: String
    var enabled: Bool
}

private enum SettingsTab: Int, CaseIterable, Identifiable {
    // Appended last: raw values are a public contract (settings_tab=<index>).
    case general, launcher, appearance, shortcuts, clipboard, search, capture, ask, providers, advanced, terminal, cheatsheets

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .launcher: return "Launcher"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .clipboard: return "Clipboard"
        case .search: return "Search"
        case .capture: return "Capture"
        case .ask: return "Ask"
        case .providers: return "Providers"
        case .advanced: return "Advanced"
        case .terminal: return "Terminal"
        case .cheatsheets: return "Cheatsheets"
        }
    }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .launcher: return "rectangle.topthird.inset.filled"
        case .appearance: return "paintpalette"
        case .shortcuts: return "command"
        case .clipboard: return "doc.on.clipboard"
        case .search: return "magnifyingglass"
        case .capture: return "camera"
        case .ask: return "sparkles"
        case .providers: return "square.stack.3d.up"
        case .advanced: return "gearshape.2"
        case .terminal: return "apple.terminal"
        case .cheatsheets: return "book"
        }
    }
    /// Fixed tile colours like System Settings, deliberately not read from the
    /// theme so the icons look the same in light and dark.
    var tint: Color {
        switch self {
        case .general: return Color(red: 0.55, green: 0.56, blue: 0.58)
        case .launcher: return Color(red: 0.00, green: 0.48, blue: 1.00)
        case .appearance: return Color(red: 0.69, green: 0.32, blue: 0.87)
        case .shortcuts: return Color(red: 1.00, green: 0.58, blue: 0.00)
        case .clipboard: return Color(red: 0.19, green: 0.69, blue: 0.78)
        case .search: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .capture: return Color(red: 0.96, green: 0.29, blue: 0.35)
        case .ask: return Color(red: 0.72, green: 0.38, blue: 0.95)
        case .providers: return Color(red: 0.61, green: 0.44, blue: 0.31)
        case .advanced: return Color(red: 0.42, green: 0.45, blue: 0.50)
        case .terminal: return Color(red: 0.06, green: 0.62, blue: 0.52)
        case .cheatsheets: return Color(red: 0.42, green: 0.42, blue: 0.88)
        }
    }
}

private struct SettingsTabGroup: Identifiable {
    var id: String { title }
    var title: String
    var tabs: [SettingsTab]
}

private extension SettingsTab {
    static let sidebarGroups: [SettingsTabGroup] = [
        SettingsTabGroup(title: "General", tabs: [.general, .launcher, .appearance]),
        SettingsTabGroup(title: "Features", tabs: [.shortcuts, .clipboard, .search, .capture, .terminal, .ask, .cheatsheets]),
        SettingsTabGroup(title: "System", tabs: [.providers, .advanced]),
    ]
}

/// A System Settings–style tile: a small rounded gradient square holding a
/// white symbol, so each sidebar row reads at a glance.
private struct SettingsTabIcon: View {
    var tab: SettingsTab

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tab.tint, tab.tint.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 22, height: 22)
            .overlay {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// Every editable field in Settings and Onboarding uses the same bordered
/// field, so a setting looks like an input instead of another label.
extension View {
    func settingsField() -> some View {
        textFieldStyle(.roundedBorder)
    }
}

private struct SettingsDestination: Identifiable {
    var id: String { "\(tab.rawValue)-\(title)" }
    var title: String
    var tab: SettingsTab
    /// Matches the `.searchTarget(_:)` id on the row or section this entry
    /// points at, so picking a result can scroll to it.
    var anchor: String
    var keywords: String
}

/// A picked search result. `token` lets the same anchor fire twice in a row.
private struct SettingsJump: Equatable {
    var anchor: String
    var token: Int
}

private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private extension EnvironmentValues {
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

/// Marks a search target: gives the row a stable scroll id and pulses a
/// rounded background behind its label — not the whole Form row — when a
/// search result lands on it.
private struct SettingsSearchTarget: ViewModifier {
    @Environment(\.settingsHighlight) private var highlight
    let anchor: String

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(highlight == anchor ? 0.3 : 0))
                    // Negative insets keep the label where it was when idle.
                    .padding(.horizontal, -5)
                    .padding(.vertical, -2)
            }
            .animation(.easeInOut(duration: 0.3), value: highlight)
    }
}

private extension View {
    func searchTarget(_ anchor: String) -> some View {
        modifier(SettingsSearchTarget(anchor: anchor))
    }
}

struct SettingsView: View {
    @State private var config: PaletteConfig
    @State private var engines: [WebSearchEngine]
    @State private var selectedTab: SettingsTab = .general
    @State private var saveError: String?
    @State private var launcherRecordToken = 0
    @State private var clipboardRecordToken = 0
    @State private var terminalRecordToken = 0
    @State private var scratchpadRecordToken = 0
    @State private var askRecordToken = 0
    @State private var screenshotRecordToken = 0
    @State private var regionRecordToken = 0
    @State private var windowRecordToken = 0
    @State private var recordingRecordToken = 0
    @State private var settingsSearch = ""
    @State private var settingsJump: SettingsJump?
    @State private var settingsHighlight: String?
    @State private var accessibilityTrusted: Bool
    @State private var askKeyInput = ""
    @State private var askKeyStored: Bool
    @State private var askKeyMessage: String?
    @State private var providerOrder: [String]
    @State private var providerAliasesDraft: [String: [ProviderAliasEntry]]
    @State private var newAlias: [String: String]
    @State private var disabledProviders: [String]
    @State private var globalProviders: [String]
    @State private var bookmarks: [Bookmark] = []
    @State private var bookmarksLoaded = false
    @State private var terminalShellChoice: String
    @State private var cheatsheetFolders: [String]
    @State private var cheatsheetExtensions: String
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
    private let providerNameWidth: CGFloat = 112
    private let providerDefaultWidth: CGFloat = 62
    private let providerTriggerWidth: CGFloat = 122
    private let providerOrderWidth: CGFloat = 36
    private let onSave: (PaletteConfig) -> String?
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
        onSave: @escaping (PaletteConfig) -> String?,
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
        var aliasState: [String: [ProviderAliasEntry]] = [:]
        for id in ordered + Array(config.providerAliases.keys) where aliasState[id] == nil {
            var entries: [ProviderAliasEntry] = []
            var seen = Set<String>()
            for word in ProviderAliases.defaults[id] ?? [] {
                guard seen.insert(word.lowercased()).inserted else { continue }
                let active = config.providerAliases[id]?.contains {
                    $0.lowercased() == word.lowercased()
                } ?? false
                entries.append(ProviderAliasEntry(word: word, enabled: active))
            }
            for word in config.providerAliases[id] ?? [] {
                let trimmed = word.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
                entries.append(ProviderAliasEntry(word: trimmed, enabled: true))
            }
            aliasState[id] = entries
        }
        _providerAliasesDraft = State(initialValue: aliasState)
        _newAlias = State(initialValue: [String: String]())
        _disabledProviders = State(initialValue: config.disabledProviders.filter { $0 != "apps" })
        _globalProviders = State(initialValue: config.globalProviders)
        let configuredShell = config.terminalSession.shell.trimmingCharacters(in: .whitespaces)
        let shellName = (configuredShell as NSString).lastPathComponent.lowercased()
        _terminalShellChoice = State(initialValue: configuredShell.isEmpty
            ? "auto"
            : (["fish", "zsh"].contains(shellName) ? shellName : "custom"))
        _cheatsheetFolders = State(initialValue: config.cheatsheets.folders)
        _cheatsheetExtensions = State(initialValue: config.cheatsheets.extensions.joined(separator: ", "))
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
        NavigationSplitView {
            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                List(selection: $selectedTab) {
                    ForEach(SettingsTab.sidebarGroups) { group in
                        Section(group.title) {
                            ForEach(group.tabs) { tab in
                                Label {
                                    Text(tab.title)
                                } icon: {
                                    SettingsTabIcon(tab: tab)
                                }
                                .font(theme.font(size: 12))
                                .tag(tab)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .background(theme.color(theme.palette.bg).opacity(0.35))
            .navigationSplitViewColumnWidth(220)
        } detail: {
            VStack(spacing: 0) {
                if settingsSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                    ScrollViewReader { proxy in
                        selectedSettingsContent
                            .scrollContentBackground(.hidden)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .environment(\.settingsHighlight, settingsHighlight)
                            .task(id: settingsJump) {
                                await jumpToSearchTarget(settingsJump, proxy: proxy)
                            }
                    }
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
            .navigationTitle(selectedTab.title)
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteSettingsTab)) { note in
            guard let index = note.object as? Int, let tab = SettingsTab(rawValue: index) else { return }
            selectedTab = tab
        }
        .frame(minWidth: 820, minHeight: 560)
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

    /// Hand-built rather than `.searchable`: the system field cannot render the
    /// custom result list or drive the jump-and-pulse, so the sidebar keeps it.
    private var searchField: some View {
        HStack(spacing: 6) {
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
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.color(theme.palette.elevated).opacity(0.5))
        )
    }

    /// Grouped-form footers render trailing-aligned here, so take the full row
    /// and pin the text to the leading edge.
    private func settingsFooter(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clamped(_ value: Binding<Int>, to range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { min(range.upperBound, max(range.lowerBound, value.wrappedValue)) },
            set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }
        )
    }

    private func clamped(_ value: Binding<Double>, to range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { min(range.upperBound, max(range.lowerBound, value.wrappedValue)) },
            set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }
        )
    }

    /// Label, editable number field, optional unit, and the stepper arrows.
    /// The binding is clamped on write, so a typed value cannot leave `range`
    /// even though the field commits only when it loses focus.
    private func numericRow(
        _ title: String,
        value: Binding<Int>,
        in range: ClosedRange<Int>,
        step: Int = 1,
        unit: String = ""
    ) -> some View {
        let bound = clamped(value, to: range)
        return LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: bound, format: .number)
                    .labelsHidden()
                    .settingsField()
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                if !unit.isEmpty {
                    Text(unit).foregroundStyle(.secondary)
                }
                Stepper("", value: bound, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private func numericRow(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 1,
        unit: String = ""
    ) -> some View {
        let bound = clamped(value, to: range)
        return LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: bound, format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .settingsField()
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                if !unit.isEmpty {
                    Text(unit).foregroundStyle(.secondary)
                }
                Stepper("", value: bound, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private var screenSize: CGSize {
        (PanelController.screenUnderPointer() ?? NSScreen.main)?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)
    }

    private var visibleRowsBinding: Binding<Int> {
        Binding(
            get: { config.window.launcherRows(for: screenSize) },
            set: { config.window.visibleRows = min(10, max(5, $0)) }
        )
    }

    private var widthBinding: Binding<Double> {
        Binding(
            get: { config.window.launcherWidth(for: screenSize) },
            set: { config.window.width = min(1_400, max(560, $0)) }
        )
    }

    /// Stored as 0.8–1.6; the field reads as a percentage.
    private var scalePercentBinding: Binding<Double> {
        Binding(
            get: { (config.window.effectiveScale * 100).rounded() },
            set: { config.window.scale = min(1.6, max(0.8, $0 / 100)) }
        )
    }

    /// Stored in milliseconds; the field reads as seconds.
    private var clearAfterSecondsBinding: Binding<Int> {
        Binding(
            get: { config.clipboard.clearAfterMs / 1_000 },
            set: { config.clipboard.clearAfterMs = $0 * 1_000 }
        )
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch selectedTab {
        case .general: general
        case .launcher: launcher
        case .appearance: appearance
        case .shortcuts: shortcuts
        case .clipboard: clipboard
        case .search: search
        case .capture: capture
        case .ask: ask
        case .providers: providerSettings
        case .advanced: advanced
        case .terminal: terminal
        case .cheatsheets: cheatsheets
        }
    }

    private var configURL: URL {
        PalettePaths.resolve().configFile
    }

    private var destinations: [SettingsDestination] {
        [
            .init(title: "Startup", tab: .general, anchor: "general-startup", keywords: "login start startup launch item"),
            .init(title: "Permissions", tab: .general, anchor: "general-permissions", keywords: "accessibility permission paste automation"),
            .init(title: "Power and keep awake", tab: .general, anchor: "general-power", keywords: "awake clamshell lid sleep power"),
            .init(title: "Notifications and timers", tab: .general, anchor: "general-notifications", keywords: "timer sound notification finish"),
            .init(title: "Apps and editor", tab: .general, anchor: "general-apps", keywords: "terminal editor neovide kitty external app detect reset"),
            .init(title: "Embedded terminal", tab: .terminal, anchor: "terminal-embedded", keywords: "terminal session zellij tmux fish zsh shell font size"),
            .init(title: "Launcher position and tabs", tab: .launcher, anchor: "launcher-tabs", keywords: "top center app order alphabetical frequent provider tabs chips show"),
            .init(title: "Launcher size", tab: .launcher, anchor: "launcher-size", keywords: "width rows scale preview layout fit screen"),
            .init(title: "Command prefix", tab: .launcher, anchor: "launcher-commands", keywords: "prefix provider command slash"),
            .init(title: "Themes", tab: .appearance, anchor: "appearance-theme", keywords: "theme dark light catppuccin gruvbox aetheria"),
            .init(title: "Typography and fonts", tab: .appearance, anchor: "appearance-typography", keywords: "font family size mono typography"),
            .init(title: "Global shortcuts", tab: .shortcuts, anchor: "shortcuts-global", keywords: "hotkey shortcut launcher clipboard terminal scratchpad ask record screen region window"),
            .init(title: "Clipboard history", tab: .clipboard, anchor: "clipboard-history", keywords: "clipboard history entries poll clear retention secrets"),
            .init(title: "Web search", tab: .search, anchor: "search-web", keywords: "web search engine google duckduckgo github youtube"),
            .init(title: "Search engines and bangs", tab: .search, anchor: "search-engines", keywords: "engine url keyword bang !g"),
            .init(title: "Bookmarks", tab: .search, anchor: "search-bookmarks", keywords: "bookmark url keywords browser"),
            .init(title: "Web app browser", tab: .search, anchor: "search-webapps", keywords: "browser helium chrome chromium web app"),
            .init(title: "Screenshots and recordings", tab: .capture, anchor: "capture-screenshots", keywords: "screenshot capture record audio microphone delay format save folder gallery"),
            .init(title: "Ask models and API key", tab: .ask, anchor: "ask-model", keywords: "ask model api key token endpoint history retention"),
            .init(title: "Default search", tab: .providers, anchor: "providers-default", keywords: "global unprefixed plain query provider default search system timer awake"),
            .init(title: "Provider order and aliases", tab: .providers, anchor: "providers-order", keywords: "provider order alias visibility trigger"),
            .init(title: "Provider shortcuts and aliases", tab: .providers, anchor: "providers-shortcuts", keywords: "provider alias shortcut trigger reset defaults enable disable neo editor neof folders"),
            .init(title: "Cheatsheet folders", tab: .cheatsheets, anchor: "cheatsheets-folders", keywords: "cheatsheet reference pdf html markdown text image folder book"),
            .init(title: "Backup and diagnostics", tab: .advanced, anchor: "advanced-backup", keywords: "backup export restore diagnostics crash log version"),
            .init(title: "Configuration files", tab: .advanced, anchor: "advanced-config", keywords: "config providers themes log folder file"),
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
                settingsJump = SettingsJump(
                    anchor: destination.anchor,
                    token: (settingsJump?.token ?? 0) + 1
                )
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

    /// Centre the row a search result points at, then pulse its label for two
    /// seconds. The short delay lets the freshly switched tab lay out its Form.
    @MainActor
    private func jumpToSearchTarget(_ jump: SettingsJump?, proxy: ScrollViewProxy) async {
        guard let jump else { return }
        do {
            try await Task.sleep(for: .milliseconds(160))
            proxy.scrollTo(jump.anchor, anchor: .center)
            settingsHighlight = jump.anchor
            // Form rows lay out lazily, so the first scroll can stop short on a
            // long tab; centre again once the whole form has been measured.
            try await Task.sleep(for: .milliseconds(400))
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(jump.anchor, anchor: .center)
            }
            try await Task.sleep(for: .seconds(2))
            if settingsHighlight == jump.anchor { settingsHighlight = nil }
        } catch {
            // Leaving search cancels the pulse; a newer jump replaces it.
            if settingsJump == jump, settingsHighlight == jump.anchor {
                settingsHighlight = nil
            }
        }
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
            ("Screen", config.screenshotHotkey),
            ("Region", config.regionScreenshotHotkey),
            ("Window", config.windowScreenshotHotkey),
            ("Recording", config.recordingHotkey),
        ].filter { !$0.1.isEmpty }
        let values = entries
            .map { "\($0.0) \(HotKeySpec.parse($0.1)?.prettyDisplay ?? $0.1)" }
            .joined(separator: " · ")
        return hasShortcutConflict ? "Conflict: each global shortcut must be unique." : values
    }

    private var hasShortcutConflict: Bool {
        let values = [
            config.hotkey,
            config.clipboardHotkey,
            config.terminalHotkey,
            config.scratchpadHotkey,
            config.askHotkey,
            config.screenshotHotkey,
            config.regionScreenshotHotkey,
            config.windowScreenshotHotkey,
            config.recordingHotkey,
        ].filter { !$0.isEmpty }.map { $0.lowercased() }
        return Set(values).count != values.count
    }

    private var shortcuts: some View {
        Form {
            Section {
                shortcutRow("Launcher shortcut", value: $config.hotkey, token: $launcherRecordToken, label: "Launcher hotkey")
                shortcutRow("Clipboard shortcut", value: $config.clipboardHotkey, token: $clipboardRecordToken, label: "Clipboard hotkey")
                shortcutRow("Terminal shortcut", value: $config.terminalHotkey, token: $terminalRecordToken, label: "Terminal hotkey")
                shortcutRow("Scratchpad shortcut", value: $config.scratchpadHotkey, token: $scratchpadRecordToken, label: "Scratchpad hotkey")
                shortcutRow("Ask shortcut", value: $config.askHotkey, token: $askRecordToken, label: "Ask hotkey")
            } header: {
                Text("Global shortcuts").searchTarget("shortcuts-global")
            }
            Section("Screenshots and recording") {
                shortcutRow("Screen shortcut", value: $config.screenshotHotkey, token: $screenshotRecordToken, label: "Screen hotkey")
                shortcutRow("Region shortcut", value: $config.regionScreenshotHotkey, token: $regionRecordToken, label: "Region hotkey")
                shortcutRow("Window shortcut", value: $config.windowScreenshotHotkey, token: $windowRecordToken, label: "Window hotkey")
                shortcutRow("Recording shortcut", value: $config.recordingHotkey, token: $recordingRecordToken, label: "Recording hotkey")
                Text("⌘⇧3 and ⌘⇧4 take over the macOS screenshot keys while they are set here. Clear one to give it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Click Record, then press the shortcut you want. Save applies it immediately; clear an optional shortcut to disable it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(shortcutSummary)
                    .font(.caption)
                    .foregroundStyle(hasShortcutConflict ? .red : .secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Explicit label / control / button row. `LabeledContent` sized its label
    /// column to the longest title and pushed the whole row past the form's
    /// inset, clipping "Scratchpad shortcut" at the window edge.
    private func shortcutRow(
        _ title: String,
        value: Binding<String>,
        token: Binding<Int>,
        label: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            ShortcutRecorder(value: value, label: label, recordToken: token.wrappedValue)
                .frame(width: 170, height: 26)
            Button("Record") { token.wrappedValue += 1 }
                .controlSize(.small)
                .accessibilityLabel("Record \(label)")
        }
    }

    private var general: some View {
        Form {
            Section {
                Toggle("Open Palette at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            } header: {
                Text("Startup").searchTarget("general-startup")
            } footer: {
                settingsFooter("Applies immediately. If macOS asks for approval, allow Palette under System Settings › General › Login Items.")
            }

            Section {
                HStack {
                    Image(systemName: accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityTrusted ? .green : .orange)
                    Text("Accessibility")
                    Spacer()
                    Text(accessibilityTrusted ? "Enabled" : "Not granted")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
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
            } header: {
                Text("Permissions").searchTarget("general-permissions")
            } footer: {
                settingsFooter("Needed for direct paste and recording system shortcuts. A new install may require granting once; subsequent updates keep the same signature.")
            }

            Section {
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
            } header: {
                Text("Power").searchTarget("general-power")
            } footer: {
                settingsFooter("Clamshell uses the standard administrator prompt and keeps working with the lid shut only on AC power. Turning it off leaves an active keep-awake timer alone.")
            }

            Section {
                Toggle("Play a sound when a timer finishes", isOn: $config.timer.sound)
                Toggle("Show a notification when a timer finishes", isOn: $config.timer.notify)
            } header: {
                Text("Notifications").searchTarget("general-notifications")
            } footer: {
                settingsFooter("Presets (minutes) are set with [timer] presets in config.toml. Use /timer 25m, /timer 1h30m or /timer 1:30 to start any duration.")
            }

            Section {
                TextField("Editor", text: $config.editorOpenWith)
                    .settingsField()
                TextField("Terminal", text: $config.terminalApp)
                    .settingsField()
                HStack(spacing: 8) {
                    Button("Detect Installed Apps") { detectDefaults() }
                    Button("Reset App and Theme Defaults") { resetDefaults() }
                }
                if let defaultsMessage {
                    Text(defaultsMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Apps").searchTarget("general-apps")
            } footer: {
                settingsFooter("Used by projects, commands, Zellij, and Bitwarden. Examples: neovide, Visual Studio Code, Cursor, kitty, Terminal. Reset also restores the theme, Ask, and terminal-session defaults.")
            }
        }
        .formStyle(.grouped)
    }

    private var terminal: some View {
        Form {
            Section {
                Picker("Session", selection: $config.terminalSession.multiplexer) {
                    Text("Auto").tag(TerminalMultiplexer.auto)
                    Text("Zellij").tag(TerminalMultiplexer.zellij)
                    Text("tmux").tag(TerminalMultiplexer.tmux)
                    Text("Plain shell").tag(TerminalMultiplexer.none)
                }
                TextField("Session name", text: $config.terminalSession.name)
                    .settingsField()
                Picker("Shell", selection: $terminalShellChoice) {
                    Text("Auto (fish, then zsh)").tag("auto")
                    Text("Fish").tag("fish")
                    Text("Zsh").tag("zsh")
                    Text("Custom…").tag("custom")
                }
                if terminalShellChoice == "custom" {
                    TextField("Custom shell executable", text: $config.terminalSession.shell)
                        .settingsField()
                }
                TextField("Font family", text: $config.terminalSession.font)
                    .settingsField()
                numericRow("Font size", value: $config.terminalSession.fontSize,
                           in: 0...48, step: 1, unit: "pt")
            } header: {
                Text("Embedded terminal").searchTarget("terminal-embedded")
            } footer: {
                settingsFooter("Auto uses Zellij, then tmux, then a plain shell; plain shell sessions end when the panel closes. Empty font and a size of 0 auto-detect Kitty's font, then the theme mono font. Use a Nerd Font for icons.")
            }
        }
        .formStyle(.grouped)
    }

    private var cheatsheets: some View {
        Form {
            Section {
                ForEach(cheatsheetFolders.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        TextField("Folder", text: $cheatsheetFolders[index])
                            .settingsField()
                        Button {
                            cheatsheetFolders.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove folder")
                        .accessibilityLabel("Remove folder")
                    }
                    .padding(.vertical, 4)
                }
                Button("Add folder") {
                    cheatsheetFolders.append("")
                }
            } header: {
                Text("Folders").searchTarget("cheatsheets-folders")
            } footer: {
                settingsFooter("PDF, HTML, Markdown, text and images preview in the launcher; press ⌥P to enlarge.")
            }

            Section {
                TextField("Extensions", text: $cheatsheetExtensions, prompt: Text("pdf, html, md, txt, png"))
                    .settingsField()
            } header: {
                Text("Extensions")
            } footer: {
                settingsFooter("Comma-separated, without the dot. Folders are scanned one level deep and ~ works in paths.")
            }
        }
        .formStyle(.grouped)
    }

    private var launcher: some View {
        Form {
            Section {
                Picker("Opens at", selection: $config.searchPosition) {
                    Text("Top").tag(SearchPosition.top)
                    Text("Center").tag(SearchPosition.center)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Position")
            } footer: {
                settingsFooter("Top drops down from the menu bar; Center opens in the middle of the screen.")
            }

            Section {
                Toggle("Show provider tabs", isOn: $config.window.showTabs)
                Picker("App order", selection: $config.appSort) {
                    Text("Alphabetical").tag(AppSort.alphabetical)
                    Text("Most used").tag(AppSort.frequent)
                }
                Toggle("Fit to the active screen", isOn: $config.window.autoSize)
            } header: {
                Text("Tabs and order").searchTarget("launcher-tabs")
            } footer: {
                settingsFooter("Provider tabs are the chip strip above the list. Turn individual providers on or off in the Providers tab. Fit sizes the launcher to the screen under the pointer.")
            }

            Section {
                numericRow("Width", value: widthBinding, in: 560...1_400, step: 20, unit: "pt")
                numericRow("Visible rows", value: visibleRowsBinding, in: 5...10, step: 1)
                numericRow("Scale", value: scalePercentBinding, in: 80...160, step: 5, unit: "%")
                Picker("Preview", selection: $config.window.previewLayout) {
                    Text("Automatic (window width)").tag(PreviewPlacement.auto)
                    Text("Below the list").tag(PreviewPlacement.below)
                    Text("Beside the list").tag(PreviewPlacement.beside)
                }
            } header: {
                Text("Size").searchTarget("launcher-size")
            } footer: {
                settingsFooter("Scale multiplies every launcher size, like rem; width and rows override it. Clipboard, Ask, preview, terminal, and scratchpad widths are in config.toml under [window].")
            }

            Section {
                TextField("Command prefix", text: $config.providerPrefix)
                    .settingsField()
                    .frame(width: 92)
            } header: {
                Text("Commands").searchTarget("launcher-commands")
            } footer: {
                settingsFooter("Prefix for provider commands such as /clip and /port. Usually /.")
            }
        }
        .formStyle(.grouped)
    }

    private var appearance: some View {
        Form {
            Section {
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
            } header: {
                Text("Theme").searchTarget("appearance-theme")
            } footer: {
                settingsFooter("Theme files use TOML. See THEMING.html in the repository; saving this window reloads the active theme.")
            }

            Section {
                Picker("UI family", selection: $config.typography.uiFamily) {
                    Text("Inherit from theme").tag("")
                    ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                TextField("Or type a UI family name", text: $config.typography.uiFamily)
                    .settingsField()
                numericRow("UI size", value: $config.typography.uiSize,
                           in: 0...48, step: 1, unit: "pt")
                Picker("Mono family", selection: $config.typography.monoFamily) {
                    Text("Inherit from theme").tag("")
                    ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                TextField("Or type a mono family name", text: $config.typography.monoFamily)
                    .settingsField()
                numericRow("Mono size", value: $config.typography.monoSize,
                           in: 0...48, step: 1, unit: "pt")
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
            } header: {
                Text("Typography").searchTarget("appearance-typography")
            } footer: {
                settingsFooter("A size of 0 inherits the theme. The family pickers list installed fonts; the fields below accept any family name.")
            }
        }
        .formStyle(.grouped)
    }

    private var clipboard: some View {
        Form {
            Section {
                Toggle("Record clipboard history", isOn: $config.clipboard.enabled)
                numericRow("Maximum entries", value: $config.clipboard.maxEntries,
                           in: 50...50_000, step: 500)
                numericRow("Poll interval", value: $config.clipboard.pollMs,
                           in: 200...2_000, step: 50, unit: "ms")
                numericRow("Clear copied secrets after", value: clearAfterSecondsBinding,
                           in: 0...300, step: 5, unit: "s")
            } header: {
                Text("History").searchTarget("clipboard-history")
            } footer: {
                settingsFooter("Text and PNG images are stored. Anything marked concealed by another app is never recorded. A clear-after value of 0 seconds keeps secrets until you clear the history.")
            }
        }
        .formStyle(.grouped)
    }

    private var search: some View {
        Form {
            Section {
                Toggle("Show web results in search", isOn: $config.webSearchEnabled)
            } header: {
                Text("Web search").searchTarget("search-web")
            } footer: {
                settingsFooter("When a query does not match an app or file, Palette offers a browser search.")
            }

            Section {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach($engines) { $engine in
                        engineEditor($engine)
                        Divider().padding(.vertical, 6)
                    }
                    HStack(spacing: 8) {
                        Button("Add Engine") {
                            engines.append(WebSearchEngine(
                                name: "New Engine",
                                urlTemplate: "https://example.com/?q={query}"
                            ))
                        }
                        Button("Restore Defaults") {
                            engines = WebSearchEngine.restoringDefaults(into: engines)
                            config.webSearchEngines = engines
                        }
                    }
                }
            } header: {
                Text("Search engines").searchTarget("search-engines")
            } footer: {
                settingsFooter("Type !keyword in the launcher, e.g. !yt lo-fi. The search URL must contain {query} — for example https://example.com/search?q={query} — which Palette replaces with the URL-encoded text. “Open in web app” sends that engine's searches to the web-app browser — set a Chromium-based browser below or under Web apps.")
            }

            Section {
                ForEach($bookmarks) { $bookmark in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("Name", text: $bookmark.name)
                                .settingsField()
                            Button {
                                bookmarks.removeAll { $0.id == bookmark.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove bookmark")
                            .accessibilityLabel("Remove bookmark")
                        }
                        TextField("URL", text: $bookmark.url)
                            .settingsField()
                        BrowserPicker(browser: $bookmark.browser)
                        TextField("Keywords (comma separated)", text: Binding(
                            get: { bookmark.keywords.joined(separator: ", ") },
                            set: { text in
                                bookmark.keywords = text
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }
                            }
                        ))
                        .settingsField()
                    }
                    .padding(.vertical, 4)
                }
                Button("Add bookmark") {
                    bookmarks.append(Bookmark(name: "", url: "", browser: ""))
                }
            } header: {
                Text("Bookmarks").searchTarget("search-bookmarks")
            } footer: {
                settingsFooter("Bookmarks open in a normal browser window, in the browser you pick.")
            }

            Section {
                Picker("Open web apps in", selection: $config.webAppBrowser) {
                    ForEach(BrowserCatalog.chromiumChoices, id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("Web apps").searchTarget("search-webapps")
            } footer: {
                settingsFooter("Chromium-based browsers only. Helium is the default.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Load once so switching tabs does not discard unsaved edits.
            guard !bookmarksLoaded else { return }
            bookmarks = BookmarkStore.load(from: PalettePaths.resolve().bookmarksFile)
            bookmarksLoaded = true
        }
    }

    /// One engine card: labelled fields, the bang keyword beside its `!`, and
    /// the web-app switch. Rows stay one line so several engines fit at once.
    private func engineEditor(_ engine: Binding<WebSearchEngine>) -> some View {
        let keyword = Binding(
            get: { engine.wrappedValue.keyword ?? "" },
            set: { engine.wrappedValue.keyword = $0.isEmpty ? nil : $0 }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LabeledContent("Name") {
                    TextField("Name", text: engine.name)
                        .labelsHidden()
                        .settingsField()
                }
                Button {
                    if let index = engines.firstIndex(where: { $0.id == engine.wrappedValue.id }) {
                        engines.remove(at: index)
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove engine")
                .accessibilityLabel("Remove \(engine.wrappedValue.name)")
            }
            LabeledContent("Search URL") {
                TextField("Search URL", text: engine.urlTemplate)
                    .labelsHidden()
                    .settingsField()
                    .font(.system(.body, design: .monospaced))
            }
            LabeledContent("Keyword") {
                HStack(spacing: 4) {
                    Text("!").foregroundStyle(.secondary)
                    TextField("Keyword", text: keyword)
                        .labelsHidden()
                        .settingsField()
                        .frame(width: 90)
                }
            }
            BrowserPicker(browser: engine.browser)
            Toggle("Open in web app", isOn: engine.appMode)
                .toggleStyle(.checkbox)
        }
        .padding(.vertical, 2)
    }

    private var capture: some View {
        Form {
            Section {
                TextField("Save to", text: $config.capture.directory)
                    .settingsField()
                Picker("Action", selection: $config.capture.screenshotAction) {
                    Text("Save").tag(CaptureAction.save)
                    Text("Copy").tag(CaptureAction.copy)
                    Text("Save and copy").tag(CaptureAction.saveCopy)
                    Text("Save and preview").tag(CaptureAction.preview)
                }
                Picker("Format", selection: $config.capture.screenshotFormat) {
                    Text("PNG").tag("png")
                    Text("JPG").tag("jpg")
                }
                numericRow("Delay before capture", value: $config.capture.delay,
                           in: 0...10, step: 1, unit: "s")
            } header: {
                Text("Screenshots").searchTarget("capture-screenshots")
            } footer: {
                settingsFooter("Use /shot or the screen, region, and window shortcuts. Save to supports ~ and is created on the first capture.")
            }

            Section {
                Picker("Action", selection: $config.capture.recordingAction) {
                    Text("Save").tag(CaptureAction.save)
                    Text("Save and copy").tag(CaptureAction.saveCopy)
                }
                Picker("What to record", selection: $config.capture.recordingTarget) {
                    Text("Whole screen").tag("screen")
                    Text("A display").tag("display")
                    Text("A region").tag("region")
                }
                if config.capture.recordingTarget == "display" {
                    Picker("Display", selection: $config.capture.recordingDisplay) {
                        ForEach(CaptureDisplays.active()) { display in
                            Text(display.label).tag(display.index)
                        }
                    }
                }
                if config.capture.recordingTarget == "region" {
                    TextField("Region (x,y,w,h)", text: $config.capture.recordingRegion)
                        .settingsField()
                }
                Picker("Format", selection: $config.capture.recordingFormat) {
                    Text("MOV").tag("mov")
                    Text("MP4").tag("mp4")
                }
                Toggle("Record audio", isOn: $config.capture.recordingAudio)
                Picker("Microphone", selection: $config.capture.recordingMicrophone) {
                    Text("System default").tag("")
                    ForEach(CaptureMicrophones.active(), id: \.id) { microphone in
                        Text(microphone.name).tag(microphone.id)
                    }
                }
                .disabled(!config.capture.recordingAudio)
            } header: {
                Text("Recordings")
            } footer: {
                settingsFooter("Use /rec to start or stop a recording. Recordings are saved with the system capture engine.")
            }

            Section {
                Toggle("Hide Palette before capturing", isOn: $config.capture.hidePalette)
                Toggle("Include the cursor", isOn: $config.capture.captureCursor)
                Toggle("Show clicks while recording", isOn: $config.capture.showClicks)
                Toggle("Shutter sound after a screenshot", isOn: $config.capture.captureSound)
                Toggle("Show a thumbnail after a screenshot", isOn: $config.capture.captureThumbnail)
                Toggle("Open the annotator after a screenshot", isOn: $config.capture.editAfterCapture)
                Toggle("Preview recordings when they stop", isOn: $config.capture.previewRecording)
            } header: {
                Text("After the capture")
            }

            Section {
                Picker("List", selection: $config.capture.gallery) {
                    Text("Everything in the folder").tag("all")
                    Text("Only Palette's captures").tag("palette")
                }
            } header: {
                Text("Captures list")
            } footer: {
                settingsFooter("Controls what /shots shows: every image and video in the folder, or only Palette's own shot-* and rec-* files.")
            }
        }
        .formStyle(.grouped)
    }

    private var ask: some View {
        Form {
            Section {
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
                numericRow("Max answer tokens", value: $config.ask.maxTokens,
                           in: 32...8_192, step: 32)
                Toggle("Fall back to free or small models when quota runs out", isOn: $config.ask.fallback)
            } header: {
                Text("Model").searchTarget("ask-model")
            } footer: {
                settingsFooter("Free models are listed first. If a free model is rate-limited, Ask tries the next free option, then the cheapest paid model from an endpoint where you have a key.")
            }

            Section {
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
                        .settingsField()
                    HStack(spacing: 8) {
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
            } header: {
                Text("API key")
            } footer: {
                settingsFooter("Keys can also come from OPENCODE_API_KEY, OPENCODE_GO_API_KEY, or OPENAI_API_KEY for a shell-launched build. The app never logs a key.")
            }

            Section {
                numericRow("Keep questions and answers", value: $config.ask.maxHistory,
                           in: 10...20_000, step: 10)
                numericRow("Delete answers older than", value: $config.ask.retentionDays,
                           in: 1...3_650, step: 1, unit: "days")
            } header: {
                Text("History")
            } footer: {
                settingsFooter("Ask History is the History sub-tab under /ask. Rows show the model, endpoint, age, duration, and token count.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            normalizeAskModel()
            askKeyStored = AskKeychain.hasStoredKey(for: config.ask.endpoint)
        }
    }

    /// One row per provider: visibility, name, trigger, aliases, and order all
    /// live in the same table so a provider is configured in one place.
    private var providerSettings: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Text("Show")
                            .frame(width: 30, alignment: .leading)
                        Text("Provider")
                            .frame(width: providerNameWidth, alignment: .leading)
                        Text("Default")
                            .searchTarget("providers-default")
                            .frame(width: providerDefaultWidth, alignment: .leading)
                        Text("Trigger")
                            .frame(width: providerTriggerWidth, alignment: .leading)
                        Text("Aliases")
                            .searchTarget("providers-shortcuts")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Order")
                            .searchTarget("providers-order")
                            .frame(width: providerOrderWidth)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                    Divider()

                    ForEach(Array(allProviderIDs.enumerated()), id: \.element) { index, id in
                        providerRow(id)
                        if index < allProviderIDs.count - 1 {
                            Divider()
                        }
                    }
                }
            } header: {
                Text("Providers")
            } footer: {
                settingsFooter("Turn off a provider to hide its tab; apps always stay visible. A checked Default column means plain, unprefixed queries search that provider. A checked alias is active and saved to config.toml — unchecking keeps the row so the word can be restored. Triggers come from provider.toml and cannot be renamed here. Use the arrows to change the tab order.")
            }

            Section {
                Button("Open Providers Folder") { onOpen(PalettePaths.resolve().providersDir) }
                Button("Open commands.toml") {
                    onOpen(PalettePaths.resolve().configDir.appendingPathComponent("commands.toml"))
                }
            } header: {
                Text("Files")
            } footer: {
                settingsFooter("Add your own provider by creating a folder under providers/ with a provider.toml. User providers override bundled ones with the same id. Press ⌘R after editing files.")
            }
        }
        .formStyle(.grouped)
    }

    private var advanced: some View {
        Form {
            Section {
                Button("Open config.toml") { onOpen(configURL) }
                Button("Open Log") { onOpen(PalettePaths.resolve().logFile) }
            } header: {
                Text("Configuration").searchTarget("advanced-config")
            } footer: {
                settingsFooter("Settings writes config.toml for you. Edit it directly only for options that are not in this window, then press ⌘R.")
            }

            Section {
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
            } header: {
                Text("Backup & diagnostics").searchTarget("advanced-backup")
            }

            Section {
                LabeledContent("Version") {
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                }
                Button("Copy Update Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew upgrade --cask palette", forType: .string)
                }
            } header: {
                Text("About")
            } footer: {
                settingsFooter("Update with the Homebrew cask; the app has no self-updater.")
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

    private func providerTrigger(_ id: String) -> String? {
        providers.first(where: { $0.id == id })?.trigger
    }

    /// The Default column: apps always answer a plain query, everything else
    /// follows the allowlist saved to `[providers] global`.
    private func providerDefaultBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { id == "apps" || globalProviders.contains(id.lowercased()) },
            set: { enabled in
                let key = id.lowercased()
                if enabled {
                    if !globalProviders.contains(key) { globalProviders.append(key) }
                } else {
                    globalProviders.removeAll { $0 == key }
                }
            }
        )
    }

    private func providerEnabledBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !disabledProviders.contains(id) },
            set: { enabled in
                if enabled {
                    disabledProviders.removeAll { $0 == id }
                } else if !disabledProviders.contains(id) {
                    disabledProviders.append(id)
                }
            }
        )
    }

    /// Moves a provider one row in the table. Rows skip `apps`, so swap with the
    /// neighbouring row's id rather than the neighbouring array slot.
    private func moveProvider(_ id: String, up: Bool) {
        let rows = allProviderIDs
        guard let row = rows.firstIndex(of: id) else { return }
        let neighbour = up ? row - 1 : row + 1
        guard rows.indices.contains(neighbour),
              let from = providerOrder.firstIndex(of: id),
              let to = providerOrder.firstIndex(of: rows[neighbour]) else { return }
        providerOrder.swapAt(from, to)
    }

    private func providerRow(_ id: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("Show \(providerName(id))", isOn: providerEnabledBinding(id))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 30, alignment: .leading)
                .help("Show \(providerName(id)) as a launcher tab")

            VStack(alignment: .leading, spacing: 2) {
                Text(providerName(id))
                    .fontWeight(.medium)
                    .lineLimit(2)
            }
            .frame(width: providerNameWidth, alignment: .leading)

            Toggle("Search \(providerName(id)) without a prefix", isOn: providerDefaultBinding(id))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: providerDefaultWidth, alignment: .leading)
                .disabled(id == "apps")
                .help(id == "apps"
                    ? "Apps always answer a plain query."
                    : "Include \(providerName(id)) in plain, unprefixed queries.")

            providerTriggerChip(id)
                .frame(width: providerTriggerWidth, alignment: .leading)

            aliasEditor(id)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 2) {
                Button { moveProvider(id, up: true) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(providerOrder.firstIndex(of: id) == nil || allProviderIDs.first == id)
                .help("Move \(providerName(id)) up")
                .accessibilityLabel("Move \(providerName(id)) up")

                Button { moveProvider(id, up: false) } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(providerOrder.firstIndex(of: id) == nil || allProviderIDs.last == id)
                .help("Move \(providerName(id)) down")
                .accessibilityLabel("Move \(providerName(id)) down")
            }
            .frame(width: providerOrderWidth)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func providerTriggerChip(_ id: String) -> some View {
        if let trigger = providerTrigger(id) {
            Text("trigger: \(trigger)")
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )
                .help("The trigger is compiled from provider.toml. Edit that file to rename it.")
        } else {
            Text("no trigger")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("This provider has no trigger; it can only appear in a plain query.")
        }
    }

    @ViewBuilder
    private func aliasEditor(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(aliasEntries(id)) { $entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Toggle("Use alias \(entry.word)", isOn: $entry.enabled)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .accessibilityLabel("Use alias \(entry.word)")
                        TextField("Alias", text: $entry.word)
                            .settingsField()
                            .foregroundStyle(aliasIssues[entry.id] == nil ? Color.primary : Color.red)
                        Button {
                            deleteAlias(entry.id, from: id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this alias")
                        .accessibilityLabel("Delete alias \(entry.word)")
                    }
                    if let issue = aliasIssues[entry.id] {
                        Text(issue).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("Add alias", text: Binding(
                    get: { newAlias[id] ?? "" },
                    set: { newAlias[id] = $0 }
                ))
                .settingsField()
                .onSubmit { addAlias(id) }
                Button("Add") { addAlias(id) }
                    .disabled((newAlias[id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if ProviderAliases.defaults[id] != nil {
                Button("Reset to defaults") { resetAliases(id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    private func aliasEntries(_ id: String) -> Binding<[ProviderAliasEntry]> {
        Binding(
            get: { providerAliasesDraft[id] ?? [] },
            set: { providerAliasesDraft[id] = $0 }
        )
    }

    /// Words already taken, scanned in display order so a duplicate flags the
    /// later row instead of aborting the save.
    private var aliasIssues: [UUID: String] {
        var owner: [String: String] = [:]
        for provider in providers {
            if let trigger = provider.trigger { owner[trigger.lowercased()] = provider.name }
        }
        // Apps is not editable here, but its aliases still claim their words.
        for entry in providerAliasesDraft["apps"] ?? [] where entry.enabled {
            owner[entry.word.lowercased()] = "apps"
        }
        var issues: [UUID: String] = [:]
        for id in allProviderIDs {
            for entry in providerAliasesDraft[id] ?? [] where entry.enabled {
                let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty else {
                    issues[entry.id] = "Type a word, or uncheck this alias."
                    continue
                }
                guard word.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
                    issues[entry.id] = "Use only letters, digits, dots, dashes, and underscores."
                    continue
                }
                if let existing = owner[word.lowercased()] {
                    issues[entry.id] = "“\(word)” is already used by \(existing)."
                    continue
                }
                owner[word.lowercased()] = providerName(id)
            }
        }
        return issues
    }

    private func addAlias(_ id: String) {
        let word = (newAlias[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        if let index = providerAliasesDraft[id]?.firstIndex(where: {
            $0.word.caseInsensitiveCompare(word) == .orderedSame
        }) {
            providerAliasesDraft[id]?[index].enabled = true
        } else {
            providerAliasesDraft[id, default: []].append(ProviderAliasEntry(word: word, enabled: true))
        }
        newAlias[id] = ""
    }

    private func deleteAlias(_ entryID: UUID, from id: String) {
        providerAliasesDraft[id]?.removeAll { $0.id == entryID }
    }

    private func resetAliases(_ id: String) {
        providerAliasesDraft[id] = (ProviderAliases.defaults[id] ?? []).map {
            ProviderAliasEntry(word: $0, enabled: true)
        }
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
            config.screenshotHotkey,
            config.regionScreenshotHotkey,
            config.windowScreenshotHotkey,
            config.recordingHotkey,
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
        // Row-level validation: a bad alias is flagged in the editor and left
        // out, while every other provider's valid edits still save.
        let aliasProblems = aliasIssues
        var aliasMap: [String: [String]] = [:]
        for provider in providers {
            let words = (providerAliasesDraft[provider.id] ?? [])
                .filter { $0.enabled && aliasProblems[$0.id] == nil }
                .map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !words.isEmpty {
                aliasMap[provider.id] = words
            } else if ProviderAliases.defaults[provider.id] != nil {
                // An explicit empty list keeps removed built-in defaults removed.
                aliasMap[provider.id] = []
            }
        }
        // Keep aliases for providers that are not loaded right now (apps, a
        // provider whose folder was temporarily removed).
        let loadedIDs = Set(providers.map(\.id))
        for (id, words) in config.providerAliases where !loadedIDs.contains(id) {
            if !words.isEmpty { aliasMap[id] = words }
        }
        config.providerAliases = aliasMap
        config.providerOrder = providerOrder
        config.disabledProviders = disabledProviders.filter { $0 != "apps" }
        // apps is always searched, so keep it out of the stored allowlist.
        config.globalProviders = globalProviders.filter { $0 != "apps" }
        switch terminalShellChoice {
        case "auto": config.terminalSession.shell = ""
        case "fish", "zsh": config.terminalSession.shell = terminalShellChoice
        default:
            if config.terminalSession.shell.trimmingCharacters(in: .whitespaces).isEmpty {
                config.terminalSession.shell = ""
            }
        }
        // Only write bookmarks once the editor has loaded them; a save from
        // another tab must not blank the file with an empty in-memory list.
        if bookmarksLoaded {
            let bookmarkFile = PalettePaths.resolve().bookmarksFile
            try? BookmarkStore.save(bookmarks, to: bookmarkFile)
            bookmarks = BookmarkStore.load(from: bookmarkFile)
        }
        config.cheatsheets.folders = cheatsheetFolders
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let extensions = cheatsheetExtensions
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        // An empty list would silently hide every file; keep the defaults.
        config.cheatsheets.extensions = extensions.isEmpty ? CheatsheetConfig().extensions : extensions
        // The writer owns the file; surface its failure in this window's alert.
        if let error = onSave(config) {
            saveError = error
        }
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
            setAccessibilityValue(HotKeySpec.parse(value)?.prettyDisplay ?? value)
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

        let shown = HotKeySpec.parse(value)?.prettyDisplay ?? value
        let text = focused && value.isEmpty ? "Press shortcut…" : (value.isEmpty ? "Click to record" : shown)
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