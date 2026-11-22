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

enum SettingsTab: Int, CaseIterable, Identifiable {
    // Raw values are the `settings_tab=<index>` script surface.
    case general, launcher, appearance, shortcuts, search, ask, providers

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .launcher: return "Launcher"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .search: return "Search"
        case .ask: return "Ask"
        case .providers: return "Providers"
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
        case .providers: return "square.stack.3d.up"
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
        case .providers: return Color(red: 0.61, green: 0.44, blue: 0.31)
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
        SettingsTabGroup(title: "Features", tabs: [.search, .ask]),
        SettingsTabGroup(title: "System", tabs: [.providers]),
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
    @ObservedObject private var themeManager: ThemeManager
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
    @State private var aliasPopover: String?
    @State private var loginMessage: String?
    @State private var launcherRecordToken = 0
    @State private var clipboardRecordToken = 0
    @State private var terminalRecordToken = 0
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
    @State private var bookmarksDirty = false
    @State private var terminalShellChoice: String
    @State private var cheatsheetFolders: [String]
    @State private var cheatsheetExtensions: String
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var keepAwakeStatus = KeepAwakeStatus()
    @State private var keepAwakeMessage: String?
    @State private var appsMessage: String?

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
    private let onExportBackup: () -> Void
    private let panelHeightForRows: (Int) -> CGFloat

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
        themesDirectory: URL,
        accessibilityTrusted: Bool,
        providers: [ProviderSettingsInfo],
        commands: [CatalogCommand],
        diagnostics: [String],
        onApply: @escaping (PaletteConfig) -> String?,
        onOpen: @escaping (URL) -> Void,
        onExportBackup: @escaping () -> Void,
        panelHeightForRows: @escaping (Int) -> CGFloat
    ) {
        _config = State(initialValue: config)
        _savedConfig = State(initialValue: config)
        _engines = State(initialValue: config.webSearchEngines)
        _accessibilityTrusted = State(initialValue: accessibilityTrusted)
        _askKeyStored = State(initialValue: AskKeychain.hasStoredKey(for: config.ask.endpoint))
        _bookmarks = State(initialValue: BookmarkStore.load(from: PalettePaths.resolve().bookmarksFile))
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
        _themeManager = ObservedObject(wrappedValue: themeManager)
        self.keepAwake = keepAwake
        self.themesDirectory = themesDirectory
        self.providers = providers
        self.commands = commands
        self.diagnostics = diagnostics
        self.initialWebAppBrowser = config.webAppBrowser
        self.onApply = onApply
        self.onOpen = onOpen
        self.onExportBackup = onExportBackup
        self.panelHeightForRows = panelHeightForRows
    }

    private var theme: Theme { themeManager.theme }
    private var muted: Color { theme.color(theme.palette.fgMuted) }
    private var danger: Color { theme.color(theme.palette.danger) }

    /// Exactly what the panel renders for the current rows and screen.
    private var derivedPanelHeight: CGFloat {
        panelHeightForRows(config.window.launcherRows(for: screenSize))
    }

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
        .onReceive(NotificationCenter.default.publisher(for: .paletteSettingsTab)) { note in
            guard let index = note.object as? Int, let tab = SettingsTab(rawValue: index) else { return }
            settingsSearch = ""
            selectedTab = tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .paletteSettingsClearSearch)) { _ in
            settingsSearch = ""
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
        .navigationSplitViewColumnWidth(min: 155, ideal: 165, max: 220)
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
                ProgressView().controlSize(.small)
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
                    Stepper("", value: bound, in: range, step: step)
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
                    Stepper("", value: bound, in: range, step: step)
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

    private var screenSize: CGSize {
        (PanelController.screenUnderPointer() ?? NSScreen.main)?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)
    }

    private var visibleRowsBinding: Binding<Int> {
        Binding(
            get: { config.window.launcherRows(for: screenSize) },
            set: { config.window.visibleRows = min(11, max(6, $0)) }
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

    private var widthAutomatic: Binding<Bool> {
        Binding(
            get: { config.window.width == 0 },
            set: { automatic in
                if automatic {
                    config.window.width = 0
                } else {
                    config.window.width = config.window.launcherWidth(for: screenSize)
                }
            }
        )
    }

    private var rowsAutomatic: Binding<Bool> {
        Binding(
            get: { config.window.visibleRows == 0 },
            set: { automatic in
                if automatic {
                    config.window.visibleRows = 0
                } else {
                    config.window.visibleRows = config.window.launcherRows(for: screenSize)
                }
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
        case .providers: providerSettings
        }
    }

    private var configURL: URL {
        PalettePaths.resolve().configFile
    }

    private var destinations: [SettingsDestination] {
        [
            .init(title: "Startup", tab: .general, anchor: "general-startup", keywords: "login start startup launch item"),
            .init(title: "Permissions", tab: .general, anchor: "general-permissions", keywords: "accessibility permission paste automation"),
            .init(title: "Keep Mac awake", tab: .general, anchor: "row-Keep Mac awake", keywords: "awake clamshell lid sleep power timer"),
            .init(title: "Clamshell mode", tab: .general, anchor: "row-Clamshell mode (lid closed)", keywords: "lid closed ac power"),
            .init(title: "Timer sound", tab: .general, anchor: "row-Play a sound when a timer finishes", keywords: "timer sound notification finish"),
            .init(title: "Timer notification", tab: .general, anchor: "row-Show a notification when a timer finishes", keywords: "timer sound notification finish"),
            .init(title: "Editor", tab: .general, anchor: "row-Editor", keywords: "editor neovide vscode cursor zed"),
            .init(title: "Terminal app", tab: .general, anchor: "row-Terminal", keywords: "terminal kitty ghostty external app"),
            .init(title: "Clipboard history", tab: .general, anchor: "row-Record clipboard history", keywords: "clipboard history entries poll clear retention secrets"),
            .init(title: "Launcher position", tab: .launcher, anchor: "launcher-position", keywords: "top center position"),
            .init(title: "Provider bar", tab: .launcher, anchor: "launcher-tabs", keywords: "provider bar top left hidden tabs"),
            .init(title: "Search placeholder", tab: .launcher, anchor: "row-Placeholder", keywords: "search hint placeholder text"),
            .init(title: "App order", tab: .launcher, anchor: "launcher-tabs", keywords: "alphabetical frequent sorting"),
            .init(title: "Fit to the active screen", tab: .launcher, anchor: "launcher-tabs", keywords: "fit screen auto size"),
            .init(title: "Width", tab: .launcher, anchor: "row-Width", keywords: "launcher width size automatic"),
            .init(title: "Visible rows", tab: .launcher, anchor: "row-Visible rows", keywords: "rows height automatic"),
            .init(title: "Scale", tab: .launcher, anchor: "row-Scale", keywords: "scale rem zoom"),
            .init(title: "Preview layout", tab: .launcher, anchor: "row-Preview", keywords: "preview beside below layout"),
            .init(title: "Command prefix", tab: .launcher, anchor: "row-Command prefix", keywords: "prefix provider command slash"),
            .init(title: "Terminal session", tab: .launcher, anchor: "row-Session", keywords: "terminal session zellij tmux fish zsh shell"),
            .init(title: "Terminal font", tab: .launcher, anchor: "row-Font family", keywords: "terminal font family size"),
            .init(title: "Themes", tab: .appearance, anchor: "appearance-theme", keywords: "theme dark light catppuccin gruvbox aetheria glass material"),
            .init(title: "UI font family", tab: .appearance, anchor: "row-UI family", keywords: "font family ui typography"),
            .init(title: "UI size", tab: .appearance, anchor: "row-UI size", keywords: "font size ui typography"),
            .init(title: "Mono font family", tab: .appearance, anchor: "row-Mono family", keywords: "font family mono code typography"),
            .init(title: "Mono size", tab: .appearance, anchor: "row-Mono size", keywords: "font size mono code typography"),
            .init(title: "Launcher shortcut", tab: .shortcuts, anchor: "row-Launcher shortcut", keywords: "hotkey shortcut launcher"),
            .init(title: "Clipboard shortcut", tab: .shortcuts, anchor: "row-Clipboard shortcut", keywords: "hotkey shortcut clipboard"),
            .init(title: "Terminal shortcut", tab: .shortcuts, anchor: "row-Terminal shortcut", keywords: "hotkey shortcut terminal"),
            .init(title: "Scratchpad shortcut", tab: .shortcuts, anchor: "row-Scratchpad shortcut", keywords: "hotkey shortcut scratchpad"),
            .init(title: "Ask shortcut", tab: .shortcuts, anchor: "row-Ask shortcut", keywords: "hotkey shortcut ask"),
            .init(title: "Screenshot shortcuts", tab: .shortcuts, anchor: "shortcuts-capture", keywords: "screenshot screen region window recording hotkey"),
            .init(title: "Custom hotkeys", tab: .shortcuts, anchor: "shortcuts-bindings", keywords: "binding launch command provider url shortcut hotkey"),
            .init(title: "Web search", tab: .search, anchor: "row-Show web results in search", keywords: "web search engine google duckduckgo github youtube"),
            .init(title: "Search engines", tab: .search, anchor: "search-engines", keywords: "engine url keyword bang !g"),
            .init(title: "Bookmarks", tab: .search, anchor: "search-bookmarks", keywords: "bookmark url keywords browser"),
            .init(title: "Cheatsheet folders", tab: .search, anchor: "search-cheatsheets", keywords: "cheatsheet reference pdf html markdown text image folder book"),
            .init(title: "Web app browser", tab: .search, anchor: "search-webapps", keywords: "browser helium chrome chromium web app"),
            .init(title: "Screenshot destination", tab: .search, anchor: "row-Save to", keywords: "screenshot capture delay format save folder"),
            .init(title: "Recording action", tab: .search, anchor: "row-recording-action", keywords: "recording audio microphone display region format"),
            .init(title: "After a capture", tab: .search, anchor: "search-screenshots", keywords: "cursor clicks shutter thumbnail annotator preview"),
            .init(title: "Ask provider", tab: .ask, anchor: "row-Provider", keywords: "ask endpoint model"),
            .init(title: "Ask model", tab: .ask, anchor: "row-Model", keywords: "ask model tokens fallback"),
            .init(title: "API key", tab: .ask, anchor: "ask-model", keywords: "api key token secret"),
            .init(title: "Ask history", tab: .ask, anchor: "row-Keep questions and answers", keywords: "ask history retention"),
            .init(title: "Plain queries", tab: .providers, anchor: "providers-default", keywords: "global unprefixed plain query provider default search"),
            .init(title: "Provider filter", tab: .providers, anchor: "providers-default", keywords: "filter find provider"),
            .init(title: "Provider order", tab: .providers, anchor: "providers-default", keywords: "provider order visibility trigger"),
            .init(title: "Provider aliases", tab: .providers, anchor: "providers-default", keywords: "provider alias shortcut"),
            .init(title: "Provider files", tab: .providers, anchor: "providers-files", keywords: "provider commands.toml folder"),
            .init(title: "Config file and logs", tab: .providers, anchor: "providers-config", keywords: "config log crash backup export diagnostics"),
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

        next.webSearchEngines = engines.filter { engineIssue($0) == nil }
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

        if bookmarksDirty {
            try? BookmarkStore.save(bookmarks, to: PalettePaths.resolve().bookmarksFile)
            bookmarksDirty = false
        }

        if let error = onApply(next) {
            saveState = .failed(error)
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
        case "width": config.window.width = Double(value) ?? 0
        case "visible_rows": config.window.visibleRows = Int(value) ?? 0
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
        guard HotKeySpec.parse(trimmed) != nil else {
            return "Not a valid shortcut. Click the field and press the keys you want."
        }
        let duplicates = hotkeyValues
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        if (duplicates[trimmed.lowercased()] ?? 0) > 1 {
            return "This shortcut is used more than once. Each one must be unique."
        }
        return nil
    }

    private var providerPrefixIssue: String? {
        config.providerPrefix.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Enter a prefix, usually /."
            : nil
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
        if engine.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Give the engine a name."
        }
        if !engine.urlTemplate.contains("{query}") {
            return "The search URL needs a {query} placeholder."
        }
        return nil
    }

    private var issueCount: Int {
        var count = 0
        if providerPrefixIssue != nil { count += 1 }
        if hotkeyIssue(config.hotkey, required: true, among: "") != nil { count += 1 }
        if hotkeyIssue(config.clipboardHotkey, required: true, among: "") != nil { count += 1 }
        if hotkeyIssue(config.terminalHotkey, required: false, among: "") != nil { count += 1 }
        if hotkeyIssue(config.scratchpadHotkey, required: false, among: "") != nil { count += 1 }
        if hotkeyIssue(config.askHotkey, required: false, among: "") != nil { count += 1 }
        if hotkeyIssue(config.screenshotHotkey, required: false, among: "") != nil { count += 1 }
        if hotkeyIssue(config.regionScreenshotHotkey, required: false, among: "") != nil { count += 1 }
        if hotkeyIssue(config.windowScreenshotHotkey, required: false, among: "") != nil { count += 1 }
        if hotkeyIssue(config.recordingHotkey, required: false, among: "") != nil { count += 1 }
        if webAppBrowserIssue != nil { count += 1 }
        count += engines.filter { engineIssue($0) != nil }.count
        count += aliasIssues.count
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

            card("Apps", anchor: "general-apps") {
                fieldRow("Editor") {
                    TextField("Editor", text: $config.editorOpenWith)
                        .settingsField()
                }
                fieldRow("Terminal") {
                    TextField("Terminal", text: $config.terminalApp)
                        .settingsField()
                }
                HStack(spacing: 8) {
                    Button("Detect installed apps") { detectDefaults() }
                }
                if let appsMessage {
                    Text(appsMessage).font(.caption).foregroundStyle(muted)
                }
            } footer: {
                Text("Used by projects, commands, Zellij, and Bitwarden. Examples: neovide, Visual Studio Code, Cursor, kitty, Terminal.")
            }

            card("Clipboard history", anchor: "general-clipboard") {
                toggleRow("Record clipboard history", isOn: $config.clipboard.enabled)
                numericRow("Maximum entries", value: $config.clipboard.maxEntries,
                           in: 50...50_000, step: 500)
                numericRow("Poll interval", value: $config.clipboard.pollMs,
                           in: 200...2_000, step: 50, unit: "ms")
                numericRow("Clear copied secrets after", value: clearAfterSecondsBinding,
                           in: 0...300, step: 5, unit: "s")
            } footer: {
                Text("Text and PNG images are stored. Anything another app marks concealed is never recorded. Zero seconds keeps secrets until you clear the history.")
            }
        }
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
        if let browser = installedChromium.first {
            config.webAppBrowser = browser
        }
        appsMessage = "Detected installed editor and browser where available."
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
                    Picker("App order", selection: $config.appSort) {
                        Text("Alphabetical").tag(AppSort.alphabetical)
                        Text("Most used").tag(AppSort.frequent)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                }
                toggleRow("Fit to the active screen", isOn: $config.window.autoSize)
            } footer: {
                Text("Provider tabs are the chip strip above the list, or the rail on the left. Hidden keeps Tab and /trigger for switching. Turn individual providers on or off under Providers. Fit sizes the launcher to the screen under the pointer.")
            }

            card("Size", anchor: "launcher-size") {
                numericRow("Width", value: widthBinding, in: 560...1_400, step: 20, unit: "pt",
                           automatic: widthAutomatic,
                           automaticValue: "\(Int(config.window.launcherWidth(for: screenSize))) pt")
                numericRow("Rows", value: visibleRowsBinding, in: 6...11, step: 1,
                           automatic: rowsAutomatic,
                           automaticValue: "\(config.window.launcherRows(for: screenSize))")
                Text("\(Int(derivedPanelHeight.rounded())) pt on this display")
                    .font(.caption)
                    .foregroundStyle(muted)
                numericRow("Scale", value: scalePercentBinding, in: 80...160, step: 5, unit: "%")
                pickerRow("Preview") {
                    Picker("Preview", selection: $config.window.previewLayout) {
                        Text("Automatic (window width)").tag(PreviewPlacement.auto)
                        Text("Below the list").tag(PreviewPlacement.below)
                        Text("Beside the list").tag(PreviewPlacement.beside)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                }
            } footer: {
                Text("Scale multiplies every launcher size, like rem. Width and rows override it, and Automatic falls back to the screen and scale. Clipboard, Ask, preview, terminal, and scratchpad widths live in config.toml under [window].")
            }

            card("Commands", anchor: "launcher-commands") {
                fieldRow("Command prefix", error: providerPrefixIssue) {
                    TextField("Command prefix", text: $config.providerPrefix)
                        .settingsField()
                        .frame(maxWidth: 92)
                }
            } footer: {
                Text("Prefix for provider commands such as /clip and /port. Usually /.")
            }

            card("Embedded terminal", anchor: "launcher-terminal") {
                pickerRow("Session") {
                    Picker("Session", selection: $config.terminalSession.multiplexer) {
                        Text("Auto").tag(TerminalMultiplexer.auto)
                        Text("Zellij").tag(TerminalMultiplexer.zellij)
                        Text("tmux").tag(TerminalMultiplexer.tmux)
                        Text("Plain shell").tag(TerminalMultiplexer.none)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                }
                fieldRow("Session name") {
                    TextField("Session name", text: $config.terminalSession.name)
                        .settingsField()
                }
                pickerRow("Shell") {
                    Picker("Shell", selection: $terminalShellChoice) {
                        Text("Auto (fish, then zsh)").tag("auto")
                        Text("Fish").tag("fish")
                        Text("Zsh").tag("zsh")
                        Text("Custom…").tag("custom")
                    }
                    .labelsHidden()
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
                           in: 0...48, step: 1, unit: "pt")
            } footer: {
                Text("Auto uses Zellij, then tmux, then a plain shell. Plain shells end when the panel closes. A size of 0 uses Kitty's font size, then the theme. Use a Nerd Font for icons.")
            }
        }
    }

    // MARK: - Appearance

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Theme", anchor: "appearance-theme") {
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
                pickerRow("Dark theme") {
                    Picker("Dark theme", selection: $config.theme.dark) {
                        ForEach(themeNames, id: \.self) { Text(displayName($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                }
                pickerRow("Light theme") {
                    Picker("Light theme", selection: $config.theme.light) {
                        ForEach(themeNames, id: \.self) { Text(displayName($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                }
                Button("Open themes folder") { onOpen(PalettePaths.resolve().themesDir) }
            } footer: {
                Text("Theme files use TOML. The active theme reloads when you pick another.")
            }

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
    }

    private var themeNames: [String] {
        ThemeLoader.catalog(themesDirectory: themesDirectory).map(\.name)
    }

    private var fontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
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
        return Picker("Font family", selection: value) {
            Text("Inherit — \(inherited)").tag("")
            ForEach(fontChoices(value.wrappedValue, installed: installed), id: \.self) { family in
                Text(installed.contains(family) ? family : "\(family) (missing)")
                    .tag(family)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 380, alignment: .leading)
    }

    private func displayName(_ name: String) -> String {
        ThemeLoader.catalog(themesDirectory: themesDirectory).first(where: { $0.name == name })?.displayName
            ?? name.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
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
                shortcutRow("Scratchpad shortcut", id: "scratchpad", value: $config.scratchpadHotkey,
                            token: $scratchpadRecordToken, label: "Scratchpad hotkey")
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
                ForEach(config.bindings.indices, id: \.self) { index in
                    bindingRow(index)
                }
                Button("Add hotkey") {
                    config.bindings.append(HotkeyBinding(keys: ""))
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

    private func bindingRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ShortcutRecorder(
                    value: $config.bindings[index].keys,
                    label: "Custom hotkey",
                    validate: { candidate in
                        validateCandidate(candidate, id: "binding-\(index)", current: config.bindings[index].keys)
                    },
                    onValidation: { message in
                        recordValidation("binding-\(index)", message: message)
                    }
                )
                .frame(width: 180, height: 26)
                Picker("Action", selection: $config.bindings[index].action) {
                    ForEach(HotkeyAction.allCases, id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                TextField(bindingPlaceholder(config.bindings[index].action), text: $config.bindings[index].value)
                    .settingsField()
                Button {
                    guard config.bindings.indices.contains(index) else { return }
                    config.bindings.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(muted)
                .help("Delete hotkey")
                .accessibilityLabel("Delete custom hotkey")
            }
            if let issue = shortcutErrors["binding-\(index)"]
                ?? bindingIssue(keys: config.bindings[index].keys, index: index) {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
        let values = hotkeyValues.filter { !$0.isEmpty }.map { $0.lowercased() }
        return Set(values).count != values.count
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
            ("terminal", config.terminalHotkey), ("scratchpad", config.scratchpadHotkey),
            ("ask", config.askHotkey), ("screen", config.screenshotHotkey),
            ("region", config.regionScreenshotHotkey), ("window", config.windowScreenshotHotkey),
            ("recording", config.recordingHotkey),
        ] + config.shortcuts.map { ($0.command, $0.keys) }
            + config.bindings.enumerated().map { ("binding-\($0.offset)", $0.element.keys) }
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
                ForEach($engines) { $engine in
                    engineRow($engine)
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
                Text("Type !keyword in the launcher, for example !yt lo-fi. The search URL must contain {query}, which Palette replaces with the URL-encoded text. An invalid engine is flagged here and the last valid one stays in config.toml.")
            }

            card("Bookmarks", anchor: "search-bookmarks") {
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
                            BrowserPicker(browser: $bookmark.browser)
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
                HStack(spacing: 8) {
                    Button("Add bookmark") {
                        bookmarks.append(Bookmark(name: "", url: "", browser: ""))
                    }
                    Button("Reveal in Finder") {
                        reveal(PalettePaths.resolve().bookmarksFile.path)
                    }
                    .help("Show bookmarks.toml in Finder")
                }
            } footer: {
                Text("Bookmarks open in a normal browser window, in the browser you pick. They live in bookmarks.toml; Reveal in Finder shows that file.")
            }

            card("Cheatsheets", anchor: "search-cheatsheets") {
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

            card("Web apps", anchor: "search-webapps") {
                fieldRow("Open web apps in", error: webAppBrowserIssue) {
                    Picker("Open web apps in", selection: webAppBrowserBinding) {
                        if webAppBrowserChoices.isEmpty {
                            Text("No Chromium browser found").tag("")
                        }
                        ForEach(webAppBrowserChoices, id: \.self) { name in
                            Text(installedChromium.contains(name) ? name : "\(name) (not installed)")
                                .tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)
                }
            } footer: {
                Text("Chromium-based browsers only. The list shows the ones installed on this Mac.")
            }

            card("Screenshots", anchor: "search-screenshots") {
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
                    Picker("Action", selection: $config.capture.screenshotAction) {
                        Text("Save").tag(CaptureAction.save)
                        Text("Copy").tag(CaptureAction.copy)
                        Text("Save and copy").tag(CaptureAction.saveCopy)
                        Text("Save and preview").tag(CaptureAction.preview)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)
                }
                pickerRow("Format", anchor: "row-screenshot-format") {
                    Picker("Format", selection: $config.capture.screenshotFormat) {
                        Text("PNG").tag("png")
                        Text("JPG").tag("jpg")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160, alignment: .leading)
                }
                numericRow("Delay before capture", value: $config.capture.delay,
                           in: 0...10, step: 1, unit: "s")
            } footer: {
                Text("Use /shot or the screen, region, and window shortcuts. Save to supports ~ and is created on the first capture.")
            }

            card("Recordings", anchor: "search-recordings") {
                pickerRow("Action", anchor: "row-recording-action") {
                    Picker("Action", selection: $config.capture.recordingAction) {
                        Text("Save").tag(CaptureAction.save)
                        Text("Save and copy").tag(CaptureAction.saveCopy)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)
                }
                pickerRow("What to record") {
                    Picker("What to record", selection: $config.capture.recordingTarget) {
                        Text("Whole screen").tag("screen")
                        Text("A display").tag("display")
                        Text("A region").tag("region")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)
                }
                if config.capture.recordingTarget == "display" {
                    pickerRow("Display") {
                        Picker("Display", selection: $config.capture.recordingDisplay) {
                            ForEach(CaptureDisplays.active()) { display in
                                Text(display.label).tag(display.index)
                            }
                        }
                        .labelsHidden()
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
                    Picker("Format", selection: $config.capture.recordingFormat) {
                        Text("MOV").tag("mov")
                        Text("MP4").tag("mp4")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160, alignment: .leading)
                }
                toggleRow("Record audio", isOn: $config.capture.recordingAudio)
                pickerRow("Microphone") {
                    Picker("Microphone", selection: $config.capture.recordingMicrophone) {
                        Text("System default").tag("")
                        ForEach(CaptureMicrophones.active(), id: \.id) { microphone in
                            Text(microphone.name).tag(microphone.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)
                    .disabled(!config.capture.recordingAudio)
                }
            } footer: {
                Text("Use /rec to start or stop a recording. Recordings are saved with the system capture engine.")
            }

            card("After a capture") {
                toggleRow("Hide Palette before capturing", isOn: $config.capture.hidePalette)
                toggleRow("Include the cursor", isOn: $config.capture.captureCursor)
                toggleRow("Show clicks while recording", isOn: $config.capture.showClicks)
                toggleRow("Shutter sound after a screenshot", isOn: $config.capture.captureSound)
                toggleRow("Show a thumbnail after a screenshot", isOn: $config.capture.captureThumbnail)
                toggleRow("Open the annotator after a screenshot", isOn: $config.capture.editAfterCapture)
                toggleRow("Preview recordings when they stop", isOn: $config.capture.previewRecording)
            }

            card("Captures list") {
                pickerRow("List") {
                    Picker("List", selection: $config.capture.gallery) {
                        Text("Everything in the folder").tag("all")
                        Text("Only Palette's captures").tag("palette")
                    }
                    .labelsHidden()
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

    private func engineRow(_ engine: Binding<WebSearchEngine>) -> some View {
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
                    engines.removeAll { $0.id == engine.wrappedValue.id }
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
        Menu {
            Button("Default browser") { engine.wrappedValue.browser = "" }
            Divider()
            ForEach(BrowserCatalog.activeBrowsers(), id: \.self) { name in
                Button {
                    engine.wrappedValue.browser = name
                } label: {
                    if engine.wrappedValue.browser == name {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            if !engine.wrappedValue.browser.isEmpty,
               !BrowserCatalog.activeBrowsers().contains(engine.wrappedValue.browser) {
                Text("\(engine.wrappedValue.browser) (not installed)")
                    .disabled(true)
            }
            Divider()
            Toggle("Open in web app", isOn: engine.appMode)
        } label: {
            Text(engine.wrappedValue.browser.isEmpty ? "Default" : engine.wrappedValue.browser)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
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
                    Picker("Provider", selection: $config.ask.endpoint) {
                        ForEach(AskEndpoint.allCases, id: \.self) { endpoint in
                            Text(endpoint.displayName).tag(endpoint)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)
                }
                pickerRow("Model") {
                    Picker("Model", selection: $config.ask.model) {
                        ForEach(AskModel.models(for: config.ask.endpoint)) { model in
                            Text(model.free ? "FREE · \(model.name)" : "\(model.name) · \(model.note)")
                                .tag(model.id)
                        }
                    }
                    .labelsHidden()
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

            card("Provider files", anchor: "providers-files") {
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
            }

            card("Configuration", anchor: "providers-config") {
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
                Text("Settings writes config.toml for you. Edit it directly only for options that are not in this window, then press ⌘R.")
            }

            card("Diagnostics") {
                if diagnostics.isEmpty {
                    Text("No startup diagnostics.").font(.caption).foregroundStyle(muted)
                } else {
                    ForEach(diagnostics, id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
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

    private func providerTrigger(_ id: String) -> String? {
        providers.first(where: { $0.id == id })?.trigger
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

            Text(providerName(id))
                .fontWeight(.medium)
                .lineLimit(2)
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
            return "Restores the editor, terminal app, notification, and clipboard-history defaults. Startup, permissions, and power are left alone."
        case .launcher:
            return "Restores launcher position, size, behaviour, command prefix, and the embedded terminal defaults."
        case .appearance:
            return "Restores the default theme and the theme's typography."
        case .shortcuts:
            return "Restores every global shortcut to its default. Custom hotkeys are left alone."
        case .search:
            return "Restores web search, engines, the web-app browser, screenshots, recordings, and cheatsheet folders. Bookmarks and saved files are left alone."
        case .ask:
            return "Restores the Ask endpoint, model, tokens, fallback, notifications, and history limits. Saved API keys are left alone."
        case .providers:
            return "Restores provider order, visibility, plain-query search, and aliases. Provider files are left alone."
        }
    }

    private func resetSection() {
        let defaults = PaletteConfig()
        switch selectedTab {
        case .general:
            config.editorOpenWith = defaults.editorOpenWith
            config.terminalApp = defaults.terminalApp
            config.timer = TimerConfig()
            config.clipboard = ClipboardConfig()
            appsMessage = nil
        case .launcher:
            config.searchPosition = .top
            config.appSort = .alphabetical
            config.window = WindowConfig()
            config.providerPrefix = defaults.providerPrefix
            config.searchPlaceholder = defaults.searchPlaceholder
            config.terminalSession = TerminalSessionConfig()
            terminalShellChoice = "auto"
        case .appearance:
            config.theme = ThemeSelection()
            config.typography = TypographyConfig()
        case .shortcuts:
            config.hotkey = defaults.hotkey
            config.clipboardHotkey = defaults.clipboardHotkey
            config.terminalHotkey = defaults.terminalHotkey
            config.scratchpadHotkey = defaults.scratchpadHotkey
            config.askHotkey = defaults.askHotkey
            config.screenshotHotkey = defaults.screenshotHotkey
            config.regionScreenshotHotkey = defaults.regionScreenshotHotkey
            config.windowScreenshotHotkey = defaults.windowScreenshotHotkey
            config.recordingHotkey = defaults.recordingHotkey
        case .search:
            config.webSearchEnabled = defaults.webSearchEnabled
            config.webSearchEngines = WebSearchEngine.defaults
            engines = WebSearchEngine.defaults
            config.webAppBrowser = installedChromium.first ?? defaults.webAppBrowser
            config.capture = CaptureConfig()
            config.cheatsheets = CheatsheetConfig()
            cheatsheetFolders = []
            cheatsheetExtensions = CheatsheetConfig().extensions.joined(separator: ", ")
        case .ask:
            config.ask = AskConfig()
            askKeyMessage = nil
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            cheatsheetFolders.append(url.path)
        }
    }

    private func chooseDirectory(into binding: Binding<String>) {        let panel = NSOpenPanel()
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
