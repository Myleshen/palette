import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import CoreText
import ServiceManagement
import SwiftUI
import PaletteCore
import PalettePlatform

struct ProviderSettingsInfo: Identifiable, Equatable {
    var id: String
    var name: String
    var trigger: String?
    var isGlobal: Bool
    /// Tools this provider cannot run without, checked once here rather than
    /// from inside a search.
    var requirements: [ProviderRequirement] = []
    var group: ProviderGroup?
}

/// One editable alias row. `enabled` is the effective set written to config;
/// unchecked rows stay visible so a removed built-in alias can come back.
private struct ProviderAliasEntry: Identifiable, Equatable {
    var id = UUID()
    var word: String
    var enabled: Bool
}

enum SettingsTab: Int, CaseIterable, Identifiable {
    // Raw values are the `settings_tab=<index>` script surface; the order here
    // is the sidebar order and must stay stable.
    case general
    case launcher
    case appearance
    case shortcuts
    case search
    case ask
    case terminal
    case bookmarks
    case cheatsheets
    case webApps
    case screenshots
    case afterCapture
    case recordings
    case captures
    case about
    case providers
    case providerFiles
    case configFiles
    case diagnostics
    case theming

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .launcher: return "Launcher"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .search: return "Search"
        case .ask: return "Ask"
        case .terminal: return "Embedded Terminal"
        case .bookmarks: return "Bookmarks"
        case .cheatsheets: return "Cheatsheets"
        case .webApps: return "Web Apps"
        case .screenshots: return "Screenshots"
        case .afterCapture: return "After a capture"
        case .recordings: return "Recordings"
        case .captures: return "Captures"
        case .about: return "About"
        case .providers: return "Providers"
        case .providerFiles: return "Provider Files"
        case .configFiles: return "Config Files"
        case .diagnostics: return "Diagnostics"
        case .theming: return "Theming"
        }
    }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .launcher: return "rectangle.topthird.inset.filled"
        case .appearance: return "paintpalette"
        case .shortcuts: return "command"
        case .search: return "magnifyingglass"
        case .ask: return "sparkles"
        case .terminal: return "terminal"
        case .bookmarks: return "bookmark.fill"
        case .cheatsheets: return "book.closed.fill"
        case .webApps: return "globe"
        case .screenshots: return "camera.fill"
        case .afterCapture: return "wand.and.stars"
        case .recordings: return "record.circle"
        case .captures: return "photo.on.rectangle.angled"
        case .about: return "info.circle.fill"
        case .providers: return "square.stack.3d.up"
        case .providerFiles: return "folder.fill"
        case .configFiles: return "doc.text.fill"
        case .diagnostics: return "stethoscope"
        case .theming: return "paintbrush.pointed.fill"
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
        case .search: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .ask: return Color(red: 0.72, green: 0.38, blue: 0.95)
        case .terminal: return Color(red: 0.29, green: 0.33, blue: 0.38)
        case .bookmarks: return Color(red: 0.00, green: 0.42, blue: 0.90)
        case .cheatsheets: return Color(red: 0.00, green: 0.62, blue: 0.58)
        case .webApps: return Color(red: 0.35, green: 0.34, blue: 0.84)
        case .screenshots: return Color(red: 0.90, green: 0.30, blue: 0.42)
        case .afterCapture: return Color(red: 0.65, green: 0.35, blue: 0.90)
        case .recordings: return Color(red: 0.88, green: 0.19, blue: 0.22)
        case .captures: return Color(red: 0.55, green: 0.38, blue: 0.24)
        case .about: return Color(red: 0.45, green: 0.47, blue: 0.50)
        case .providers: return Color(red: 0.61, green: 0.44, blue: 0.31)
        case .providerFiles: return Color(red: 0.76, green: 0.53, blue: 0.16)
        case .configFiles: return Color(red: 0.36, green: 0.42, blue: 0.50)
        case .diagnostics: return Color(red: 0.20, green: 0.62, blue: 0.52)
        case .theming: return Color(red: 0.80, green: 0.36, blue: 0.22)
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
        SettingsTabGroup(title: "Basics", tabs: [.general, .launcher, .appearance, .shortcuts]),
        SettingsTabGroup(title: "Features", tabs: [
            .search, .ask, .terminal, .bookmarks, .cheatsheets, .webApps,
            .screenshots, .afterCapture, .recordings, .captures,
        ]),
        SettingsTabGroup(title: "Theming", tabs: [.theming]),
        SettingsTabGroup(title: "Advanced", tabs: [.providerFiles, .configFiles, .diagnostics]),
        SettingsTabGroup(title: "System", tabs: [.about, .providers]),
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
/// rounded background behind its label — not the whole card — when a search
/// result lands on it.
private struct SettingsSearchTarget: ViewModifier {
    @Environment(\.settingsHighlight) private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: highlight)
    }
}

private extension View {
    func searchTarget(_ anchor: String) -> some View {
        modifier(SettingsSearchTarget(anchor: anchor))
    }
}

private enum SaveState: Equatable {
    case idle
    case pending
    case saved
    case failed(String)
}

struct SettingsView: View {
    /// Scripted snapshots must not depend on a split-divider position saved by
    /// the user, so the tests pin the sidebar to its ideal width.
    private var scriptMode: Bool {
        ProcessInfo.processInfo.environment["PALETTE_SCRIPT"] != nil
    }

    @ObservedObject private var themeManager: ThemeManager
    @ObservedObject private var updates: UpdateService
    @ObservedObject private var theming: ThemingEngine
    @State private var config: PaletteConfig
    /// The last values actually written to disk. A row with an invalid value
    /// keeps what the user typed on screen while the file keeps this.
    @State private var savedConfig: PaletteConfig
    @State private var engines: [WebSearchEngine]
    @State private var selectedTab: SettingsTab = .general
    @State private var saveTask: Task<Void, Never>?
    @State private var saveState: SaveState = .idle
    @State private var resetPending = false
    @State private var clearKeyPending = false
    @State private var forgetLearnedPending = false
    @State private var forgetLearnedMessage: String?
    @State private var aliasPopover: String?
    @State private var loginMessage: String?
    @State private var launcherRecordToken = 0
    @State private var clipboardRecordToken = 0
    @State private var terminalRecordToken = 0
    @State private var themeGalleryRecordToken = 0
    @State private var wallpaperGalleryRecordToken = 0
    @State private var scratchpadRecordToken = 0
    @State private var askRecordToken = 0
    @State private var screenshotRecordToken = 0
    @State private var regionRecordToken = 0
    @State private var windowRecordToken = 0
    @State private var recordingRecordToken = 0
    /// Validation messages from a recorder, keyed like `shortcutRow`'s id.
    @State private var shortcutErrors: [String: String] = [:]
    @State private var settingsSearch = ""
    @FocusState private var settingsSearchFocused: Bool
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
    @State private var providerFilter = ""
    @State private var bookmarks: [Bookmark]
    @State private var bookmarksError: String?
    @State private var bookmarksDirty = false
    @State private var bookmarksSaveError: String?
    @State private var bindingRowIDs: [UUID]
    /// Typed binding values stay here until commit (Return or focus loss), so
    /// quitting mid-typing never registers a truncated shell command.
    @State private var bindingValueDrafts: [UUID: String] = [:]
    @FocusState private var focusedBindingID: UUID?
    @State private var terminalShellChoice: String
    @State private var cheatsheetFolders: [String]
    @State private var cheatsheetExtensions: String
    @State private var wallpaperPreviewImage: NSImage?
    @State private var copiedInclude: String?
    @State private var removePoliciesPending = false
    /// A silent plist outlives unchecking or Revert; the browser keeps the
    /// Palette colour until it is removed in the Browsers card.
    @State private var policyWarning: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var keepAwakeStatus = KeepAwakeStatus()
    @State private var keepAwakeMessage: String?
    @State private var appsMessage: String?
    @State private var copiedDiagnostics = false
    /// Bundle ids the clipboard ignores, with names resolved from installed and
    /// running apps only while this pane is open.
    @State private var ignoredAppChoices: [AppRecord] = []
    /// Running apps are refreshed by workspace notifications instead of being
    /// read from NSWorkspace on every body pass.
    @State private var runningAppChoices: [(id: String, name: String)] = []
    @State private var ignoredAppDraft = ""
    /// Device and font lists are read off-main once per pane appearance; the
    /// old computed properties reran AVFoundation and font enumeration on
    /// every re-render.
    @State private var microphones: [(id: String, name: String)] = []
    @State private var captureDisplays: [CaptureDisplay] = []
    @State private var fontFamilies: [String] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let keepAwake: KeepAwakeService
    private let themesDirectory: URL
    private let providers: [ProviderSettingsInfo]
    private let commands: [CatalogCommand]
    private let diagnostics: [String]
    private let initialWebAppBrowser: String
    private let onApply: (PaletteConfig) -> String?
    private let onOpen: (URL) -> Void
    private let onThemeCards: () -> Void
    private let onOpenThemedZellij: () -> Void
    private let onExportBackup: () -> Void
    /// Clears the learned-ranking rows; returns an error message on failure.
    private let onForgetLearned: () async -> String?

    private let contentWidth: CGFloat = 640
    private let providerTabWidth: CGFloat = 26
    private let providerNameWidth: CGFloat = 180
    private let providerPlainWidth: CGFloat = 70
    private let providerTriggerWidth: CGFloat = 110
    private let providerOrderWidth: CGFloat = 40

    init(
        config: PaletteConfig,
        keepAwake: KeepAwakeService,
        themeManager: ThemeManager,
        theming: ThemingEngine,
        themesDirectory: URL,
        accessibilityTrusted: Bool,
        providers: [ProviderSettingsInfo],
        commands: [CatalogCommand],
        diagnostics: [String],
        updates: UpdateService,
        onApply: @escaping (PaletteConfig) -> String?,
        onOpen: @escaping (URL) -> Void,
        onThemeCards: @escaping () -> Void,
        onOpenThemedZellij: @escaping () -> Void,
        onExportBackup: @escaping () -> Void,
        onForgetLearned: @escaping () async -> String?
    ) {
        _config = State(initialValue: config)
        _savedConfig = State(initialValue: config)
        _engines = State(initialValue: config.webSearchEngines)
        _accessibilityTrusted = State(initialValue: accessibilityTrusted)
        _askKeyStored = State(initialValue: AskKeychain.hasStoredKey(for: config.ask.endpoint))
        do {
            _bookmarks = State(initialValue: try BookmarkStore.load(from: PalettePaths.resolve().bookmarksFile))
        } catch {
            // Keep the rows empty and report the parse failure; saving is
            // blocked below so the broken file is never overwritten.
            _bookmarks = State(initialValue: [])
            _bookmarksError = State(initialValue: error.localizedDescription)
        }
        _bindingRowIDs = State(initialValue: config.bindings.map { _ in UUID() })
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
        _globalProviders = State(initialValue: config.globalProviders.filter { id in
            providers.contains { $0.id == id }
        })
        let configuredShell = config.terminalSession.shell.trimmingCharacters(in: .whitespaces)
        let shellName = (configuredShell as NSString).lastPathComponent.lowercased()
        _terminalShellChoice = State(initialValue: configuredShell.isEmpty
            ? "auto"
            : (["fish", "zsh"].contains(shellName) ? shellName : "custom"))
        _cheatsheetFolders = State(initialValue: config.cheatsheets.folders)
        _cheatsheetExtensions = State(initialValue: config.cheatsheets.extensions.joined(separator: ", "))
        _themeManager = ObservedObject(wrappedValue: themeManager)
        _updates = ObservedObject(wrappedValue: updates)
        self.keepAwake = keepAwake
        self.themesDirectory = themesDirectory
        self.providers = providers
        self.commands = commands
        self.diagnostics = diagnostics
        self.initialWebAppBrowser = config.webAppBrowser
        self.onApply = onApply
        self.onOpen = onOpen
        self.onThemeCards = onThemeCards
        self.onOpenThemedZellij = onOpenThemedZellij
        self.onExportBackup = onExportBackup
        self.onForgetLearned = onForgetLearned
        _theming = ObservedObject(wrappedValue: theming)
    }

    private var theme: Theme { themeManager.theme }
    private var muted: Color { theme.color(theme.palette.fgMuted) }
    private var danger: Color { theme.color(theme.palette.danger) }

    /// The light palette's accent is only 3.4:1 on the card fill; darken it
    /// just for light mode so links stay readable.
    private var linkColor: Color {
        guard theme.appearance == "light", let accent = RGBA(hex: theme.palette.accent) else {
            return theme.color(theme.palette.accent)
        }
        return Color(red: accent.red * 0.7, green: accent.green * 0.7, blue: accent.blue * 0.7)
    }

    var body: some View {
        alertedView
    }

    private var alertedView: some View {
        observedView
            .alert("Reset \(selectedTab.title)?", isPresented: $resetPending) {
                Button("Reset", role: .destructive) { resetSection() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(resetSummary)
            }
            .alert("Forget learned ranking?", isPresented: $forgetLearnedPending) {
                Button("Forget", role: .destructive) { forgetLearned() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Palette stops preferring rows it learned from your past choices. Only query digests are stored, and all of them are removed.")
            }
            .confirmationDialog(
                "Clear the saved \(config.ask.endpoint.displayName) API key?",
                isPresented: $clearKeyPending,
                titleVisibility: .visible
            ) {
                Button("Clear key", role: .destructive) {
                    AskKeychain.delete(endpoint: config.ask.endpoint)
                    askKeyStored = false
                    askKeyInput = ""
                    askKeyMessage = "Key removed."
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The key is deleted from the encrypted local key file. This cannot be undone.")
            }
            .confirmationDialog(
                "Remove silent browser theming?",
                isPresented: $removePoliciesPending,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    Task { @MainActor in
                        await theming.removeSilentTheming()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Palette deletes the managed preference files it owns. Browsers fall back to their own colour; running browsers may need a restart.")
            }
    }

    private var observedView: some View {
        configuredView
            .onChange(of: config) { _, _ in schedulePersist() }
            .onChange(of: engines) { _, _ in schedulePersist() }
            .onChange(of: bookmarks) { _, _ in
                bookmarksDirty = true
                schedulePersist()
            }
            .onChange(of: cheatsheetFolders) { _, _ in schedulePersist() }
            .onChange(of: cheatsheetExtensions) { _, _ in schedulePersist() }
            .onChange(of: providerOrder) { _, _ in schedulePersist() }
            .onChange(of: disabledProviders) { _, _ in schedulePersist() }
            .onChange(of: globalProviders) { _, _ in schedulePersist() }
            .onChange(of: providerAliasesDraft) { _, _ in schedulePersist() }
            .onChange(of: terminalShellChoice) { _, _ in schedulePersist() }
            .onChange(of: focusedBindingID) { old, _ in
                if let old { commitBindingValue(old) }
            }
            .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            .onChange(of: config.ask.endpoint) { _, _ in
                normalizeAskModel()
                askKeyStored = AskKeychain.hasStoredKey(for: config.ask.endpoint)
                askKeyMessage = nil
            }
    }

    private var configuredView: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailPane
        }
        // Settings is one window with a fixed sidebar; hide AppKit's automatic
        // sidebar-collapse button so the title stands alone.
        .toolbar(removing: .sidebarToggle)
        .onReceive(NotificationCenter.default.publisher(for: .paletteSettingsTab)) { note in
            guard let index = note.object as? Int, let tab = SettingsTab(rawValue: index) else { return }
            settingsSearch = ""
            selectedTab = tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteSettingsClearSearch)) { _ in
            settingsSearch = ""
            settingsSearchFocused = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteSettingsSearch)) { note in
            guard let query = note.object as? String else { return }
            settingsSearch = query
            settingsSearchFocused = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteSettingsEdit)) { note in
            guard let edit = note.object as? [String: String] else { return }
            applyScriptEdit(edit)
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteSettingsJump)) { note in
            guard let anchor = note.object as? String else { return }
            settingsJump = SettingsJump(anchor: anchor, token: (settingsJump?.token ?? 0) + 1)
        }
        .frame(minWidth: 820, minHeight: 560)
        .background {
            settingsBackdrop
        }
        .preferredColorScheme(theme.appearance == "light" ? .light : .dark)
        .tint(linkColor)
        .task {
            // Poll the same service the menu reads, so a timer armed from the
            // menu shows up here without reopening Settings.
            while !Task.isCancelled {
                keepAwakeStatus = await keepAwake.snapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                Group {
                    if settingsSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                        ScrollView {
                            contentColumn
                        }
                        .mask(bottomFadeMask)
                    } else {
                        settingsSearchResults
                    }
                }
                .environment(\.settingsHighlight, settingsHighlight)
                .task(id: settingsJump) {
                    await jumpToSearchTarget(settingsJump, proxy: proxy)
                }
            }

            Divider()
            footer
        }
        .navigationTitle(selectedTab.title)
    }

    private var settingsBackdrop: some View {
        ZStack {
            if !reduceTransparency {
                GlassBackdrop(material: .hudWindow)
            }
            theme.color(theme.palette.bg)
                .opacity(reduceTransparency ? 1 : (theme.window.glass ? theme.window.glassOpacity : 1))
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
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
                            .font(theme.font(size: 13))
                            .tag(tab)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .tint(theme.color(theme.palette.accent))
        }
        .background(
            reduceTransparency
                ? theme.color(theme.palette.surface).opacity(1)
                : theme.color(theme.palette.bg).opacity(0.35)
        )
        .navigationSplitViewColumnWidth(
            min: scriptMode ? 215 : 195,
            ideal: 215,
            max: scriptMode ? 215 : 270
        )
    }

    /// Hand-built rather than `.searchable`: the system field cannot render the
    /// custom result list or drive the jump-and-pulse, so the sidebar keeps it.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(muted)
            TextField("Search settings", text: $settingsSearch)
                .textFieldStyle(.plain)
                .focused($settingsSearchFocused)
                .onExitCommand {
                    settingsSearch = ""
                    settingsSearchFocused = false
                }
            if !settingsSearch.isEmpty {
                Button {
                    settingsSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(muted)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.color(theme.palette.elevated).opacity(0.5))
        )
        .background(
            Button("") { settingsSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }

    // MARK: - Column and footer

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            selectedSettingsContent
        }
        .frame(maxWidth: contentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 6)
        .padding(.top, 20)
        .padding(.bottom, 32)
    }

    /// A soft cut-off above the footer; the extra bottom padding keeps the last
    /// card clear of it at 820×560.
    private var bottomFadeMask: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.black)
            LinearGradient(
                colors: [.black, .black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 30)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            switch saveState {
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Could not save: \(message)")
                    .foregroundStyle(.red)
            case .pending:
                PaletteSpinner()
                Text("Saving…")
            case .saved:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Saved")
            case .idle:
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(muted)
                Text("Changes save automatically")
            }
            Spacer(minLength: 12)
            if issueCount > 0 {
                Text("\(issueCount) \(issueCount == 1 ? "value needs" : "values need") attention")
                    .foregroundStyle(.orange)
            }
            Button("Reset \(selectedTab.title)…") { resetPending = true }
                .controlSize(.small)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.color(theme.palette.surface).opacity(reduceTransparency ? 1 : 0.65))
    }

    // MARK: - Cards and rows

    private func card<Content: View>(
        _ title: String?,
        anchor: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        card(title, anchor: anchor, content: content, footer: { EmptyView() })
    }

    private func card<Content: View, Footer: View>(
        _ title: String?,
        anchor: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Group {
                    if let anchor {
                        Text(title).searchTarget(anchor)
                    } else {
                        Text(title)
                    }
                }
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.color(theme.palette.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        theme.appearance == "light"
                            ? muted
                            : theme.color(theme.palette.border).opacity(0.55),
                        lineWidth: 1
                    )
            )
            footer()
                .font(.caption)
                .foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fieldRow<Content: View>(
        _ title: String,
        help: String? = nil,
        error: String? = nil,
        anchor: String? = nil,
        @ViewBuilder control: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(theme.font(size: 13))
            control()
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .searchTarget(anchor ?? "row-\(title)")
    }

    private func toggleRow(
        _ title: String,
        isOn: Binding<Bool>,
        help: String? = nil,
        anchor: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox)
                .font(theme.font(size: 13))
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .searchTarget(anchor ?? "row-\(title)")
    }

    private func pickerRow<Content: View>(
        _ title: String,
        help: String? = nil,
        anchor: String? = nil,
        @ViewBuilder control: () -> Content
    ) -> some View {
        fieldRow(title, help: help, anchor: anchor, control: control)
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

    /// A bordered number field with its unit inside the border, so large
    /// ranges can drop the stepper without leaving a floating "pt".
    private func numberField(_ title: String, value: Binding<Int>, unit: String) -> some View {
        ZStack(alignment: .trailing) {
            TextField(title, value: value, format: .number)
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .padding(.leading, 6)
                .padding(.trailing, unit.isEmpty ? 6 : 22)
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(muted)
                    .padding(.trailing, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: unit.isEmpty ? 72 : 88, height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private func numberField(_ title: String, value: Binding<Double>, unit: String) -> some View {
        ZStack(alignment: .trailing) {
            TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .padding(.leading, 6)
                .padding(.trailing, unit.isEmpty ? 6 : 22)
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(muted)
                    .padding(.trailing, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: unit.isEmpty ? 72 : 88, height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    /// Label above, number field and stepper beneath. `automatic` writes the
    /// config's 0 sentinel and disables both controls when checked.
    private func numericRow(
        _ title: String,
        value: Binding<Int>,
        in range: ClosedRange<Int>,
        step: Int = 1,
        unit: String = "",
        automatic: Binding<Bool>? = nil,
        automaticValue: String? = nil,
        anchor: String? = nil
    ) -> some View {
        let bound = clamped(value, to: range)
        return fieldRow(title, anchor: anchor) {
            HStack(spacing: 6) {
                if automatic?.wrappedValue == true {
                    Text(automaticValue ?? "Automatic")
                        .foregroundStyle(muted)
                        .frame(width: 88, alignment: .trailing)
                } else {
                    numberField(title, value: bound, unit: unit)
                }
                if range.upperBound - range.lowerBound <= 1_200 {
                    Stepper(title, value: bound, in: range, step: step)
                        .labelsHidden()
                        .disabled(automatic?.wrappedValue == true)
                        .tint(muted)
                }
                if let automatic {
                    Toggle("Automatic", isOn: automatic)
                        .toggleStyle(.checkbox)
                        .padding(.leading, 8)
                }
            }
        }
    }

    private func numericRow(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 1,
        unit: String = "",
        automatic: Binding<Bool>? = nil,
        automaticValue: String? = nil,
        anchor: String? = nil
    ) -> some View {
        let bound = clamped(value, to: range)
        return fieldRow(title, anchor: anchor) {
            HStack(spacing: 6) {
                if automatic?.wrappedValue == true {
                    Text(automaticValue ?? "Automatic")
                        .foregroundStyle(muted)
                        .frame(width: 88, alignment: .trailing)
                } else {
                    numberField(title, value: bound, unit: unit)
                }
                if range.upperBound - range.lowerBound <= 1_200 {
                    Stepper(title, value: bound, in: range, step: step)
                        .labelsHidden()
                        .disabled(automatic?.wrappedValue == true)
                        .tint(muted)
                }
                if let automatic {
                    Toggle("Automatic", isOn: automatic)
                        .toggleStyle(.checkbox)
                        .padding(.leading, 8)
                }
            }
        }
    }

    private var clearAfterSecondsBinding: Binding<Int> {
        Binding(
            get: { config.clipboard.clearAfterMs / 1_000 },
            set: { config.clipboard.clearAfterMs = $0 * 1_000 }
        )
    }

    private var maxClipboardImageMBBinding: Binding<Int> {
        Binding(
            get: { config.clipboard.maxImageBytes / (1024 * 1024) },
            set: { config.clipboard.maxImageBytes = $0 * 1024 * 1024 }
        )
    }

    private var uiSizeAutomatic: Binding<Bool> {
        Binding(
            get: { config.typography.uiSize == 0 },
            set: { automatic in
                config.typography.uiSize = automatic ? 0 : 14
            }
        )
    }

    private var monoSizeAutomatic: Binding<Bool> {
        Binding(
            get: { config.typography.monoSize == 0 },
            set: { automatic in
                config.typography.monoSize = automatic ? 0 : 12
            }
        )
    }

    private var previewSizeAutomatic: Binding<Bool> {
        Binding(
            get: { config.typography.previewSize == 0 },
            set: { automatic in
                config.typography.previewSize = automatic ? 0 : 13
            }
        )
    }

    /// 0 is the loader's sentinel for "Kitty's size, then the theme".
    private var terminalFontSizeAutomatic: Binding<Bool> {
        Binding(
            get: { config.terminalSession.fontSize == 0 },
            set: { automatic in
                config.terminalSession.fontSize = automatic ? 0 : 13
            }
        )
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch selectedTab {
        case .general: general
        case .launcher: launcher
        case .appearance: appearance
        case .shortcuts: shortcuts
        case .search: search
        case .ask: ask
        case .terminal: terminalSettings
        case .bookmarks: bookmarksPane
        case .cheatsheets: cheatsheetsPane
        case .webApps: webAppsPane
        case .screenshots: screenshotsPane
        case .afterCapture: afterCapturePane
        case .recordings: recordingsPane
        case .captures: capturesPane
        case .about: aboutPane
        case .providers: providerSettings
        case .providerFiles: providerFilesPane
        case .configFiles: configFilesPane
        case .diagnostics: diagnosticsPane
        case .theming: themingPane
        }
    }

    private var configURL: URL {
        PalettePaths.resolve().configFile
    }

    private var destinations: [SettingsDestination] {
        [
            .init(title: "Startup", tab: .general, anchor: "general-startup", keywords: "login start startup launch item"),
            .init(title: "Permissions", tab: .general, anchor: "general-permissions", keywords: "accessibility permission paste automation"),
            .init(title: "Notifications", tab: .general, anchor: "general-notifications", keywords: "notification timer sound alert"),
            .init(title: "Apps", tab: .general, anchor: "general-apps", keywords: "apps launcher empty screen list"),
            .init(title: "Keep Mac awake", tab: .general, anchor: "row-Keep Mac awake", keywords: "awake clamshell lid sleep power timer"),
            .init(title: "Clamshell mode", tab: .general, anchor: "row-Clamshell mode (lid closed)", keywords: "lid closed ac power"),
            .init(title: "Timer sound", tab: .general, anchor: "row-Play a sound when a timer finishes", keywords: "timer sound notification finish"),
            .init(title: "Timer notification", tab: .general, anchor: "row-Show a notification when a timer finishes", keywords: "timer sound notification finish"),
            .init(title: "Updates", tab: .general, anchor: "general-updates", keywords: "update upgrade homebrew brew release version check now automatic"),
            .init(title: "Check for updates automatically", tab: .general, anchor: "row-Check for updates automatically", keywords: "update upgrade homebrew brew release version check automatic"),
            .init(title: "Editor", tab: .general, anchor: "row-Editor", keywords: "editor neovide vscode cursor zed"),
            .init(title: "Terminal", tab: .general, anchor: "row-Terminal", keywords: "terminal binary zellij project command embedded"),
            .init(title: "Terminal app", tab: .general, anchor: "row-Terminal app", keywords: "terminal kitty ghostty ssh docker github external app"),
            .init(title: "Clipboard history", tab: .general, anchor: "row-Record clipboard history", keywords: "clipboard history entries text images files poll clear retention secrets"),
            .init(title: "Ignored clipboard apps", tab: .general, anchor: "row-Never record from", keywords: "clipboard ignore apps password manager 1password secrets bundle id"),
            .init(title: "Commands", tab: .general, anchor: "general-commands", keywords: "command prefix provider slash"),
            .init(title: "Command prefix", tab: .general, anchor: "row-Command prefix", keywords: "prefix provider command slash"),
            .init(title: "Launcher position", tab: .launcher, anchor: "launcher-position", keywords: "top center position"),
            .init(title: "Provider bar", tab: .launcher, anchor: "launcher-tabs", keywords: "provider bar top left hidden tabs"),
            .init(title: "Tabs and order", tab: .launcher, anchor: "launcher-tabs", keywords: "tabs order provider bar icons hidden sorting"),
            .init(title: "Search field", tab: .launcher, anchor: "launcher-search", keywords: "search field placeholder hint text"),
            .init(title: "Search placeholder", tab: .launcher, anchor: "row-Placeholder", keywords: "search hint placeholder text"),
            .init(title: "App order", tab: .launcher, anchor: "launcher-tabs", keywords: "alphabetical frequent sorting"),
            .init(title: "Preview layout", tab: .launcher, anchor: "row-Preview", keywords: "preview beside below layout"),
            .init(title: "Palette", tab: .theming, anchor: "appearance-theme", keywords: "palette theme browser ghostty search preview dark light catppuccin gruvbox aetheria"),
            .init(title: "Themes", tab: .theming, anchor: "appearance-theme", keywords: "theme browser ghostty search preview dark light catppuccin gruvbox aetheria glass material"),
            .init(title: "Theme Cards", tab: .theming, anchor: "appearance-theme", keywords: "cards gallery wallpaper desktop picture swatch flip apply shortcut"),
            .init(title: "Wallpaper folder", tab: .theming, anchor: "theming-section", keywords: "wallpaper folder directory theme cards pictures wallpapers group extract"),
            .init(title: "UI font family", tab: .appearance, anchor: "row-UI family", keywords: "font family ui typography"),
            .init(title: "UI size", tab: .appearance, anchor: "row-UI size", keywords: "font size ui typography"),
            .init(title: "Mono font family", tab: .appearance, anchor: "row-Mono family", keywords: "font family mono code typography"),
            .init(title: "Mono size", tab: .appearance, anchor: "row-Mono size", keywords: "font size mono code typography"),
            .init(title: "Preview text", tab: .appearance, anchor: "row-Preview text", keywords: "font size preview text typography"),
            .init(title: "Launcher shortcut", tab: .shortcuts, anchor: "row-Launcher shortcut", keywords: "hotkey shortcut launcher"),
            .init(title: "Global shortcuts", tab: .shortcuts, anchor: "shortcuts-global", keywords: "global hotkey shortcut launcher clipboard terminal ask"),
            .init(title: "Clipboard shortcut", tab: .shortcuts, anchor: "row-Clipboard shortcut", keywords: "hotkey shortcut clipboard"),
            .init(title: "Terminal shortcut", tab: .shortcuts, anchor: "row-Terminal shortcut", keywords: "hotkey shortcut terminal"),
            .init(title: "Scratchpad list", tab: .shortcuts, anchor: "row-Scratchpad list", keywords: "hotkey shortcut scratchpad notes list"),
            .init(title: "Ask shortcut", tab: .shortcuts, anchor: "row-Ask shortcut", keywords: "hotkey shortcut ask"),
            .init(title: "Screenshot shortcuts", tab: .shortcuts, anchor: "shortcuts-capture", keywords: "screenshot screen region window recording hotkey"),
            .init(title: "Screenshots and recording", tab: .shortcuts, anchor: "shortcuts-capture", keywords: "screenshot screen region window recording capture hotkey"),
            .init(title: "Providers & actions", tab: .shortcuts, anchor: "shortcuts-catalog", keywords: "providers actions catalog command shortcuts"),
            .init(title: "Custom hotkeys", tab: .shortcuts, anchor: "shortcuts-bindings", keywords: "binding launch command provider url shortcut hotkey"),
            .init(title: "Web search", tab: .search, anchor: "row-Show web results in search", keywords: "web search engine google duckduckgo github youtube"),
            .init(title: "Search engines", tab: .search, anchor: "search-engines", keywords: "engine url keyword bang !g"),
            .init(title: "Ask provider", tab: .ask, anchor: "row-Provider", keywords: "ask endpoint model"),
            .init(title: "Ask model", tab: .ask, anchor: "row-Model", keywords: "ask model tokens fallback"),
            .init(title: "API key", tab: .ask, anchor: "ask-model", keywords: "api key token secret"),
            .init(title: "Ask history", tab: .ask, anchor: "row-Keep questions and answers", keywords: "ask history retention"),
            .init(title: "Embedded Terminal", tab: .terminal, anchor: "terminal-session", keywords: "terminal session zellij tmux fish zsh shell font"),
            .init(title: "Terminal session", tab: .terminal, anchor: "row-Session", keywords: "terminal session zellij tmux fish zsh shell"),
            .init(title: "Terminal font", tab: .terminal, anchor: "row-Font family", keywords: "terminal font family size"),
            .init(title: "Bookmarks", tab: .bookmarks, anchor: "bookmarks-list", keywords: "bookmark url keywords browser"),
            .init(title: "Cheatsheets", tab: .cheatsheets, anchor: "cheatsheets-folders", keywords: "cheatsheet reference pdf html markdown text image folder book extensions"),
            .init(title: "Cheatsheet folders", tab: .cheatsheets, anchor: "cheatsheets-folders", keywords: "cheatsheet reference pdf html markdown text image folder book"),
            .init(title: "Web Apps", tab: .webApps, anchor: "webapps-browser", keywords: "browser helium chrome chromium web app"),
            .init(title: "Web app browser", tab: .webApps, anchor: "webapps-browser", keywords: "browser helium chrome chromium web app"),
            .init(title: "Screenshots", tab: .screenshots, anchor: "screenshots-destination", keywords: "screenshot capture delay format save folder"),
            .init(title: "Screenshot destination", tab: .screenshots, anchor: "screenshots-destination", keywords: "screenshot capture delay format save folder"),
            .init(title: "After a capture", tab: .afterCapture, anchor: "search-after-capture", keywords: "cursor clicks shutter thumbnail annotator preview hide palette"),
            .init(title: "Recordings", tab: .recordings, anchor: "recordings-action", keywords: "recording audio microphone display region format"),
            .init(title: "Recording action", tab: .recordings, anchor: "recordings-action", keywords: "recording audio microphone display region format"),
            .init(title: "Captures", tab: .captures, anchor: "search-captures", keywords: "captures list shots gallery folder"),
            .init(title: "About Palette", tab: .about, anchor: "settings-about", keywords: "about version build commit chip macos architecture config state logs reveal diagnostics github releases issue author myleshen licence"),
            .init(title: "Plain queries", tab: .providers, anchor: "providers-default", keywords: "global unprefixed plain query provider default search"),
            .init(title: "Learning", tab: .search, anchor: "search-learning", keywords: "learn learned ranking memory choices forget prefix order digest"),
            .init(title: "Provider filter", tab: .providers, anchor: "providers-default", keywords: "filter find provider"),
            .init(title: "Provider order", tab: .providers, anchor: "providers-default", keywords: "provider order visibility trigger"),
            .init(title: "Provider aliases", tab: .providers, anchor: "providers-default", keywords: "provider alias shortcut"),
            .init(title: "Provider Files", tab: .providerFiles, anchor: "providers-files", keywords: "provider commands.toml folder"),
            .init(title: "Missing tools", tab: .providers, anchor: "providers-missing-tools", keywords: "install brew missing tool devx gh fzf copy command"),
            .init(title: "File indexing", tab: .providers, anchor: "providers-indexing", keywords: "home folder index consent fd walk permissions privacy"),
            .init(title: "Config Files", tab: .configFiles, anchor: "config-files", keywords: "config log crash backup export reveal diagnostics"),
            .init(title: "Diagnostics", tab: .diagnostics, anchor: "diagnostics-lines", keywords: "diagnostics startup warnings log"),
            .init(title: "Theming", tab: .theming, anchor: "theming-section", keywords: "theming cross app palette terminal editor export managed files"),
            .init(title: "Other apps", tab: .theming, anchor: "theming-section", keywords: "other apps palette source theme wallpaper extract desktop picture follow"),
            .init(title: "Palette source", tab: .theming, anchor: "theming-section", keywords: "palette source theme wallpaper toggle disable override follow extract"),
            .init(title: "Other apps palette", tab: .theming, anchor: "theming-section", keywords: "palette source theme wallpaper extract desktop picture override"),
            .init(title: "Targets", tab: .theming, anchor: "theming-targets", keywords: "targets kitty ghostty zellij neovim fish starship bat delta btop yazi vscode zed helium apps"),
            .init(title: "Browsers", tab: .theming, anchor: "theming-browsers", keywords: "browsers helium chrome edge brave vivaldi chromium arc silent managed plist mobileconfig admin all profiles seed enable remove download"),
            .init(title: "Helium policy", tab: .theming, anchor: "theming-browsers", keywords: "helium silent managed plist mobileconfig admin all profiles seed enable remove download"),
            .init(title: "Include lines", tab: .theming, anchor: "theming-targets", keywords: "include line config-file source copy kitty ghostty zellij neovim fish starship bat delta btop yazi"),
            .init(title: "Apply", tab: .theming, anchor: "theming-section", keywords: "apply palette revert previous generated files"),
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
                HStack(spacing: 8) {
                    Text(destination.title)
                    Spacer()
                    Text(destination.tab.title)
                        .foregroundStyle(muted)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(muted)
                }
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
        .overlay {
            if matches.isEmpty {
                Text("No matching settings")
                    .foregroundStyle(muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Centre the card a search result points at, then pulse its label for two
    /// seconds. The short delay lets the freshly switched tab lay out.
    @MainActor
    private func jumpToSearchTarget(_ jump: SettingsJump?, proxy: ScrollViewProxy) async {
        guard let jump else { return }
        do {
            try await Task.sleep(for: .milliseconds(160))
            proxy.scrollTo(jump.anchor, anchor: .center)
            settingsHighlight = jump.anchor
            // Cards lay out lazily, so the first scroll can stop short on a
            // long pane; centre again once the whole pane has been measured.
            try await Task.sleep(for: .milliseconds(400))
            if reduceMotion {
                proxy.scrollTo(jump.anchor, anchor: .center)
            } else {
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(jump.anchor, anchor: .center)
                }
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

    // MARK: - Auto-apply

    private func schedulePersist() {
        saveTask?.cancel()
        saveState = .pending
        saveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    /// Writes the same `ConfigWriter.render` path the old Save button used.
    /// Invalid rows stay on screen but the file keeps their last valid value.
    private func persistNow() {
        guard config != savedConfig
            || engines != savedConfig.webSearchEngines
            || bookmarksDirty
            || providerDraftsDiffer
        else {
            saveState = .saved
            return
        }

        var next = config
        if providerPrefixIssue != nil {
            next.providerPrefix = savedConfig.providerPrefix
        }
        if hotkeyIssue(config.hotkey, required: true, among: config.hotkey) != nil {
            next.hotkey = savedConfig.hotkey
        }
        if hotkeyIssue(config.clipboardHotkey, required: true, among: config.clipboardHotkey) != nil {
            next.clipboardHotkey = savedConfig.clipboardHotkey
        }
        if hotkeyIssue(config.terminalHotkey, required: false, among: config.terminalHotkey) != nil {
            next.terminalHotkey = savedConfig.terminalHotkey
        }
        if hotkeyIssue(config.themeGalleryHotkey, required: false, among: config.themeGalleryHotkey) != nil {
            next.themeGalleryHotkey = savedConfig.themeGalleryHotkey
        }
        if hotkeyIssue(config.wallpaperGalleryHotkey, required: false, among: config.wallpaperGalleryHotkey) != nil {
            next.wallpaperGalleryHotkey = savedConfig.wallpaperGalleryHotkey
        }
        if hotkeyIssue(config.scratchpadHotkey, required: false, among: config.scratchpadHotkey) != nil {
            next.scratchpadHotkey = savedConfig.scratchpadHotkey
        }
        if hotkeyIssue(config.askHotkey, required: false, among: config.askHotkey) != nil {
            next.askHotkey = savedConfig.askHotkey
        }
        if hotkeyIssue(config.screenshotHotkey, required: false, among: config.screenshotHotkey) != nil {
            next.screenshotHotkey = savedConfig.screenshotHotkey
        }
        if hotkeyIssue(config.regionScreenshotHotkey, required: false, among: config.regionScreenshotHotkey) != nil {
            next.regionScreenshotHotkey = savedConfig.regionScreenshotHotkey
        }
        if hotkeyIssue(config.windowScreenshotHotkey, required: false, among: config.windowScreenshotHotkey) != nil {
            next.windowScreenshotHotkey = savedConfig.windowScreenshotHotkey
        }
        if hotkeyIssue(config.recordingHotkey, required: false, among: config.recordingHotkey) != nil {
            next.recordingHotkey = savedConfig.recordingHotkey
        }
        if webAppBrowserIssue != nil {
            next.webAppBrowser = savedConfig.webAppBrowser
        }
        if next.webAppBrowser.trimmingCharacters(in: .whitespaces).isEmpty,
           let firstInstalled = installedChromium.first {
            next.webAppBrowser = firstInstalled
        }

        next.webSearchEngines = WebSearchEngine.persisting(engines, over: savedConfig.webSearchEngines)
        // Rows still being filled in stay on screen but are not written. An
        // invalid or duplicate key keeps the same rule as the built-in rows.
        next.bindings = config.bindings.enumerated().compactMap { index, binding in
            let keys = binding.keys.trimmingCharacters(in: .whitespaces)
            let value = binding.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keys.isEmpty, !value.isEmpty, bindingIssue(keys: keys, index: index) == nil else {
                return nil
            }
            return binding
        }
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
        for (id, words) in savedConfig.providerAliases where !loadedIDs.contains(id) {
            if !words.isEmpty { aliasMap[id] = words }
        }
        next.providerAliases = aliasMap
        next.providerOrder = providerOrder
        next.disabledProviders = disabledProviders.filter { $0 != "apps" }
        // apps is always searched, so keep it out of the stored allowlist.
        next.globalProviders = globalProviders.filter { $0 != "apps" }
        switch terminalShellChoice {
        case "auto": next.terminalSession.shell = ""
        case "fish", "zsh": next.terminalSession.shell = terminalShellChoice
        default: break
        }
        next.cheatsheets.folders = cheatsheetFolders
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let extensions = cheatsheetExtensions
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        // An empty list would silently hide every file; keep the defaults.
        next.cheatsheets.extensions = extensions.isEmpty ? CheatsheetConfig().extensions : extensions

        if bookmarksDirty, bookmarksError == nil {
            do {
                try BookmarkStore.save(bookmarks, to: PalettePaths.resolve().bookmarksFile)
                bookmarksDirty = false
                bookmarksSaveError = nil
            } catch {
                bookmarksSaveError = error.localizedDescription
            }
        }

        if let error = onApply(next) {
            saveState = .failed(error)
        } else if let bookmarksSaveError {
            savedConfig = next
            saveState = .failed("bookmarks.toml: \(bookmarksSaveError)")
        } else {
            savedConfig = next
            saveState = .saved
        }
    }

    private var providerDraftsDiffer: Bool {
        config.providerOrder != providerOrder
            || config.disabledProviders.filter({ $0 != "apps" }) != disabledProviders
            || config.globalProviders.filter({ $0 != "apps" }) != globalProviders.filter({ $0 != "apps" })
    }

    /// Script-only surface used by `PALETTE_SCRIPT` to exercise auto-apply.
    /// shortcut: a few named fields rather than every control; add a case here
    /// when a script needs a new one.
    private func applyScriptEdit(_ edit: [String: String]) {
        guard let (key, value) = edit.first else { return }
        switch key {
        case "hotkey": config.hotkey = value
        case "clipboard_hotkey": config.clipboardHotkey = value
        case "provider_prefix": config.providerPrefix = value
        case "search_placeholder": config.searchPlaceholder = value
        case "editor_open_with": config.editorOpenWith = value
        case "web_app_browser": config.webAppBrowser = value
        case "search_position": config.searchPosition = SearchPosition(rawValue: value) ?? .top
        case "provider_bar": config.window.providerBar = ProviderBarPlacement(rawValue: value) ?? .top
        case "provider_filter": providerFilter = value
        case "settings_search": settingsSearch = value
        default:
            Log.shared.warn("Unknown settings script edit: \(key)", source: "settings")
        }
    }

    // MARK: - Validation

    private var hotkeyValues: [String] {
        [
            config.hotkey, config.clipboardHotkey, config.terminalHotkey,
            config.themeGalleryHotkey,
            config.wallpaperGalleryHotkey,
            config.scratchpadHotkey, config.askHotkey, config.screenshotHotkey,
            config.regionScreenshotHotkey, config.windowScreenshotHotkey,
            config.recordingHotkey,
        ]
    }

    private func hotkeyIssue(_ value: String, required: Bool, among _: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return required ? "Enter a shortcut. The launcher and clipboard need one." : nil
        }
        guard let spec = HotKeySpec.parse(trimmed) else {
            return "Not a valid shortcut. Click the field and press the keys you want."
        }
        // Carbon identities ignore modifier order and aliases, so opt+cmd+a
        // and cmd+opt+a are the same key even though the strings differ.
        let matches = hotkeyValues.compactMap {
            HotKeySpec.parse($0.trimmingCharacters(in: .whitespaces))
        }.filter { $0.identity == spec.identity }
        if matches.count > 1 {
            return "This shortcut is used more than once. Each one must be unique."
        }
        return nil
    }

    private var providerPrefixIssue: String? {
        let prefix = config.providerPrefix
        if prefix.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter a prefix, usually /."
        }
        // Match the loader exactly: anything but one character is replaced by
        // "/" on the next launch, so reject it here instead.
        if prefix.count != 1 {
            return "Use exactly one character, usually /."
        }
        return nil
    }

    private var installedChromium: [String] {
        BrowserCatalog.chromiumChoices.filter {
            ToolLocator.shared.appPath(named: $0) != nil
        }
    }

    private var webAppBrowserChoices: [String] {
        var result = installedChromium
        if !config.webAppBrowser.isEmpty, !result.contains(config.webAppBrowser) {
            result.append(config.webAppBrowser)
        }
        return result
    }

    /// Only a value the user changed is validated, so an existing config that
    /// names an uninstalled browser still opens and saves without nagging.
    private var webAppBrowserIssue: String? {
        guard config.webAppBrowser != initialWebAppBrowser else { return nil }
        return BrowserCatalog.validationError(for: config.webAppBrowser)
    }

    private func engineIssue(_ engine: WebSearchEngine) -> String? {
        engine.validationIssue(among: engines)
    }

    private var issueCount: Int {
        var count = 0
        if providerPrefixIssue != nil { count += 1 }
        if hotkeyIssue(config.hotkey, required: true, among: "") != nil { count += 1 }
        if hotkeyIssue(config.clipboardHotkey, required: true, among: "") != nil { count += 1 }
        if hotkeyIssue(config.terminalHotkey, required: false, among: "") != nil { count += 1 }
        if hotkeyIssue(config.themeGalleryHotkey, required: false, among: "") != nil { count += 1 }
        if hotkeyIssue(config.wallpaperGalleryHotkey, required: false, among: "") != nil { count += 1 }
        if hotkeyIssue(config.scratchpadHotkey, required: false, among: "") != nil { count += 1 }
        if hotkeyIssue(config.askHotkey, required: false, among: "") != nil { count += 1 }
        if hotkeyIssue(config.screenshotHotkey, required: false, among: "") != nil { count += 1 }
        if hotkeyIssue(config.regionScreenshotHotkey, required: false, among: "") != nil { count += 1 }
        if hotkeyIssue(config.windowScreenshotHotkey, required: false, among: "") != nil { count += 1 }
        if hotkeyIssue(config.recordingHotkey, required: false, among: "") != nil { count += 1 }
        if webAppBrowserIssue != nil { count += 1 }
        count += engines.filter { engineIssue($0) != nil }.count
        count += aliasIssues.count
        count += config.bindings.indices.filter {
            bindingIssue(keys: config.bindings[$0].keys, index: $0) != nil
        }.count
        count += bindingRowIDs.filter { shortcutErrors[$0.uuidString] != nil }.count
        count += commands.filter { catalogIssue($0) != nil }.count
        return count
    }

    // MARK: - General

    private var general: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Startup", anchor: "general-startup") {
                toggleRow("Open Palette at login", isOn: $launchAtLogin)
                if let loginMessage {
                    Text(loginMessage).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Applies immediately. If macOS asks for approval, allow Palette under System Settings › General › Login Items.")
            }

            card("Permissions", anchor: "general-permissions") {
                HStack(spacing: 8) {
                    Image(systemName: accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityTrusted ? .green : .orange)
                    Text("Accessibility")
                    Spacer()
                    Text(accessibilityTrusted ? "Enabled" : "Not granted")
                        .foregroundStyle(muted)
                }
                HStack(spacing: 8) {
                    Button("Open accessibility settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Check again") {
                        accessibilityTrusted = AXIsProcessTrusted()
                    }
                }
            } footer: {
                Text("Needed for direct paste and recording system shortcuts. A new install may ask once; updates keep the same signature.")
            }

            card("Power", anchor: "general-power") {
                toggleRow("Keep Mac awake", isOn: keepAwakeBinding)
                toggleRow("Clamshell mode (lid closed)", isOn: clamshellBinding)
                Text(keepAwakeSummary)
                    .font(.caption)
                    .foregroundStyle(muted)
                if let keepAwakeMessage {
                    Text(keepAwakeMessage).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Clamshell asks for an administrator password and keeps working with the lid shut on AC power only. Turning it off leaves an active keep-awake timer alone.")
            }

            card("Notifications", anchor: "general-notifications") {
                toggleRow("Play a sound when a timer finishes", isOn: $config.timer.sound)
                toggleRow("Show a notification when a timer finishes", isOn: $config.timer.notify)
            } footer: {
                Text("Presets live in config.toml under [timer]. Start any duration with /timer 25m, /timer 1h30m, or /timer 1:30.")
            }

            card("Updates", anchor: "general-updates") {
                toggleRow("Check for updates automatically", isOn: $config.updates.automatic)
                HStack(spacing: 8) {
                    Button("Check now") { updates.checkNow() }
                        .disabled(updates.status == .checking)
                    if updates.status == .checking {
                        PaletteSpinner()
                    }
                    Text(updateStatusText)
                        .font(.caption)
                        .foregroundStyle(updateStatusIsError ? danger : muted)
                    Spacer(minLength: 0)
                }
                Text(lastCheckedText)
                    .font(.caption)
                    .foregroundStyle(muted)
            } footer: {
                Text("Homebrew installs updates; Palette only tells you. A newer release appears in the menu bar with an Update command that runs brew in the embedded terminal.")
            }

            card("Apps", anchor: "general-apps") {
                fieldRow("Editor") {
                    TextField("Editor", text: $config.editorOpenWith)
                        .settingsField()
                }
                fieldRow("Terminal") {
                    TextField("Terminal", text: $config.terminal)
                        .settingsField()
                }
                fieldRow("Terminal app") {
                    TextField("Terminal app", text: $config.terminalApp)
                        .settingsField()
                }
                HStack(spacing: 8) {
                    Button("Detect installed apps") { detectDefaults() }
                }
                if let appsMessage {
                    Text(appsMessage).font(.caption).foregroundStyle(muted)
                }
            } footer: {
                Text("Terminal is what Zellij, projects, and commands launch. Terminal app is the macOS app used for SSH, Docker, and GitHub logins. Examples: neovide, Visual Studio Code, Cursor, kitty, Terminal.")
            }

            card("Clipboard history", anchor: "general-clipboard") {
                toggleRow("Record clipboard history", isOn: $config.clipboard.enabled)
                numericRow("Text entries", value: $config.clipboard.maxText,
                           in: 10...10_000, step: 10)
                numericRow("Image entries", value: $config.clipboard.maxImages,
                           in: 1...100, step: 1)
                numericRow("File entries", value: $config.clipboard.maxFiles,
                           in: 1...200, step: 1)
                numericRow("Poll interval", value: $config.clipboard.pollMs,
                           in: 200...2_000, step: 50, unit: "ms")
                numericRow("Clear copied secrets after", value: clearAfterSecondsBinding,
                           in: 0...300, step: 5, unit: "s")
                numericRow("Delete history older than", value: $config.clipboard.retentionDays,
                           in: 0...3_650, step: 1, unit: "days")
                numericRow("Image storage cap", value: maxClipboardImageMBBinding,
                           in: 0...2_048, step: 50, unit: "MB")
                ignoredAppsRow
            } footer: {
                Text("Text, images and file selections are limited separately, so a run of screenshots never evicts text. Pinned entries are always kept. Copies an app marks concealed or transient are never recorded, even when that app is allowed below. Zero seconds keeps secrets until you clear the history.")
            }
            .task {
                if ignoredAppChoices.isEmpty {
                    ignoredAppChoices = await AppIndex().applications()
                }
                refreshRunningAppChoices()
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didLaunchApplicationNotification
            ).receive(on: RunLoop.main)) { _ in refreshRunningAppChoices() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didTerminateApplicationNotification
            ).receive(on: RunLoop.main)) { _ in refreshRunningAppChoices() }

            card("Commands", anchor: "general-commands") {
                fieldRow("Command prefix", error: providerPrefixIssue) {
                    TextField("Command prefix", text: $config.providerPrefix)
                        .settingsField()
                        .frame(maxWidth: 92)
                }
            } footer: {
                Text("Prefix for provider commands such as /clip and /port. Usually /.")
            }
        }
    }

    /// Password managers and token viewers that copy without marking the
    /// pasteboard. Names come from installed and running apps; a bundle id can
    /// be typed for anything not found.
    private var ignoredAppsRow: some View {
        fieldRow("Never record from") {
            VStack(alignment: .leading, spacing: 6) {
                if config.clipboard.ignoredApps.isEmpty {
                    Text("Every app is recorded.")
                        .font(.caption)
                        .foregroundStyle(muted)
                } else {
                    ForEach(config.clipboard.ignoredApps, id: \.self) { bundleID in
                        HStack(spacing: 8) {
                            Text(ignoredAppLabel(bundleID))
                                .font(theme.font(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button {
                                config.clipboard.ignoredApps.removeAll { $0 == bundleID }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Record from this app again")
                            .accessibilityLabel("Stop ignoring \(bundleID)")
                        }
                    }
                }
                HStack(spacing: 8) {
                    PaletteMenuButton(
                        title: "Add app…",
                        items: ignorableApps.map { PaletteMenuItem(id: $0.id, title: $0.name) },
                        theme: theme,
                        onSelect: { addIgnoredApp($0) }
                    )
                    .frame(maxWidth: 160)
                    .disabled(ignorableApps.isEmpty)
                    TextField("Bundle id, e.g. com.1password.1password", text: $ignoredAppDraft)
                        .settingsField()
                        .onSubmit { addIgnoredApp(ignoredAppDraft) }
                    Button("Add") { addIgnoredApp(ignoredAppDraft) }
                        .disabled(ignoredAppDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// Cached, so a body pass never walks NSWorkspace. Workspace notifications
    /// keep the list current while the pane is open.
    @MainActor
    private func refreshRunningAppChoices() {
        var seen = Set<String>()
        runningAppChoices = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty,
                  seen.insert(bundleID).inserted else { return nil }
            return (bundleID, app.localizedName ?? bundleID)
        }
    }

    private var ignorableApps: [(id: String, name: String)] {
        var seen = Set<String>()
        var rows: [(id: String, name: String)] = []
        for record in ignoredAppChoices {
            guard let bundleID = record.bundleID, seen.insert(bundleID).inserted else { continue }
            rows.append((bundleID, record.name))
        }
        for app in runningAppChoices where seen.insert(app.id).inserted {
            rows.append(app)
        }
        return rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// App name with its bundle id, or just the id when nothing installed or
    /// running matches.
    private func ignoredAppLabel(_ bundleID: String) -> String {
        guard let name = ignorableApps.first(where: { $0.id == bundleID })?.name else { return bundleID }
        return "\(name) (\(bundleID))"
    }

    private func addIgnoredApp(_ raw: String) {
        let bundleID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty, !config.clipboard.ignoredApps.contains(bundleID) else { return }
        config.clipboard.ignoredApps.append(bundleID)
        ignoredAppDraft = ""
    }

    // MARK: - About

    private var updateStatusText: String {
        switch updates.status {
        case .idle: return ""
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .available(let version): return "Palette \(version) available"
        case .failed(let message): return message
        }
    }

    private var updateStatusIsError: Bool {
        if case .failed = updates.status { return true }
        return false
    }

    private var lastCheckedText: String {
        guard let date = updates.lastChecked else { return "Never checked" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("About", anchor: "settings-about") {
                aboutRow("Version", about.versionBuild)
                if let commit = about.commit {
                    aboutRow("Commit", commit)
                }
                aboutRow("macOS", AboutInfo.macOS)
                aboutRow("Chip", AboutInfo.chip)
                aboutLinkRow("Licence", "MIT", AboutInfo.licence)
                Divider()
                aboutFolderRow("Config folder", url: palettePaths.configDir)
                aboutFolderRow("State folder", url: palettePaths.stateDir)
                aboutFolderRow("Logs folder", url: palettePaths.logsDir)
                Divider()
                HStack(spacing: 12) {
                    aboutLink("GitHub", AboutInfo.repo)
                    aboutLink("Releases", AboutInfo.releases)
                    aboutLink("Report an Issue", AboutInfo.issues)
                }
                HStack(spacing: 4) {
                    Text("Built by")
                    Text(AboutInfo.author).fontWeight(.semibold)
                    Text("·").foregroundStyle(muted)
                    Link(AboutInfo.email, destination: URL(string: "mailto:\(AboutInfo.email)")!)
                        .foregroundStyle(linkColor)
                }
                .font(theme.font(size: 12))
                Button(copiedDiagnostics ? "Copied" : "Copy Diagnostics") {
                    AboutInfo.copyDiagnostics()
                    copiedDiagnostics = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedDiagnostics = false
                    }
                }
                .controlSize(.small)
            } footer: {
                Text("Palette is a keyboard-first launcher for macOS. Built with SwiftUI + AppKit.")
            }
        }
    }

    private var about: AboutInfo { AboutInfo() }
    private var palettePaths: PalettePaths { PalettePaths.resolve() }

    private func aboutRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(theme.font(size: 13))
            Spacer(minLength: 12)
            Text(value)
                .font(theme.font(size: 13))
                .foregroundStyle(muted)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .searchTarget("row-\(title)")
    }

    private func aboutLinkRow(_ title: String, _ value: String, _ url: URL) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Link(value, destination: url)
        }
        .font(theme.font(size: 13))
        .searchTarget("row-\(title)")
    }

    private func aboutFolderRow(_ title: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                    .font(theme.font(size: 13))
                Spacer(minLength: 12)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
            }
            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption)
                .foregroundStyle(muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .searchTarget("row-\(title)")
    }

    private func aboutLink(_ title: String, _ url: URL) -> some View {
        Button(title) { NSWorkspace.shared.open(url) }
            .buttonStyle(.link)
            .font(theme.font(size: 12))
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
        let clamshell: String
        if keepAwakeStatus.clamshell {
            clamshell = keepAwakeStatus.clamshellRequiresPower
                ? "Clamshell armed but inactive — needs AC power"
                : "Clamshell on"
        } else {
            clamshell = "Clamshell off"
        }
        if keepAwakeStatus.active {
            if let endsAt = keepAwakeStatus.endsAt {
                return "Awake until \(Self.timeFormatter.string(from: endsAt)) · \(clamshell)"
            }
            return "Awake indefinitely · \(clamshell)"
        }
        return "No timer · \(clamshell)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func detectDefaults() {
        let editors = ["neovide", "Visual Studio Code", "Cursor", "Zed", "Sublime Text"]
        if let editor = editors.first(where: {
            ToolLocator.shared.appPath(named: $0) != nil
        }) {
            config.editorOpenWith = editor
        }
        appsMessage = "Detected an installed editor where available."
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginMessage = nil
        } catch {
            loginMessage = "Could not update the login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Launcher

    private var launcher: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Position", anchor: "launcher-position") {
                pickerRow("Opens at") {
                    Picker("Opens at", selection: $config.searchPosition) {
                        Text("Top").tag(SearchPosition.top)
                        Text("Center").tag(SearchPosition.center)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
            } footer: {
                Text("Top drops down from the menu bar; Center opens in the middle of the screen.")
            }

            card("Search field", anchor: "launcher-search") {
                fieldRow(
                    "Placeholder",
                    help: "Leave empty to use the theme's “\(theme.search.placeholder)”."
                ) {
                    TextField("Search placeholder", text: $config.searchPlaceholder)
                        .settingsField()
                }
            } footer: {
                Text("The hint shown in the empty launcher field before you type.")
            }

            card("Tabs and order", anchor: "launcher-tabs") {
                pickerRow("Provider bar") {
                    Picker("Provider bar", selection: $config.window.providerBar) {
                        Text("Top").tag(ProviderBarPlacement.top)
                        Text("Left").tag(ProviderBarPlacement.left)
                        Text("Hidden").tag(ProviderBarPlacement.hidden)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
                pickerRow("App order") {
                    PaletteMenuPicker(
                        selection: $config.appSort,
                        choices: [
                            PaletteMenuChoice(value: .alphabetical, label: "Alphabetical"),
                            PaletteMenuChoice(value: .frequent, label: "Most used"),
                        ],
                        theme: theme
                    )
                    .frame(maxWidth: 260, alignment: .leading)
                }
                pickerRow("Preview") {
                    PaletteMenuPicker(
                        selection: $config.window.previewLayout,
                        choices: [
                            PaletteMenuChoice(value: .auto, label: "Automatic (frame width)"),
                            PaletteMenuChoice(value: .below, label: "Below the list"),
                            PaletteMenuChoice(value: .beside, label: "Beside the list"),
                        ],
                        theme: theme
                    )
                    .frame(maxWidth: 260, alignment: .leading)
                }
                toggleRow("Site favicons", isOn: $config.window.favicons)
            } footer: {
                Text("Provider tabs are the chip strip above the list, or the rail on the left. Hidden keeps Tab and /trigger for switching. Turn individual providers on or off under Providers. The launcher keeps one fixed frame per screen; the preview fills part of it instead of resizing it. Site favicons fetch web-app icons from Google; turn them off to keep hostnames on this Mac.")
            }
        }
    }

    // MARK: - Embedded Terminal

    private var terminalSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Terminal", anchor: "terminal-session") {
                pickerRow("Session") {
                    PaletteMenuPicker(
                        selection: $config.terminalSession.multiplexer,
                        choices: [
                            PaletteMenuChoice(value: .auto, label: "Auto"),
                            PaletteMenuChoice(value: .zellij, label: "Zellij"),
                            PaletteMenuChoice(value: .tmux, label: "tmux"),
                            PaletteMenuChoice(value: .none, label: "Plain shell"),
                        ],
                        theme: theme
                    )
                    .frame(maxWidth: 260, alignment: .leading)
                }
                fieldRow("Session name") {
                    TextField("Session name", text: $config.terminalSession.name)
                        .settingsField()
                }
                pickerRow("Shell") {
                    PaletteMenuPicker(
                        selection: $terminalShellChoice,
                        choices: [
                            PaletteMenuChoice(value: "auto", label: "Auto (fish, then zsh)"),
                            PaletteMenuChoice(value: "fish", label: "Fish"),
                            PaletteMenuChoice(value: "zsh", label: "Zsh"),
                            PaletteMenuChoice(value: "custom", label: "Custom…"),
                        ],
                        theme: theme
                    )
                    .frame(maxWidth: 260, alignment: .leading)
                }
                if terminalShellChoice == "custom" {
                    fieldRow("Custom shell executable") {
                        TextField("Custom shell executable", text: $config.terminalSession.shell)
                            .settingsField()
                    }
                }
                fieldRow("Font family") {
                    fontFamilyPicker($config.terminalSession.font, inherited: theme.typography.mono)
                }
                numericRow("Font size", value: $config.terminalSession.fontSize,
                           in: 8...48, step: 1, unit: "pt",
                           automatic: terminalFontSizeAutomatic,
                           automaticValue: "Automatic")
            } footer: {
                Text("Auto uses Zellij, then tmux, then a plain shell. Plain shells end when the panel closes. A size of 0 uses Kitty's font size, then the theme. Use a Nerd Font for icons.")
            }
        }
        .task { await loadFontFamilies() }
    }

    // MARK: - Appearance

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Typography", anchor: "appearance-typography") {
                fieldRow("UI family", help: "Leave on Inherit to use the theme's \(theme.typography.family).") {
                    fontFamilyPicker($config.typography.uiFamily, inherited: theme.typography.family)
                }
                numericRow("UI size", value: $config.typography.uiSize,
                           in: 9...48, step: 1, unit: "pt",
                           automatic: uiSizeAutomatic,
                           automaticValue: "\(Int(theme.typography.size)) pt")
                fieldRow("Mono family", help: "Used by code, terminal previews, and monospaced values. Inherit uses the theme's \(theme.typography.mono).") {
                    fontFamilyPicker($config.typography.monoFamily, inherited: theme.typography.mono)
                }
                numericRow("Mono size", value: $config.typography.monoSize,
                           in: 9...48, step: 1, unit: "pt",
                           automatic: monoSizeAutomatic,
                           automaticValue: "\(Int(theme.typography.monoSize)) pt")
                numericRow("Preview text", value: $config.typography.previewSize,
                           in: 9...24, step: 1, unit: "pt",
                           automatic: previewSizeAutomatic,
                           automaticValue: "\(Int(theme.previewTextSize)) pt")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview").font(.caption).foregroundStyle(muted)
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
                        .foregroundStyle(muted)
                    Text("preview: clipboard, paths, snippets")
                        .font(.custom(
                            config.typography.monoFamily.isEmpty ? "Menlo" : config.typography.monoFamily,
                            size: config.typography.previewSize == 0 ? 13 : config.typography.previewSize
                        ))
                        .foregroundStyle(muted)
                }
                Button("Reset typography to theme") {
                    config.typography = TypographyConfig()
                }
            } footer: {
                Text("Automatic uses the theme's size. Family pickers list installed fonts. Inherit uses the theme's font; a configured family that is no longer installed stays selected and is marked missing.")
            }

            card("Glass and materials") {
                Text("Glass, material, border, and opacity are properties of each theme file.")
                    .font(.caption)
                    .foregroundStyle(muted)
                Button("Open themes folder") { onOpen(PalettePaths.resolve().themesDir) }
            } footer: {
                Text("Palette replaces glass with an opaque background when Reduce Transparency is on, and Settings follows the same rule.")
            }
        }
        .task { await loadFontFamilies() }
    }

    // MARK: - Theming

    private var sourceControls: ThemingSourceControls {
        ThemingSourceControls(source: config.theming.source)
    }

    private var themeGalleryShortcutLabel: String {
        let keys = config.themeGalleryHotkey.trimmingCharacters(in: .whitespaces)
        guard !keys.isEmpty else { return "Not set" }
        return HotKeySpec.parse(keys)?.prettyDisplay ?? keys
    }

    private var themingPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Palette", anchor: "appearance-theme") {
                pickerRow("Mode") {
                    Picker("Mode", selection: $config.theme.mode) {
                        Text("Auto").tag(ThemeMode.auto)
                        Text("Dark").tag(ThemeMode.dark)
                        Text("Light").tag(ThemeMode.light)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
                ThemeBrowserView(
                    themeManager: themeManager,
                    selection: $config.theme,
                    themesDirectory: themesDirectory,
                    onUseTheme: {
                        config.theming = WallpaperCardPolicy.themeConfig(from: config.theming)
                    }
                )
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Theme Cards").font(theme.font(size: 13))
                        Text("Large card gallery with left and right neighbours peeking; the desktop picture palette comes first. Its wallpaper folder is under Other apps.")
                            .font(.caption)
                            .foregroundStyle(muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(themeGalleryShortcutLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(muted)
                    Button("Open") { onThemeCards() }
                        .controlSize(.small)
                        .accessibilityLabel("Open Theme Cards gallery")
                }
                Button("Open themes folder") { onOpen(PalettePaths.resolve().themesDir) }
            } footer: {
                Text("Theme files use TOML. Browsing previews a theme without changing anything; Use Theme applies it and saves the choice for the current mode. This is Palette's own palette.")
            }

            card("Other apps", anchor: "theming-section") {
                toggleRow(
                    "Use Palette's palette in other apps",
                    isOn: Binding(
                        get: { config.theming.enabled },
                        set: { enabled in
                            config.theming.enabled = enabled
                            if !enabled {
                                // Master off must stop the apps using Palette now,
                                // not on the next Apply.
                                Task { @MainActor in _ = theming.removeAllIncludes() }
                            }
                        }
                    ),
                    help: "Off by default. Palette always themes itself; this also writes managed palette files for terminals and editors."
                )
                if let policyWarning {
                    Text(policyWarning)
                        .font(.caption)
                        .foregroundStyle(danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !config.theming.enabled {
                    Text("Palette themes itself here and in Appearance; enable this to also theme other apps.")
                        .font(.caption)
                        .foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    pickerRow(
                        "Palette source",
                        help: "Theme follows the theme picker; Wallpaper samples the desktop picture for the files Palette writes for other apps."
                    ) {
                        Picker("Palette source", selection: $config.theming.source) {
                            Text("Theme").tag(ThemingSource.theme)
                            Text("Wallpaper").tag(ThemingSource.wallpaper)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        pickerRow("Theme override", help: "Empty follows the Palette theme above.") {
                            PaletteMenuPicker(
                                selection: otherAppsThemeBinding,
                                choices: [PaletteMenuChoice(value: "", label: "Use the Palette theme")]
                                    + otherAppsThemeChoices.map { info in
                                        PaletteMenuChoice(
                                            value: info.name,
                                            label: "\(info.shortDisplayName) · \(info.section.title)"
                                        )
                                    },
                                theme: theme
                            )
                            .frame(maxWidth: 360, alignment: .leading)
                        }
                        if let reason = sourceControls.themeDisabledReason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .disabled(!sourceControls.themeEnabled)
                    .opacity(sourceControls.themeEnabled ? 1 : 0.45)

                    VStack(alignment: .leading, spacing: 8) {
                        pickerRow(
                            "Wallpaper folder",
                            help: "Both this palette and the Theme Cards wallpapers group read it. Empty shows the desktop picture card only."
                        ) {
                            TextField("~/wallpapers", text: $config.theming.wallpaperDirectory)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 380)
                        }
                        if wallpaperFolderMissing {
                            Text("Folder not found")
                                .font(.caption)
                                .foregroundStyle(danger)
                        }
                        HStack(alignment: .top, spacing: 12) {
                            Group {
                                if let wallpaperPreviewImage {
                                    Image(nsImage: wallpaperPreviewImage)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(theme.color(theme.palette.elevated))
                                        .overlay {
                                            Image(systemName: "photo")
                                                .foregroundStyle(muted)
                                        }
                                }
                            }
                            .frame(width: 168, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(theme.color(theme.palette.border), lineWidth: 1)
                            )

                            VStack(alignment: .leading, spacing: 6) {
                                Text(theming.wallpaperURLs.first?.lastPathComponent ?? "No desktop picture found")
                                    .font(.caption)
                                    .foregroundStyle(muted)
                                    .lineLimit(2)
                                Button("Extract palette") {
                                    Task { @MainActor in
                                        await theming.previewWallpaper(config: config.theming)
                                    }
                                }
                                .disabled(theming.busy)
                                if let palette = theming.previewPalette {
                                    HStack(spacing: 3) {
                                        ForEach(Array(palette.ansi.enumerated()), id: \.offset) { _, hex in
                                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                                .fill(theme.color(hex))
                                                .frame(width: 14, height: 18)
                                        }
                                    }
                                    Text("\(palette.background) on \(palette.foreground)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(muted)
                                }
                            }
                        }
                        .task {
                            wallpaperPreviewImage = theming.wallpaperURLs.first.flatMap(NSImage.init(contentsOf:))
                        }
                        toggleRow(
                            "Follow wallpaper changes",
                            isOn: $config.theming.followWallpaper,
                            help: "Checks the desktop image every five seconds while Palette is running. Only wallpaper-sourced palettes auto-apply."
                        )
                        pickerRow("Appearance") {
                            Picker("Appearance", selection: $config.theming.darkMode) {
                                Text("Auto").tag("auto")
                                Text("Dark").tag("dark")
                                Text("Light").tag("light")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 260)
                        }
                        if let reason = sourceControls.wallpaperDisabledReason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .disabled(!sourceControls.wallpaperEnabled)
                    .opacity(sourceControls.wallpaperEnabled ? 1 : 0.45)

                    Divider().padding(.vertical, 4)
                    HStack(spacing: 8) {
                        Button("Apply Palette") { applyTheming() }
                            .disabled(theming.busy)
                        Button("Revert to previous") { revertTheming() }
                            .disabled(theming.busy || !theming.hasPrevious)
                        if theming.busy {
                            PaletteSpinner()
                        }
                    }
                    Text(theming.status)
                        .font(.caption)
                        .foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let result = theming.lastResult {
                        if !result.written.isEmpty {
                            Text("Wrote: \(result.written.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(muted)
                        }
                        ForEach(result.changes, id: \.self) { change in
                            Text("Changed \(change)")
                                .font(.caption)
                                .foregroundStyle(muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(result.targets, id: \.id) { target in
                            Text("\(target.title): \(target.note)")
                                .font(.caption)
                                .foregroundStyle(muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(result.notices, id: \.self) { note in
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } footer: {
                Text("Theme palettes apply when you press Apply Palette. Wallpaper palettes can also follow the desktop image automatically. Revert swaps back the previous generated set in one step.")
            }

            if config.theming.enabled {
                card("Browsers", anchor: "theming-browsers") {
                    Text("Silent updates · all profiles of that browser · seed colour, approximate")
                        .font(.caption)
                        .foregroundStyle(muted)
                    ForEach(theming.browserRows()) { browser in
                        VStack(alignment: .leading, spacing: 2) {
                            if browser.supportsThemePolicy {
                                toggleRow(
                                    browser.targetTitle,
                                    isOn: themingTargetBinding(browser.target),
                                    help: "Managed preference \(browser.silentPlistPath)"
                                )
                            } else {
                                HStack(spacing: 8) {
                                    Toggle(browser.targetTitle, isOn: .constant(false))
                                        .toggleStyle(.checkbox)
                                        .disabled(true)
                                        .font(theme.font(size: 13))
                                    Text("Unsupported — does not implement BrowserThemeColor.")
                                        .font(.caption)
                                        .foregroundStyle(muted)
                                }
                            }
                            Text(browserPolicyStatus(browser))
                                .font(.caption)
                                .foregroundStyle(muted)
                        }
                    }

                    Divider().padding(.vertical, 4)
                    Text("Enable silent browser theming once. macOS asks for your password, removes any old Palette profile, and creates a preference file Palette owns, so later applies update it with no prompt.")
                        .font(.caption)
                        .foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !legacyProfileNames.isEmpty {
                        Text("Removing the old profile: \(legacyProfileNames).")
                            .font(.caption)
                            .foregroundStyle(muted)
                    }
                    HStack(spacing: 8) {
                        Button(theming.policyBusy ? "Enabling…" : "Enable silent browser theming…") {
                            Task { @MainActor in
                                await theming.enableSilentTheming(
                                    config.theming,
                                    background: PalettePalette(theme: theme).background
                                )
                            }
                        }
                        .disabled(theming.policyBusy || !canEnableSilentTheming)
                        .help("One administrator prompt for every selected installed browser.")
                        Button("Download profile") {
                            Task { @MainActor in
                                await theming.exportPolicyProfiles(config.theming)
                            }
                        }
                        .disabled(theming.policyBusy || selectedBrowsers.isEmpty)
                        .help("Save a .mobileconfig for the OS-managed route instead.")
                        Button("Refresh") {
                            Task { @MainActor in await theming.refreshPolicyStates() }
                        }
                        .disabled(theming.policyBusy)
                        Button("Remove…") {
                            removePoliciesPending = true
                        }
                        .disabled(theming.policyBusy)
                        if theming.policyBusy {
                            PaletteSpinner()
                        }
                    }
                    if let status = theming.policyStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = theming.policyError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } footer: {
                    Text("Helium is always listed; the other browsers appear when installed. Silent theming seeds the Palette background for every profile of that browser.")
                }
                .task { await theming.refreshPolicyStates() }

                card("Targets", anchor: "theming-targets") {
                    ForEach(ThemingTarget.allCases.filter { !$0.isBrowser }) { target in
                        if target.isImplemented {
                            let status = theming.includeStatus(for: target)
                            VStack(alignment: .leading, spacing: 2) {
                                Toggle(target.title, isOn: themingTargetBinding(target))
                                    .toggleStyle(.checkbox)
                                    .font(theme.font(size: 13))
                                Text(status.available
                                    ? status.note
                                    : "Unavailable — \(target.unavailableReason ?? target.includeHint)")
                                    .font(.caption)
                                    .foregroundStyle(muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                if status.installed {
                                    HStack(spacing: 8) {
                                        Text(theming.reloadStatus(for: target).message)
                                            .font(.caption)
                                            .foregroundStyle(muted)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if ThemingReload.canAttempt(target) {
                                            Button("Reload") {
                                                Task { @MainActor in await theming.reload(target) }
                                            }
                                            .controlSize(.small)
                                            .help("Ask the running app to re-read the Palette colours. Palette never restarts it.")
                                        }
                                        if target == .zellij {
                                            Button("Open themed session") {
                                                onOpenThemedZellij()
                                            }
                                            .controlSize(.small)
                                            .help("Open a new kitty window on a fresh Palette zellij session. zellij reads the palette only at session start, so a running session keeps its old colours.")
                                        }
                                    }
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                Toggle(target.title, isOn: .constant(false))
                                    .toggleStyle(.checkbox)
                                    .disabled(true)
                                    .font(theme.font(size: 13))
                                Text(target.statusLabel)
                                    .font(.caption)
                                    .foregroundStyle(muted)
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    Divider().padding(.vertical, 4)
                    let selected = config.theming.targets
                        .compactMap(ThemingTarget.init(rawValue:))
                        .filter(\.isImplemented)
                    DisclosureGroup("Manual setup") {
                        if selected.isEmpty {
                            Text("Pick at least one app above.")
                                .font(.caption)
                                .foregroundStyle(muted)
                        }
                        ForEach(selected) { target in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.title)
                                        .font(.caption)
                                        .foregroundStyle(muted)
                                    Text(target.includeHint)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                Button(copiedInclude == target.includeHint ? "Copied" : "Copy") {
                                    copyInclude(target.includeHint)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(muted)
                } footer: {
                    Text("Palette installs a marked block in each checked app's config and removes it when you uncheck one or turn this switch off. Starship is the exception: its config is never edited — Palette writes a remapped copy and fish exports STARSHIP_CONFIG. btop and yazi are manual: the generated theme file is left for you to point the app at. Revert restores the original files. Generated palette files stay in \(PalettePaths.resolve().themeDir.path). \(themingInstallSummary)")
                }
            }
        }
    }

    private var wallpaperFolderMissing: Bool {
        let path = config.theming.wallpaperDirectory
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = WallpaperLibrary.directory(path: path) else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    private var selectedBrowsers: [ChromiumBrowser] {
        config.theming.targets.compactMap { raw in
            guard let target = ThemingTarget(rawValue: raw) else { return nil }
            return ChromiumBrowser.browser(for: target)
        }
        .filter(\.supportsThemePolicy)
    }

    /// What the selected targets actually put on disk: a marker block, a
    /// managed preference, a generated copy or nothing at all.
    private var themingInstallSummary: String {
        let selected = config.theming.targets
            .compactMap(ThemingTarget.init(rawValue:))
            .filter(\.isImplemented)
        guard !selected.isEmpty else { return "Nothing selected: no app is changed." }
        let order: [ThemingTarget.InstallKind] = [.markerBlock, .policy, .generated, .manual]
        let parts = order.compactMap { kind -> String? in
            let names = selected.filter { $0.installKind == kind }.map(\.title)
            guard !names.isEmpty else { return nil }
            return "\(kind.rawValue): \(names.joined(separator: ", "))"
        }
        return "Installed: " + parts.joined(separator: " · ") + "."
    }

    private var canEnableSilentTheming: Bool {
        let installed = theming.installedBrowserIDs()
        return selectedBrowsers.contains {
            installed.contains($0.bundleID) && theming.policyStates[$0.bundleID] != true
        }
    }

    private var legacyProfileNames: String {
        ChromiumBrowser.catalog
            .filter { theming.legacyProfiles.contains($0.bundleID) }
            .map(\.name)
            .joined(separator: ", ")
    }

    private func browserPolicyStatus(_ browser: ChromiumBrowser) -> String {
        guard browser.supportsThemePolicy else {
            return "Unsupported — does not implement BrowserThemeColor."
        }
        if theming.policyStates[browser.bundleID] == true {
            return "Managed — updates silently"
        }
        guard theming.installedBrowserIDs().contains(browser.bundleID) else {
            return "Not installed"
        }
        return theming.legacyProfiles.contains(browser.bundleID)
            ? "Enable silent theming — removes the old profile"
            : "Enable silent theming"
    }

    private var otherAppsThemeBinding: Binding<String> {
        Binding(
            get: {
                ThemeLoader.themeID(for: config.theming.theme, themesDirectory: themesDirectory)
                    ?? config.theming.theme
            },
            set: { config.theming.theme = $0 }
        )
    }

    private var otherAppsThemeChoices: [ThemeInfo] {
        let themes = themeCatalogThemes
        let selected = otherAppsThemeBinding.wrappedValue
        guard !selected.isEmpty, !themes.contains(where: { $0.name == selected }) else {
            return themes
        }
        let missing = ThemeInfo(
            name: selected,
            displayName: selected,
            appearance: "dark",
            isBuiltin: false
        )
        return [missing] + themes
    }

    private var themeCatalogThemes: [ThemeInfo] {
        ThemeLoader.catalog(themesDirectory: themesDirectory).sorted {
            $0.shortDisplayName.localizedCaseInsensitiveCompare($1.shortDisplayName) == .orderedAscending
        }
    }

    private func themingTargetBinding(_ target: ThemingTarget) -> Binding<Bool> {
        Binding(
            get: { config.theming.targets.contains(target.rawValue) },
            set: { enabled in
                var targets = config.theming.targets
                if enabled {
                    if !targets.contains(target.rawValue) { targets.append(target.rawValue) }
                    policyWarning = nil
                } else {
                    targets.removeAll { $0 == target.rawValue }
                    if let browser = target.browser,
                       theming.policyStates[browser.bundleID] == true {
                        policyWarning = "\(browser.name) still has silent theming enabled. "
                            + "Unchecking does not remove it — use Remove… in the Browsers card."
                    }
                }
                config.theming.targets = targets
            }
        )
    }

    private func applyTheming() {
        policyWarning = nil
        let themingConfig = config.theming
        let fallback = themeManager.currentThemeID
        Task { @MainActor in
            _ = await theming.apply(themingConfig, fallbackThemeName: fallback)
        }
    }

    private func revertTheming() {
        Task { @MainActor in
            _ = await theming.revert()
            await theming.refreshPolicyStates()
            let installed = ChromiumBrowser.catalog.filter {
                theming.policyStates[$0.bundleID] == true
            }
            if !installed.isEmpty {
                policyWarning = "Revert restored the files, but \(installed.map(\.name).joined(separator: ", ")) "
                    + "still \(installed.count == 1 ? "has" : "have") silent theming enabled. "
                    + "Use Remove… in the Browsers card."
            }
        }
    }

    private func copyInclude(_ hint: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hint, forType: .string)
        copiedInclude = hint
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if copiedInclude == hint { copiedInclude = nil }
        }
    }

    /// AVFoundation cold start stays off the main thread; the pane shows
    /// "System default" for a beat instead of freezing.
    @MainActor
    private func loadRecordingDevices(force: Bool = false) async {
        if force || captureDisplays.isEmpty {
            captureDisplays = CaptureDisplays.active()
        }
        if force || microphones.isEmpty {
            microphones = await Task.detached(priority: .userInitiated, operation: {
                CaptureMicrophones.active()
            }).value
        }
    }

    /// CoreText's list is safe off-main; NSFontManager's was not.
    @MainActor
    private func loadFontFamilies() async {
        guard fontFamilies.isEmpty else { return }
        fontFamilies = await Task.detached(priority: .userInitiated, operation: {
            (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []).sorted()
        }).value
    }

    private var captureDisplayChoices: [PaletteMenuChoice<Int>] {
        var choices = captureDisplays.map { PaletteMenuChoice(value: $0.index, label: $0.label) }
        if !captureDisplays.contains(where: { $0.index == config.capture.recordingDisplay }) {
            choices.append(PaletteMenuChoice(
                value: config.capture.recordingDisplay,
                label: "Display \(config.capture.recordingDisplay) (missing)"
            ))
        }
        return choices
    }

    private var recordingMicrophoneChoices: [PaletteMenuChoice<String>] {
        var choices = [PaletteMenuChoice(value: "", label: "System default")]
        choices += microphones.map { PaletteMenuChoice(value: $0.id, label: $0.name) }
        if !config.capture.recordingMicrophone.isEmpty,
           !microphones.contains(where: { $0.id == config.capture.recordingMicrophone }) {
            choices.append(PaletteMenuChoice(
                value: config.capture.recordingMicrophone,
                label: "\(config.capture.recordingMicrophone) (missing)"
            ))
        }
        return choices
    }

    /// Installed fonts plus the configured family even when it is gone, so a
    /// stale value is shown as missing instead of silently reset to Inherit.
    private func fontChoices(_ selected: String, installed: [String]) -> [String] {
        let clean = selected.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !installed.contains(clean) else { return installed }
        return [clean] + installed
    }

    private func fontFamilyPicker(_ value: Binding<String>, inherited: String) -> some View {
        let installed = fontFamilies
        var choices = [PaletteMenuChoice(value: "", label: "Inherit — \(inherited)")]
        choices += fontChoices(value.wrappedValue, installed: installed).map { family in
            PaletteMenuChoice(
                value: family,
                label: installed.contains(family) ? family : "\(family) (missing)"
            )
        }
        return PaletteMenuPicker(selection: value, choices: choices, theme: theme)
            .frame(maxWidth: 380, alignment: .leading)
    }

    // MARK: - Shortcuts

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Global shortcuts", anchor: "shortcuts-global") {
                shortcutRow("Launcher shortcut", id: "launcher", value: $config.hotkey,
                            token: $launcherRecordToken, label: "Launcher hotkey", required: true)
                shortcutRow("Clipboard shortcut", id: "clipboard", value: $config.clipboardHotkey,
                            token: $clipboardRecordToken, label: "Clipboard hotkey", required: true)
                shortcutRow("Terminal shortcut", id: "terminal", value: $config.terminalHotkey,
                            token: $terminalRecordToken, label: "Terminal hotkey")
                shortcutRow("Theme cards shortcut", id: "theme-gallery", value: $config.themeGalleryHotkey,
                            token: $themeGalleryRecordToken, label: "Theme cards hotkey")
                shortcutRow("Wallpaper cards shortcut", id: "wallpaper-gallery",
                            value: $config.wallpaperGalleryHotkey,
                            token: $wallpaperGalleryRecordToken, label: "Wallpaper cards hotkey")
                shortcutRow("Scratchpad list", id: "scratchpad", value: $config.scratchpadHotkey,
                            token: $scratchpadRecordToken, label: "Scratchpad list hotkey")
                shortcutRow("Ask shortcut", id: "ask", value: $config.askHotkey,
                            token: $askRecordToken, label: "Ask hotkey")
            } footer: {
                Text("Click a field and press the keys you want. Press Delete to clear it, or click ✕. A cleared shortcut is disabled. The launcher and clipboard shortcuts are required.")
            }

            card("Screenshots and recording", anchor: "shortcuts-capture") {
                shortcutRow("Screen shortcut", id: "screen", value: $config.screenshotHotkey,
                            token: $screenshotRecordToken, label: "Screen hotkey")
                shortcutRow("Region shortcut", id: "region", value: $config.regionScreenshotHotkey,
                            token: $regionRecordToken, label: "Region hotkey")
                shortcutRow("Window shortcut", id: "window", value: $config.windowScreenshotHotkey,
                            token: $windowRecordToken, label: "Window hotkey")
                shortcutRow("Recording shortcut", id: "recording", value: $config.recordingHotkey,
                            token: $recordingRecordToken, label: "Recording hotkey")
            } footer: {
                Text("⌘⇧3 and ⌘⇧4 take over the macOS screenshot keys while they are set here. Clear one to give it back.")
            }

            card("Providers & actions", anchor: "shortcuts-catalog") {
                if commands.isEmpty {
                    Text("Reload the configuration to list the available providers and app commands.")
                        .font(.caption)
                        .foregroundStyle(muted)
                }
                ForEach(commandGroups, id: \.self) { group in
                    Text(group)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(muted)
                        .padding(.top, 4)
                    ForEach(commands.filter { $0.group == group }) { command in
                        catalogRow(command)
                    }
                }
            } footer: {
                Text("Every provider and app command can have its own global key; nothing is assigned by default. A key that macOS or another app already owns cannot be recorded: this check only runs when you record, since there is no public API to list other apps' shortcuts.")
            }

            card("Custom hotkeys", anchor: "shortcuts-bindings") {
                if config.bindings.isEmpty {
                    Text("Run an app, a shell command, a provider trigger, or a URL from a global key. Example: ctrl+alt+g → open Ghostty.")
                        .font(.caption)
                        .foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(bindingRowIDs.enumerated()), id: \.element) { index, id in
                    if index < config.bindings.count {
                        bindingRow(index, id: id)
                    }
                }
                Button("Add hotkey") {
                    config.bindings.append(HotkeyBinding(keys: ""))
                    bindingRowIDs.append(UUID())
                }
                .controlSize(.small)
            } footer: {
                Text("A binding never replaces the built-in shortcuts. An invalid, repeated, or already-taken key stays on screen with an error and is not written to config.toml.")
            }

            Text(shortcutSummary)
                .font(.caption)
                .foregroundStyle(hasShortcutConflict ? .red : .secondary)
        }
    }

    private func bindingRow(_ index: Int, id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ShortcutRecorder(
                    value: $config.bindings[index].keys,
                    label: "Custom hotkey",
                    validate: { candidate in
                        validateCandidate(candidate, id: id.uuidString, current: config.bindings[index].keys)
                    },
                    onValidation: { message in
                        recordValidation(id.uuidString, message: message)
                    }
                )
                .frame(width: 180, height: 26)
                PaletteMenuPicker(
                    selection: $config.bindings[index].action,
                    choices: HotkeyAction.allCases.map {
                        PaletteMenuChoice(value: $0, label: $0.title)
                    },
                    theme: theme
                )
                .frame(width: 130)
                TextField(
                    bindingPlaceholder(config.bindings[index].action),
                    text: bindingValue(index: index, id: id)
                )
                .settingsField()
                .focused($focusedBindingID, equals: id)
                .onSubmit { commitBindingValue(id) }
                Button {
                    guard config.bindings.indices.contains(index) else { return }
                    config.bindings.remove(at: index)
                    bindingRowIDs.removeAll { $0 == id }
                    bindingValueDrafts[id] = nil
                    shortcutErrors[id.uuidString] = nil
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(muted)
                .help("Delete hotkey")
                .accessibilityLabel("Delete custom hotkey")
            }
            if let issue = shortcutErrors[id.uuidString]
                ?? bindingIssue(keys: config.bindings[index].keys, index: index) {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let unavailable = HotKeyRegistry.unavailable(id: "binding-\(index)") {
                Text(unavailable)
                    .font(.caption)
                    .foregroundStyle(danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bindingValue(index: Int, id: UUID) -> Binding<String> {
        Binding(
            get: { bindingValueDrafts[id] ?? config.bindings[index].value },
            set: { bindingValueDrafts[id] = $0 }
        )
    }

    private func commitBindingValue(_ id: UUID) {
        guard let index = bindingRowIDs.firstIndex(of: id),
              let draft = bindingValueDrafts[id] else { return }
        config.bindings[index].value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        bindingValueDrafts[id] = nil
    }

    private func bindingPlaceholder(_ action: HotkeyAction) -> String {
        switch action {
        case .launch: return "App name, path, or URL"
        case .command: return "Shell command"
        case .provider: return "Provider trigger, e.g. calc"
        case .url: return "https://…"
        }
    }

    /// Nil when the row is usable (or still being filled in). Reports the same
    /// conditions the runtime drops with a log warning.
    private func bindingIssue(keys: String, index: Int) -> String? {
        let trimmed = keys.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let spec = HotKeySpec.parse(trimmed) else {
            return "Not a valid shortcut. Click the field and press the keys you want."
        }
        let reserved = hotkeyValues
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap { HotKeySpec.parse($0) }
        if reserved.contains(where: { $0.identity == spec.identity }) {
            return "This shortcut is already used by a built-in hotkey."
        }
        for (other, binding) in config.bindings.enumerated() where other != index {
            if HotKeySpec.parse(binding.keys)?.identity == spec.identity {
                return "This shortcut is used more than once. Each binding must be unique."
            }
        }
        for shortcut in config.shortcuts {
            if HotKeySpec.parse(shortcut.keys)?.identity == spec.identity {
                return "This shortcut is already used by a provider or app command."
            }
        }
        return nil
    }

    private var shortcutSummary: String {
        let entries = [
            ("Launcher", config.hotkey),
            ("Clipboard", config.clipboardHotkey),
            ("Terminal", config.terminalHotkey),
            ("Theme cards", config.themeGalleryHotkey),
            ("Wallpaper cards", config.wallpaperGalleryHotkey),
            ("Scratchpad list", config.scratchpadHotkey),
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
        let identities = hotkeyValues
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { HotKeySpec.parse($0)?.identity }
        return Set(identities).count != identities.count
    }

    // MARK: Catalogue shortcuts

    private var commandGroups: [String] {
        var groups: [String] = []
        for command in commands where !groups.contains(command.group) {
            groups.append(command.group)
        }
        return groups
    }

    private func shortcutBinding(for command: String) -> Binding<String> {
        Binding(
            get: { config.shortcuts.first(where: { $0.command == command })?.keys ?? "" },
            set: { keys in
                if let index = config.shortcuts.firstIndex(where: { $0.command == command }) {
                    config.shortcuts[index].keys = keys
                } else {
                    config.shortcuts.append(ShortcutBinding(command: command, keys: keys))
                }
            }
        )
    }

    private func shortcutState(_ command: String) -> String {
        let keys = config.shortcuts.first(where: { $0.command == command })?.keys ?? ""
        guard !keys.isEmpty else { return "Not set" }
        return HotKeySpec.parse(keys)?.prettyDisplay ?? keys
    }

    /// Every key Palette itself owns right now, by stable row id. Web-app keys
    /// are not in this list; the probe's live set catches those.
    private var ownShortcutKeys: [(id: String, keys: String)] {
        [
            ("launcher", config.hotkey), ("clipboard", config.clipboardHotkey),
            ("terminal", config.terminalHotkey), ("theme-gallery", config.themeGalleryHotkey),
            ("wallpaper-gallery", config.wallpaperGalleryHotkey),
            ("scratchpad", config.scratchpadHotkey), ("ask", config.askHotkey),
            ("screen", config.screenshotHotkey),
            ("region", config.regionScreenshotHotkey), ("window", config.windowScreenshotHotkey),
            ("recording", config.recordingHotkey),
        ] + config.shortcuts.map { ($0.command, $0.keys) }
            + zip(bindingRowIDs, config.bindings).map { (id: $0.uuidString, keys: $1.keys) }
    }

    private func paletteConflict(_ candidate: HotKeySpec, excluding id: String) -> Bool {
        ownShortcutKeys.contains { entry in
            guard entry.id != id, let spec = HotKeySpec.parse(entry.keys) else { return false }
            return spec.identity == candidate.identity
        }
    }

    /// Recorder gate: our own keys first, then a throwaway Carbon registration
    /// to learn whether macOS or another app already owns the pair.
    private func validateCandidate(_ display: String, id: String, current: String) -> String? {
        guard let spec = HotKeySpec.parse(display) else {
            return "Not a valid shortcut."
        }
        // Recording the key a row already has is a no-op, not a conflict.
        if let currentSpec = HotKeySpec.parse(current), currentSpec.identity == spec.identity {
            return nil
        }
        return ShortcutAvailability.message(
            for: spec,
            ownedKeys: ownShortcutKeys.filter { $0.id != id }.map(\.keys)
        )
    }

    private func recordValidation(_ id: String, message: String?) {
        if let message {
            shortcutErrors[id] = message
        } else {
            shortcutErrors[id] = nil
        }
    }

    private func catalogIssue(_ command: CatalogCommand) -> String? {
        if let error = shortcutErrors[command.id] { return error }
        let keys = config.shortcuts.first(where: { $0.command == command.id })?.keys ?? ""
        guard !keys.isEmpty else { return nil }
        guard let spec = HotKeySpec.parse(keys) else {
            return "Not a valid shortcut. Click the field and press the keys you want."
        }
        if paletteConflict(spec, excluding: command.id) {
            return "This shortcut is used more than once."
        }
        return nil
    }

    private func catalogRow(_ command: CatalogCommand) -> some View {
        let value = shortcutBinding(for: command.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(command.title)
                    .font(theme.font(size: 13))
                    .lineLimit(1)
                    .frame(width: 180, alignment: .leading)
                Text(shortcutState(command.id))
                    .font(.caption)
                    .foregroundStyle(muted)
                    .lineLimit(1)
                    .frame(width: 90, alignment: .leading)
                ShortcutRecorder(
                    value: value,
                    label: command.title,
                    validate: { candidate in
                        validateCandidate(candidate, id: command.id, current: value.wrappedValue)
                    },
                    onValidation: { message in
                        recordValidation(command.id, message: message)
                    }
                )
                .frame(width: 180, height: 26)
                if !value.wrappedValue.isEmpty {
                    Button {
                        value.wrappedValue = ""
                        recordValidation(command.id, message: nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(muted)
                    .help("Clear \(command.title)")
                    .accessibilityLabel("Clear \(command.title)")
                }
                Spacer(minLength: 0)
            }
            if let issue = catalogIssue(command) {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let unavailable = HotKeyRegistry.unavailable(id: command.id) {
                Text(unavailable)
                    .font(.caption)
                    .foregroundStyle(danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shortcutRow(
        _ title: String,
        id: String,
        value: Binding<String>,
        token: Binding<Int>,
        label: String,
        required: Bool = false,
        anchor: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(theme.font(size: 13))
            HStack(spacing: 8) {
                ShortcutRecorder(
                    value: value,
                    label: label,
                    recordToken: token.wrappedValue,
                    validate: { candidate in
                        validateCandidate(candidate, id: id, current: value.wrappedValue)
                    },
                    onValidation: { message in
                        recordValidation(id, message: message)
                    }
                )
                .frame(width: 210, height: 26)
                if !value.wrappedValue.isEmpty {
                    Button {
                        value.wrappedValue = ""
                        recordValidation(id, message: nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(muted)
                    .help("Clear \(label)")
                    .accessibilityLabel("Clear \(label)")
                }
                Button("Record") { token.wrappedValue += 1 }
                    .controlSize(.small)
                    .accessibilityLabel("Record \(label)")
                Spacer(minLength: 0)
            }
            if let issue = shortcutErrors[id] ?? hotkeyIssue(value.wrappedValue, required: required, among: "") {
                Text(issue).font(.caption).foregroundStyle(danger)
            }
            if let unavailable = HotKeyRegistry.unavailable(id: id) {
                Text(unavailable)
                    .font(.caption)
                    .foregroundStyle(danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .searchTarget(anchor ?? "row-\(title)")
    }

    // MARK: - Search

    private var search: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Web search", anchor: "search-web") {
                toggleRow("Show web results in search", isOn: $config.webSearchEnabled)
            } footer: {
                Text("When a query does not match an app or file, Palette offers a browser search.")
            }

            card("Search engines", anchor: "search-engines") {
                engineHeader
                ForEach(engines.indices, id: \.self) { index in
                    engineRow($engines[index], index: index)
                }
                HStack(spacing: 8) {
                    Button("Add engine") {
                        engines.append(WebSearchEngine(
                            name: "New engine",
                            urlTemplate: "https://example.com/?q={query}"
                        ))
                    }
                    Button("Restore defaults") {
                        engines = WebSearchEngine.restoringDefaults(into: engines)
                        config.webSearchEngines = engines
                    }
                }
            } footer: {
                Text("Type !keyword in the launcher, for example !yt lo-fi. The search URL must contain {query}, which Palette replaces with the URL-encoded text. An invalid engine is flagged here and the last valid one stays in config.toml. “Web app” opens the result in a dedicated Palette web-app window for that site (its own browser profile), not in a PWA installed inside Helium/Chrome — those live in the browser's own profile and cannot be handed a search URL.")
            }

            card("Learning", anchor: "search-learning") {
                toggleRow(
                    "Learn from my choices",
                    isOn: $config.learningEnabled,
                    help: "Remember which row you pick after a short plain query and rank it first next time. Only a digest of the query is stored."
                )
                HStack(spacing: 8) {
                    Button("Forget learned ranking") {
                        forgetLearnedPending = true
                    }
                    if let forgetLearnedMessage {
                        Text(forgetLearnedMessage)
                            .font(.caption)
                            .foregroundStyle(muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } footer: {
                Text("A learned row only breaks ties: it never outranks a better text match. Bound /trigger searches are never learned from.")
            }
        }
    }

    private func forgetLearned() {
        forgetLearnedMessage = nil
        Task { @MainActor in
            if let error = await onForgetLearned() {
                forgetLearnedMessage = "Could not clear learned ranking: \(error)"
            } else {
                forgetLearnedMessage = "Learned ranking cleared."
            }
        }
    }

    // MARK: - Bookmarks

    private var bookmarksPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Bookmarks", anchor: "bookmarks-list") {
                if let bookmarksError {
                    Text("\(bookmarksError) The file is left untouched; fix or restore bookmarks.toml, then reopen Settings.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach($bookmarks) { $bookmark in
                        VStack(alignment: .leading, spacing: 8) {
                            fieldRow("Name", anchor: "row-bookmark-\(bookmark.id)-name") {
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
                            }
                            fieldRow("URL", anchor: "row-bookmark-\(bookmark.id)-url") {
                                TextField("URL", text: $bookmark.url)
                                    .settingsField()
                            }
                            fieldRow("Browser", anchor: "row-bookmark-\(bookmark.id)-browser") {
                                BrowserPicker(browser: $bookmark.browser, theme: theme)
                            }
                            fieldRow("Keywords", anchor: "row-bookmark-\(bookmark.id)-keywords") {
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
                        }
                        .padding(.vertical, 4)
                    }
                }
                HStack(spacing: 8) {
                    if bookmarksError == nil {
                        Button("Add bookmark") {
                            bookmarks.append(Bookmark(name: "", url: "", browser: ""))
                        }
                    }
                    Button("Reveal in Finder") {
                        reveal(PalettePaths.resolve().bookmarksFile.path)
                    }
                    .help("Show bookmarks.toml in Finder")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let bookmarksSaveError {
                        Text("Could not save bookmarks.toml: \(bookmarksSaveError)")
                            .foregroundStyle(danger)
                    }
                    Text("Bookmarks open in a normal browser window, in the browser you pick. They live in bookmarks.toml; Reveal in Finder shows that file.")
                }
            }
        }
    }

    // MARK: - Cheatsheets

    private var cheatsheetsPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Cheatsheets", anchor: "cheatsheets-folders") {
                if cheatsheetFolders.isEmpty {
                    Text("Choose a folder of PDFs, notes, or images to browse with /cheat. Folders are scanned one level deep.")
                        .font(.caption)
                        .foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Choose folder…") { addCheatsheetFolder() }
                    }
                } else {
                    ForEach(cheatsheetFolders.indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            TextField("Folder", text: $cheatsheetFolders[index])
                                .settingsField()
                            Button("Choose…") {
                                chooseDirectory(into: $cheatsheetFolders[index])
                            }
                            Button {
                                reveal(cheatsheetFolders[index])
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .disabled(cheatsheetFolders[index].trimmingCharacters(in: .whitespaces).isEmpty)
                            .help("Reveal folder in Finder")
                            .accessibilityLabel("Reveal folder in Finder")
                            Button {
                                cheatsheetFolders.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove folder")
                            .accessibilityLabel("Remove folder")
                        }
                    }
                    Button("Add folder") {
                        cheatsheetFolders.append("")
                    }
                }
                fieldRow("Extensions") {
                    TextField("Extensions", text: $cheatsheetExtensions, prompt: Text("pdf, html, md, txt, png"))
                        .settingsField()
                }
            } footer: {
                Text("PDF, HTML, Markdown, text, and images preview in the launcher; press ⌥P to enlarge. Folders are scanned one level deep and ~ works in paths. Extensions are comma-separated, without the dot.")
            }
        }
    }

    // MARK: - Web Apps

    private var webAppsPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Web Apps", anchor: "webapps-browser") {
                fieldRow("Open web apps in", error: webAppBrowserIssue) {
                    PaletteMenuPicker(
                        selection: webAppBrowserBinding,
                        choices: webAppBrowserChoices.isEmpty
                            ? [PaletteMenuChoice(value: "", label: "No Chromium browser found")]
                            : webAppBrowserChoices.map { name in
                                PaletteMenuChoice(
                                    value: name,
                                    label: installedChromium.contains(name)
                                        ? name
                                        : "\(name) (not installed)"
                                )
                            },
                        theme: theme
                    )
                    .frame(maxWidth: 280, alignment: .leading)
                }
            } footer: {
                Text("Chromium-based browsers only. The list shows the ones installed on this Mac.")
            }
        }
    }

    // MARK: - Screenshots

    private var screenshotsPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Screenshots", anchor: "screenshots-destination") {
                fieldRow("Save to") {
                    HStack(spacing: 8) {
                        TextField("Save to", text: $config.capture.directory)
                            .settingsField()
                        Button("Choose…") {
                            chooseDirectory(into: $config.capture.directory)
                        }
                        Button {
                            reveal(config.capture.directory)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal folder in Finder")
                        .accessibilityLabel("Reveal capture folder in Finder")
                    }
                }
                pickerRow("Action", anchor: "row-screenshot-action") {
                    PaletteMenuPicker(
                        selection: $config.capture.screenshotAction,
                        choices: [
                            PaletteMenuChoice(value: .save, label: "Save"),
                            PaletteMenuChoice(value: .copy, label: "Copy"),
                            PaletteMenuChoice(value: .saveCopy, label: "Save and copy"),
                            PaletteMenuChoice(value: .preview, label: "Save and preview"),
                        ],
                        theme: theme
                    )
                    .frame(maxWidth: 280, alignment: .leading)
                }
                pickerRow("Format", anchor: "row-screenshot-format") {
                    PaletteMenuPicker(
                        selection: $config.capture.screenshotFormat,
                        choices: [
                            PaletteMenuChoice(value: "png", label: "PNG"),
                            PaletteMenuChoice(value: "jpg", label: "JPG"),
                        ],
                        theme: theme
                    )
                    .frame(maxWidth: 160, alignment: .leading)
                }
                numericRow("Delay before capture", value: $config.capture.delay,
                           in: 0...10, step: 1, unit: "s")
            } footer: {
                Text("Use /shot or the screen, region, and window shortcuts. Save to supports ~ and is created on the first capture.")
            }
        }
    }

    // MARK: - Recordings

    private var recordingsPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Recordings", anchor: "recordings-action") {
                pickerRow("Action", anchor: "row-recording-action") {
                    PaletteMenuPicker(
                        selection: $config.capture.recordingAction,
                        choices: [
                            PaletteMenuChoice(value: .save, label: "Save"),
                            PaletteMenuChoice(value: .saveCopy, label: "Save and copy"),
                        ],
                        theme: theme
                    )
                    .frame(maxWidth: 280, alignment: .leading)
                }
                pickerRow("What to record") {
                    PaletteMenuPicker(
                        selection: $config.capture.recordingTarget,
                        choices: [
                            PaletteMenuChoice(value: "screen", label: "Whole screen"),
                            PaletteMenuChoice(value: "display", label: "A display"),
                            PaletteMenuChoice(value: "region", label: "A region"),
                        ],
                        theme: theme
                    )
                    .frame(maxWidth: 280, alignment: .leading)
                }
                if config.capture.recordingTarget == "display" {
                    pickerRow("Display") {
                        PaletteMenuPicker(
                            selection: $config.capture.recordingDisplay,
                            choices: captureDisplayChoices,
                            theme: theme
                        )
                        .frame(maxWidth: 280, alignment: .leading)
                    }
                }
                if config.capture.recordingTarget == "region" {
                    fieldRow("Region (x,y,w,h)") {
                        TextField("Region (x,y,w,h)", text: $config.capture.recordingRegion)
                            .settingsField()
                    }
                }
                pickerRow("Format", anchor: "row-recording-format") {
                    PaletteMenuPicker(
                        selection: $config.capture.recordingFormat,
                        choices: [
                            PaletteMenuChoice(value: "mov", label: "MOV"),
                            PaletteMenuChoice(value: "mp4", label: "MP4"),
                        ],
                        theme: theme
                    )
                    .frame(maxWidth: 160, alignment: .leading)
                }
                toggleRow("Record audio", isOn: $config.capture.recordingAudio)
                pickerRow("Microphone") {
                    PaletteMenuPicker(
                        selection: $config.capture.recordingMicrophone,
                        choices: recordingMicrophoneChoices,
                        theme: theme
                    )
                    .frame(maxWidth: 280, alignment: .leading)
                    .disabled(!config.capture.recordingAudio)
                }
            } footer: {
                Text("Use /rec to start or stop a recording. Recordings are saved with the system capture engine.")
            }
        }
        .task { await loadRecordingDevices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            Task { await loadRecordingDevices(force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            Task { await loadRecordingDevices(force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            Task { await loadRecordingDevices(force: true) }
        }
    }

    // MARK: - After a capture

    private var afterCapturePane: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("After a capture", anchor: "search-after-capture") {
                toggleRow("Hide Palette before capturing", isOn: $config.capture.hidePalette)
                toggleRow("Include the cursor", isOn: $config.capture.captureCursor)
                toggleRow("Show clicks while recording", isOn: $config.capture.showClicks)
                toggleRow("Shutter sound after a screenshot", isOn: $config.capture.captureSound)
                toggleRow("Show a thumbnail after a screenshot", isOn: $config.capture.captureThumbnail)
                toggleRow("Open the annotator after a screenshot", isOn: $config.capture.editAfterCapture)
                toggleRow("Preview recordings when they stop", isOn: $config.capture.previewRecording)
            }
        }
    }

    // MARK: - Captures

    private var capturesPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Captures list", anchor: "search-captures") {
                pickerRow("List") {
                    PaletteMenuPicker(
                        selection: $config.capture.gallery,
                        choices: [
                            PaletteMenuChoice(value: "all", label: "Everything in the folder"),
                            PaletteMenuChoice(value: "palette", label: "Only Palette's captures"),
                        ],
                        theme: theme
                    )
                    .frame(maxWidth: 280, alignment: .leading)
                }
            } footer: {
                Text("Controls what /shots shows: every image and video in the folder, or only Palette's own shot-* and rec-* files.")
            }
        }
    }

    private var engineHeader: some View {
        HStack(spacing: 8) {
            Text("Name").frame(width: 120, alignment: .leading)
            Text("Bang").frame(width: 64, alignment: .leading)
            Text("Search URL").frame(maxWidth: .infinity, alignment: .leading)
            Text("Browser").frame(width: 92, alignment: .leading)
            Text("").frame(width: 20)
        }
        .font(.caption)
        .foregroundStyle(muted)
    }

    private func engineRow(_ engine: Binding<WebSearchEngine>, index: Int) -> some View {
        let keyword = Binding(
            get: { engine.wrappedValue.keyword ?? "" },
            set: { engine.wrappedValue.keyword = $0.isEmpty ? nil : $0 }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                TextField("Name", text: engine.name)
                    .labelsHidden()
                    .settingsField()
                    .frame(width: 120)
                HStack(spacing: 4) {
                    Text("!").foregroundStyle(muted)
                    TextField("Bang", text: keyword)
                        .labelsHidden()
                        .settingsField()
                }
                .frame(width: 64)
                TextField("Search URL", text: engine.urlTemplate)
                    .labelsHidden()
                    .settingsField()
                    .font(.system(.body, design: .monospaced))
                    .help(engine.wrappedValue.urlTemplate)
                engineBrowserButton(engine)
                    .frame(width: 92, alignment: .leading)
                Button {
                    guard engines.indices.contains(index) else { return }
                    engines.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .frame(width: 20)
                .help("Remove engine")
                .accessibilityLabel("Remove \(engine.wrappedValue.name)")
            }
            if let issue = engineIssue(engine.wrappedValue) {
                Text(issue).font(.caption).foregroundStyle(danger)
            }
        }
        .padding(.vertical, 4)
    }

    private func engineBrowserButton(_ engine: Binding<WebSearchEngine>) -> some View {
        let items = EngineBrowserMenu.items(
            browser: engine.wrappedValue.browser,
            browsers: BrowserCatalog.activeBrowsers(),
            appMode: engine.wrappedValue.appMode
        )
        return PaletteMenuButton(
            title: engine.wrappedValue.appMode
                ? "Web app · \(engine.wrappedValue.browser.isEmpty ? "default" : engine.wrappedValue.browser)"
                : (engine.wrappedValue.browser.isEmpty ? "Default" : engine.wrappedValue.browser),
            items: items,
            theme: theme
        ) { id in
            if id.hasPrefix("browser:") {
                engine.wrappedValue.browser = String(id.dropFirst("browser:".count))
                return
            }
            switch id {
            case "default-browser":
                engine.wrappedValue.browser = ""
            case "app-mode":
                setEngineAppMode(engine.wrappedValue, true)
            case "tab-mode":
                setEngineAppMode(engine.wrappedValue, false)
            default:
                break
            }
        }
    }

    /// Mutates by identity so a menu dismissal cannot leave a stale index
    /// binding pointing at a different engine.
    private func setEngineAppMode(_ engine: WebSearchEngine, _ value: Bool) {
        guard let index = config.webSearchEngines.firstIndex(where: { $0.id == engine.id }) else { return }
        config.webSearchEngines[index].appMode = value
    }

    private var webAppBrowserBinding: Binding<String> {
        Binding(
            get: {
                if config.webAppBrowser.isEmpty {
                    return installedChromium.first ?? ""
                }
                return config.webAppBrowser
            },
            set: { config.webAppBrowser = $0 }
        )
    }

    // MARK: - Ask

    private var ask: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Model", anchor: "ask-model") {
                pickerRow("Provider") {
                    PaletteMenuPicker(
                        selection: $config.ask.endpoint,
                        choices: AskEndpoint.allCases.map {
                            PaletteMenuChoice(value: $0, label: $0.displayName)
                        },
                        theme: theme
                    )
                    .frame(maxWidth: 280, alignment: .leading)
                }
                pickerRow("Model") {
                    PaletteMenuPicker(
                        selection: $config.ask.model,
                        choices: AskModel.models(for: config.ask.endpoint).map { model in
                            PaletteMenuChoice(
                                value: model.id,
                                label: model.free
                                    ? "FREE · \(model.name)"
                                    : "\(model.name) · \(model.note)"
                            )
                        },
                        theme: theme
                    )
                    .frame(maxWidth: 360, alignment: .leading)
                }
                numericRow("Max answer tokens", value: $config.ask.maxTokens,
                           in: 32...8_192, step: 32)
                toggleRow("Fall back to free or small models when quota runs out", isOn: $config.ask.fallback)
                toggleRow("Notify when an answer arrives (sound, banner, Dock badge)", isOn: $config.ask.notify)
                Text("Banners need Palette allowed in System Settings → Notifications. Sound and the Dock badge work either way.")
                    .font(.caption)
                    .foregroundStyle(muted)
                toggleRow("Search the web once per turn (DuckDuckGo)", isOn: $config.ask.webSearch)
            } footer: {
                Text("Free models are listed first. If a free model is rate-limited, Ask tries the next free option, then the cheapest paid model from an endpoint where you have a key.")
            }

            card("API key") {

                if askKeyStored {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Key saved locally (encrypted, user-only)")
                        Spacer()
                        Button("Clear key", role: .destructive) {
                            clearKeyPending = true
                        }
                    }
                    Text("The saved value is never shown in Palette or written to config.toml.")
                        .font(.caption)
                        .foregroundStyle(muted)
                } else {
                    fieldRow("Paste \(config.ask.endpoint.displayName) API key") {
                        SecureField("Paste \(config.ask.endpoint.displayName) API key", text: $askKeyInput)
                            .settingsField()
                    }
                    HStack(spacing: 8) {
                        Button("Save key") { saveAskKey() }
                        if let keyPage = askKeyPage {
                            Link("Get a key", destination: keyPage)
                        }
                        Spacer()
                    }
                    Text("The key is saved immediately in an encrypted user-only file. After saving, Palette only shows that a key exists.")
                        .font(.caption)
                        .foregroundStyle(muted)
                }
                if let askKeyMessage {
                    Text(askKeyMessage).font(.caption).foregroundStyle(muted)
                }
            } footer: {
                Text("Keys can also come from OPENCODE_GO_API_KEY or NVIDIA_API_KEY for a shell-launched build. The app never logs a key.")
                    .font(.caption)
                    .foregroundStyle(muted)
            }

            card("History") {
                numericRow("Keep questions and answers", value: $config.ask.maxHistory,
                           in: 10...20_000, step: 10)
                numericRow("Delete answers older than", value: $config.ask.retentionDays,
                           in: 1...3_650, step: 1, unit: "days")
            } footer: {
                Text("Older question and answer rows are trimmed automatically. Saved chats keep their full transcript.")
                    .font(.caption)
                    .foregroundStyle(muted)
            }
        }
    }

    /// The provider's site root, derived from the endpoint it talks to.
    private var askKeyPage: URL? {
        guard let host = config.ask.endpoint.baseURL.host else { return nil }
        return URL(string: "https://\(host)")
    }

    private func saveAskKey() {
        let trimmed = askKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            askKeyMessage = "Paste a key first."
            return
        }
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

    // MARK: - Providers

    /// One row per provider: tab, name, plain-query membership, trigger, aliases,
    /// and order live in the same table so a provider is configured in one place.
    private var providerSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !pendingToolRows.isEmpty {
                missingToolsCard
            }
            card("Providers", anchor: "providers-default") {
                providerFilterField
                providerHeader
                Text("A check under Plain queries includes this provider in plain, unprefixed searches. Providers without a check answer only through their trigger or alias. Always-on rows stay at the top because the registry always loads them.")
                    .font(.caption)
                    .foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
                Divider()
                ForEach(Array(tableProviderIDs.enumerated()), id: \.element) { index, id in
                    providerRow(id)
                    if index < tableProviderIDs.count - 1 {
                        Divider()
                    }
                }
                if tableProviderIDs.isEmpty {
                    Text("No providers match “\(providerFilter)”.")
                        .font(.caption)
                        .foregroundStyle(muted)
                }
            } footer: {
                Text("Tab removes the provider from the registry, so its trigger and aliases stop working. Apps always answer a plain query. A checked alias is active and saved to config.toml; unchecking keeps the row so the word can be restored. Triggers come from provider.toml and cannot be renamed here. The arrows change the tab order.")
            }
            fileIndexingCard
        }
    }

    // MARK: - Provider Files

    private var providerFilesPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Provider Files", anchor: "providers-files") {
                HStack(spacing: 8) {
                    Button("Open providers folder") { onOpen(PalettePaths.resolve().providersDir) }
                    Button("Open commands.toml") {
                        onOpen(PalettePaths.resolve().configDir.appendingPathComponent("commands.toml"))
                    }
                }
                Text("Add your own provider by creating a folder under providers/ with a provider.toml. User providers override bundled ones with the same id. Press ⌘R after editing files.")
                    .font(.caption)
                    .foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            } footer: {
                Text("These are the files Palette reads at launch. Settings never edits them.")
            }
        }
    }

    // MARK: - Config Files

    private var configFilesPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Config Files", anchor: "config-files") {
                HStack(spacing: 8) {
                    Button("Open config.toml") { onOpen(configURL) }
                    Button("Reveal in Finder") { reveal(configURL.path) }
                    Button("Open config.toml.bak") { onOpen(configURL.appendingPathExtension("bak")) }
                }
                HStack(spacing: 8) {
                    Button("Open log") { onOpen(PalettePaths.resolve().logFile) }
                    Button("Open crash log") {
                        onOpen(PalettePaths.resolve().stateDir.appendingPathComponent("crash.log"))
                    }
                }
                Button("Export backup…") { onExportBackup() }
            } footer: {
                Text("Settings writes config.toml for you. Edit it directly only for options that are not in this window, then press ⌘R. Backups include config, themes, providers, history and encrypted Ask keys: plain-text clipboard entries are removed, image and file entries stay.")
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Diagnostics", anchor: "diagnostics-lines") {
                if diagnostics.isEmpty {
                    Text("No startup diagnostics.").font(.caption).foregroundStyle(muted)
                } else {
                    ForEach(diagnostics, id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } footer: {
                Text("Lines reported while the last configuration was loaded.")
            }
        }
    }

    /// Providers that are on but cannot run until a tool is installed. The
    /// answer is written to `[providers] missing_tool_acknowledged`, so this
    /// card disappears for good once it is answered.
    private var fileIndexingCard: some View {
        card("File indexing", anchor: "providers-indexing") {
            Toggle("Index my home folder for file providers", isOn: Binding(
                get: { config.indexingHomeConsent ?? false },
                set: { config.indexingHomeConsent = $0 }
            ))
            Text("The home walk runs at launch and is cached. macOS may ask for folder access the first time; Desktop, Documents, Downloads, Library and the other system folders are skipped either way.")
                .font(.caption)
                .foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pendingToolRows: [(provider: ProviderSettingsInfo, missing: [ProviderRequirement])] {
        let acknowledged = Set(config.missingToolAcknowledged)
        return providers.compactMap { provider in
            guard !disabledProviders.contains(provider.id), !acknowledged.contains(provider.id) else { return nil }
            let missing = ProviderRequirements.missing(provider.requirements)
            return missing.isEmpty ? nil : (provider, missing)
        }
    }

    private var missingToolsCard: some View {
        card("Missing tools", anchor: "providers-missing-tools") {
            ForEach(pendingToolRows, id: \.provider.id) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(row.provider.name) needs \(row.missing.map(\.tool).joined(separator: ", "))")
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(row.missing.map(\.why).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(row.missing, id: \.tool) { requirement in
                        HStack(spacing: 8) {
                            Text(requirement.install)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Copy") { copyToPasteboard(requirement.install) }
                                .controlSize(.small)
                            if let docs = requirement.docs, let url = URL(string: docs) {
                                Link("Docs", destination: url).font(.caption)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Button("Keep enabled") { acknowledgeTool(row.provider.id) }
                            .controlSize(.small)
                        Button("Disable \(row.provider.name)") {
                            if !disabledProviders.contains(row.provider.id) {
                                disabledProviders.append(row.provider.id)
                            }
                            acknowledgeTool(row.provider.id)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
        } footer: {
            Text("Palette asks once. Answering here is stored in config.toml and is not asked again; the launcher never prompts from inside a search.")
        }
    }

    private func acknowledgeTool(_ id: String) {
        guard !config.missingToolAcknowledged.contains(id) else { return }
        config.missingToolAcknowledged.append(id)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var providerFilterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(muted)
            TextField("Filter providers", text: $providerFilter)
                .textFieldStyle(.plain)
            if !providerFilter.isEmpty {
                Button {
                    providerFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(muted)
                .accessibilityLabel("Clear provider filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.color(theme.palette.elevated).opacity(0.5))
        )
    }

    /// Always-on providers are shown first so the table reads like the
    /// registry instead of one priority ordering.
    private let pinnedProviderIDs = ["apps", "pins", "search"]

    private var tableProviderIDs: [String] {
        let query = providerFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = allProviderIDs.filter { id in
            guard !query.isEmpty else { return true }
            return providerName(id).localizedCaseInsensitiveContains(query)
                || id.localizedCaseInsensitiveContains(query)
                || (providerTrigger(id)?.localizedCaseInsensitiveContains(query) ?? false)
                || (providerGroup(id)?.localizedCaseInsensitiveContains(query) ?? false)
        }
        let pinned = pinnedProviderIDs.filter { id in
            providers.contains { $0.id == id }
        }
        return pinned + matches.filter { !pinned.contains($0) }
    }

    private var providerHeader: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Text("Tab")
                .frame(width: providerTabWidth, alignment: .leading)
            Text("Provider")
                .frame(width: providerNameWidth, alignment: .leading)
            Text("Plain queries")
                .frame(width: providerPlainWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("Trigger")
                .frame(width: providerTriggerWidth, alignment: .leading)
            Text("Aliases")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Order")
                .frame(width: providerOrderWidth, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(muted)
    }

    private func providerName(_ id: String) -> String {
        providers.first(where: { $0.id == id })?.name ?? id
    }

    private func providerGroup(_ id: String) -> String? {
        providers.first(where: { $0.id == id })?.group?.name
    }

    private func providerTrigger(_ id: String) -> String? {
        providers.first(where: { $0.id == id })?.trigger
    }

    private func requirements(for id: String) -> [ProviderRequirement] {
        providers.first(where: { $0.id == id })?.requirements ?? []
    }

    /// Plain queries follow the allowlist saved to `[providers] global`. Apps is
    /// always searched, so its box is checked and read-only.
    private func providerDefaultBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { id == "apps" || globalProviders.contains(id.lowercased()) },
            set: { enabled in
                guard id != "apps" else { return }
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
            get: { id == "apps" || !disabledProviders.contains(id) },
            set: { enabled in
                guard id != "apps" else { return }
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
        let pinned = pinnedProviderIDs.contains(id)
        return HStack(alignment: .top, spacing: 8) {
            Toggle("Tab \(providerName(id))", isOn: providerEnabledBinding(id))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: providerTabWidth, alignment: .leading)
                .allowsHitTesting(id != "apps")
                .help("Include \(providerName(id)) in the registry and show its tab")

            VStack(alignment: .leading, spacing: 1) {
                if let group = providerGroup(id) {
                    Text(group)
                        .font(.system(size: 9))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                        .padding(.leading, 10)
                }
                Text(providerName(id))
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .padding(.leading, providerGroup(id) == nil ? 0 : 10)
                if let missing = ProviderRequirements.missing(requirements(for: id)).first {
                    Text("needs \(missing.tool)")
                        .font(.caption2)
                        .foregroundStyle(muted)
                        .help(missing.install)
                }
            }
            .frame(width: providerNameWidth, alignment: .leading)

            Toggle("Plain queries for \(providerName(id))", isOn: providerDefaultBinding(id))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: providerPlainWidth, alignment: .leading)
                .allowsHitTesting(id != "apps")
                .help("Include \(providerName(id)) in plain, unprefixed queries.")

            providerTriggerChip(id)
                .frame(width: providerTriggerWidth, alignment: .leading)

            Button {
                aliasPopover = id
            } label: {
                Text(aliasCountLabel(id))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(linkColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .popover(isPresented: Binding(
                get: { aliasPopover == id },
                set: { if !$0 { aliasPopover = nil } }
            )) {
                aliasEditor(id)
                    .padding(14)
                    .frame(width: 300)
            }
            .help("Edit aliases for \(providerName(id))")

            if pinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(muted)
                    .frame(width: providerOrderWidth)
                    .help("Always-on providers stay at the top")
            } else {
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
        }
        .padding(.vertical, 6)
    }

    private func aliasCountLabel(_ id: String) -> String {
        let active = (providerAliasesDraft[id] ?? []).filter(\.enabled).count
        let total = (providerAliasesDraft[id] ?? []).count
        if total == 0 { return "Add aliases" }
        if active == total { return "\(active) \(active == 1 ? "alias" : "aliases")" }
        return "\(active) of \(total) aliases"
    }

    @ViewBuilder
    private func providerTriggerChip(_ id: String) -> some View {
        if let trigger = providerTrigger(id) {
            Text(trigger)
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
            Text("none")
                .font(.caption)
                .foregroundStyle(muted)
                .help("This provider has no trigger; it can only appear in a plain query.")
        }
    }

    @ViewBuilder
    private func aliasEditor(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(providerName(id)) aliases")
                .font(.headline)
            ForEach(aliasEntries(id)) { $entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
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
            HStack(spacing: 8) {
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

    // MARK: - Reset

    private var resetSummary: String {
        switch selectedTab {
        case .general:
            return "Restores the editor, terminal, terminal app, notification, update-check, clipboard-history, and command-prefix defaults. Startup, permissions, and power are left alone."
        case .launcher:
            return "Restores launcher position, search-field behaviour, and layout defaults."
        case .appearance:
            return "Restores typography and font defaults. Palette's theme lives in Theming."
        case .shortcuts:
            return "Restores every global shortcut to its default. Custom hotkeys are left alone."
        case .search:
            return "Restores web search, the search engine list, and the learning toggle. Learned ranking stays until you press Forget."
        case .ask:
            return "Restores the Ask endpoint, model, tokens, fallback, notifications, and history limits. Saved API keys are left alone."
        case .terminal:
            return "Restores the embedded terminal session, shell, and font defaults."
        case .bookmarks:
            return "Removes every bookmark. bookmarks.toml is rewritten with an empty list."
        case .cheatsheets:
            return "Restores the default cheatsheet folders (none) and file extensions."
        case .webApps:
            return "Restores the default web-app browser."
        case .screenshots:
            return "Restores the screenshot folder, action, format, and delay."
        case .afterCapture:
            return "Restores the toggles that decide what happens after a capture."
        case .recordings:
            return "Restores the recording action, target, display, region, format, and audio defaults."
        case .captures:
            return "Restores what the captures list shows."
        case .about:
            return "About shows read-only information; there is nothing to reset."
        case .providers:
            return "Restores provider order, visibility, plain-query search, and aliases. Provider files are left alone."
        case .providerFiles:
            return "Provider Files only opens folders and files; there is nothing to reset."
        case .configFiles:
            return "Config Files only opens files and exports a backup; there is nothing to reset."
        case .diagnostics:
            return "Diagnostics is read-only; there is nothing to reset."
        case .theming:
            return "Restores Palette's default theme and turns cross-app theming off. Generated files already on disk are left alone until the next Apply."
        }
    }

    private func resetSection() {
        let defaults = PaletteConfig()
        switch selectedTab {
        case .general:
            config.editorOpenWith = defaults.editorOpenWith
            config.terminal = defaults.terminal
            config.terminalApp = defaults.terminalApp
            config.timer = TimerConfig()
            config.updates = UpdateConfig()
            config.clipboard = ClipboardConfig()
            config.providerPrefix = defaults.providerPrefix
            appsMessage = nil
        case .launcher:
            config.searchPosition = .top
            config.appSort = .alphabetical
            config.window = WindowConfig()
            config.searchPlaceholder = defaults.searchPlaceholder
        case .appearance:
            config.typography = TypographyConfig()
        case .shortcuts:
            config.hotkey = defaults.hotkey
            config.clipboardHotkey = defaults.clipboardHotkey
            config.terminalHotkey = defaults.terminalHotkey
            config.themeGalleryHotkey = defaults.themeGalleryHotkey
            config.wallpaperGalleryHotkey = defaults.wallpaperGalleryHotkey
            config.scratchpadHotkey = defaults.scratchpadHotkey
            config.askHotkey = defaults.askHotkey
            config.screenshotHotkey = defaults.screenshotHotkey
            config.regionScreenshotHotkey = defaults.regionScreenshotHotkey
            config.windowScreenshotHotkey = defaults.windowScreenshotHotkey
            config.recordingHotkey = defaults.recordingHotkey
        case .search:
            config.webSearchEnabled = defaults.webSearchEnabled
            config.webSearchEngines = WebSearchEngine.defaults
            config.learningEnabled = defaults.learningEnabled
            engines = WebSearchEngine.defaults
            forgetLearnedMessage = nil
        case .ask:
            config.ask = AskConfig()
            askKeyMessage = nil
        case .terminal:
            config.terminalSession = TerminalSessionConfig()
            terminalShellChoice = "auto"
        case .bookmarks:
            bookmarks = []
            bookmarksSaveError = nil
        case .cheatsheets:
            config.cheatsheets = CheatsheetConfig()
            cheatsheetFolders = []
            cheatsheetExtensions = CheatsheetConfig().extensions.joined(separator: ", ")
        case .webApps:
            config.webAppBrowser = installedChromium.first ?? defaults.webAppBrowser
        case .screenshots:
            let capture = CaptureConfig()
            config.capture.directory = capture.directory
            config.capture.screenshotAction = capture.screenshotAction
            config.capture.screenshotFormat = capture.screenshotFormat
            config.capture.delay = capture.delay
        case .afterCapture:
            let capture = CaptureConfig()
            config.capture.hidePalette = capture.hidePalette
            config.capture.captureCursor = capture.captureCursor
            config.capture.showClicks = capture.showClicks
            config.capture.captureSound = capture.captureSound
            config.capture.captureThumbnail = capture.captureThumbnail
            config.capture.editAfterCapture = capture.editAfterCapture
            config.capture.previewRecording = capture.previewRecording
        case .recordings:
            let capture = CaptureConfig()
            config.capture.recordingAction = capture.recordingAction
            config.capture.recordingTarget = capture.recordingTarget
            config.capture.recordingDisplay = capture.recordingDisplay
            config.capture.recordingRegion = capture.recordingRegion
            config.capture.recordingFormat = capture.recordingFormat
            config.capture.recordingAudio = capture.recordingAudio
            config.capture.recordingMicrophone = capture.recordingMicrophone
        case .captures:
            config.capture.gallery = CaptureConfig().gallery
        case .theming:
            config.theme = ThemeSelection()
            config.theming = ThemingConfig()
            // Same as the master switch going off: reset must not leave the
            // marked blocks behind in the apps' configs.
            Task { @MainActor in _ = theming.removeAllIncludes() }
        case .about, .providerFiles, .configFiles, .diagnostics:
            break
        case .providers:
            providerOrder = providers.map(\.id)
            disabledProviders = []
            globalProviders = PaletteConfig.defaultGlobalProviders
            for id in allProviderIDs {
                resetAliases(id)
            }
        }
        schedulePersist()
    }

    // MARK: - File helpers

    private func addCheatsheetFolder() {
        // Native by necessity: the folder picker is macOS-owned.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            cheatsheetFolders.append(url.path)
        }
    }

    private func chooseDirectory(into binding: Binding<String>) {
        // Native by necessity: the folder picker is macOS-owned.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let current = (binding.wrappedValue as NSString).expandingTildeInPath
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    private func reveal(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
    }
}

extension Notification.Name {
    /// Script-only hook: posted with a one-entry dictionary so `PALETTE_SCRIPT`
    /// can exercise the same auto-apply path a control uses.
    static let paletteSettingsEdit = Notification.Name("palette.settings.edit")
    /// Script-only hook: scrolls the Settings detail pane to a search anchor.
    static let paletteSettingsJump = Notification.Name("palette.settings.jump")
    /// Clears the Settings search field so a scripted snapshot is canonical.
    static let paletteSettingsClearSearch = Notification.Name("palette.settings.clearSearch")
    /// Sets the Settings search field from a script, for the same reason.
    static let paletteSettingsSearch = Notification.Name("palette.settings.search")
}

/// Borderless AppKit field that records a real key press instead of asking the
/// user to type something like "opt+space". Delete or Backspace clears it.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var value: String
    var label: String
    var recordToken: Int = 0
    /// Returns an error message to refuse the key, or nil to accept it.
    var validate: ((String) -> String?)?
    /// Called with the refusal message, or nil when a key is accepted.
    var onValidation: ((String?) -> Void)?

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
        view.validate = validate
        view.onValidation = onValidation
        context.coordinator.lastToken = recordToken
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.label = label
        nsView.value = value
        nsView.validate = validate
        nsView.onValidation = onValidation
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
    var validate: ((String) -> String?)?
    var onValidation: ((String?) -> Void)?

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
        if code == 51 || code == 117 {
            finishRecording("")
            return nil
        }
        guard let nsEvent = NSEvent(cgEvent: event),
              let spec = HotKeySpec.from(event: nsEvent) else {
            NSSound.beep()
            return nil
        }
        if let message = validate?(spec.display) {
            NSSound.beep()
            finishRecording(nil, rejection: message)
            return nil
        }
        finishRecording(spec.display)
        return nil
    }

    private func finishRecording(_ display: String?, rejection: String? = nil) {
        stopRecording()
        if let display {
            value = display
            onChange?(display)
        }
        onValidation?(rejection)
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            finishRecording(nil)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            finishRecording("")
            return
        }
        guard let spec = HotKeySpec.from(event: event) else {
            NSSound.beep()
            return
        }
        if let message = validate?(spec.display) {
            NSSound.beep()
            finishRecording(nil, rejection: message)
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
