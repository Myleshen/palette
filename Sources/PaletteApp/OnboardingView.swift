import AppKit
import SwiftUI
import PaletteCore
import PalettePlatform
import ServiceManagement

struct OnboardingView: View {
    enum Preset: String, CaseIterable, Identifiable {
        case essentials
        case developer
        case everything

        var id: String { rawValue }

        var title: String {
            switch self {
            case .essentials: return "Essentials"
            case .developer: return "Developer"
            case .everything: return "Everything"
            }
        }

        var subtitle: String {
            switch self {
            case .essentials:
                return "Apps, clipboard, snippets, recent items, and web search."
            case .developer:
                return "Essentials plus editor paths, projects, commands, Git, ports, and terminal."
            case .everything:
                return "Adds Ask, Bitwarden, Zellij, web apps, and keep-awake."
            }
        }

        var providerIDs: Set<String> {
            switch self {
            case .essentials:
                return ["clip", "snip", "recent", "calc", "system", "theme"]
            case .developer:
                return ["clip", "snip", "recent", "calc", "system", "theme",
                        "neo", "neof", "proj", "cmd", "git", "port", "term"]
            case .everything:
                return ["clip", "snip", "recent", "calc", "system", "theme",
                        "neo", "neof", "proj", "cmd", "git", "port", "term",
                        "bw", "bwu", "bwt", "bwn", "bwo",
                        "zj", "web", "awake"]
            }
        }
    }

    @ObservedObject var themeManager: ThemeManager
    @State private var config: PaletteConfig
    @State private var step = 0
    @State private var preset: Preset = .essentials
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var shortcutMessage: String?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let providers: [ProviderSettingsInfo]
    let onFinish: (PaletteConfig) -> Void
    let onSkip: () -> Void

    private var theme: Theme { themeManager.theme }

    init(
        themeManager: ThemeManager,
        config: PaletteConfig,
        providers: [ProviderSettingsInfo],
        onFinish: @escaping (PaletteConfig) -> Void,
        onSkip: @escaping () -> Void
    ) {
        _themeManager = ObservedObject(wrappedValue: themeManager)
        _config = State(initialValue: config)
        self.providers = providers
        self.onFinish = onFinish
        self.onSkip = onSkip
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Welcome to Palette")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("Step \(step + 1) of 2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            Group {
                if step == 0 { shortcuts } else { startingSet }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(20)

            Divider()

            HStack {
                Button("Skip setup") { onSkip() }
                Spacer()
                if step == 1 {
                    Button("Back") { step = 0 }
                }
                if step == 0 {
                    Button("Continue") { step = 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Finish") { finish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 640, height: 640)
        .background(
            ZStack {
                if !reduceTransparency {
                    GlassBackdrop(material: .hudWindow)
                }
                theme.color(theme.palette.bg).opacity(reduceTransparency ? 1 : 0.65)
            }
        )
        .preferredColorScheme(theme.appearance == "light" ? .light : .dark)
    }

    private var shortcuts: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Launcher") {
                    ShortcutRecorder(
                        value: $config.hotkey,
                        label: "Launcher shortcut",
                        validate: { validateShortcut($0, current: config.hotkey) },
                        onValidation: { shortcutMessage = $0 }
                    )
                    .frame(width: 190, height: 26)
                }
                LabeledContent("Clipboard") {
                    ShortcutRecorder(
                        value: $config.clipboardHotkey,
                        label: "Clipboard shortcut",
                        validate: { validateShortcut($0, current: config.clipboardHotkey) },
                        onValidation: { shortcutMessage = $0 }
                    )
                    .frame(width: 190, height: 26)
                }
                if let shortcutMessage {
                    Text(shortcutMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("Capture shortcuts") {
                LabeledContent("Full screen") { Text(pretty(config.screenshotHotkey)) }
                LabeledContent("Region") { Text(pretty(config.regionScreenshotHotkey)) }
                LabeledContent("Window") { Text(pretty(config.windowScreenshotHotkey)) }
                LabeledContent("Recording") { Text(pretty(config.recordingHotkey)) }
                Text("Palette takes these keys while it runs, so they replace macOS's own screenshot shortcuts. Clear one later in Settings → Shortcuts to give it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Open Palette at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = "Could not update the login item: \(error.localizedDescription)"
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section {
                Text("Everything else can wait. You can change any of this later with ⌘, or /sys settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var startingSet: some View {
        Form {
            Section("Pick a starting set") {
                Picker("Starting set", selection: $preset) {
                    ForEach(Preset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                Text(preset.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if preset != .essentials {
                Section("Editor and terminal") {
                    TextField("Editor", text: $config.editorOpenWith)
                        .settingsField()
                    TextField("Terminal", text: $config.terminalApp)
                        .settingsField()
                    if let detected = detectedEditor {
                        Button("Use \(detected)") { config.editorOpenWith = detected }
                            .controlSize(.small)
                    }
                    Text("Examples: neovide, Visual Studio Code, Cursor, Zed, kitty, Ghostty. Missing tools can be installed later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("You can add more later") {
                Text("Everything is available in Settings → Providers. Essentials stays deliberately small.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if detectedEditor != nil, config.editorOpenWith.isEmpty {
                config.editorOpenWith = detectedEditor ?? ""
            }
        }
    }

    private var detectedEditor: String? {
        ["neovide", "Visual Studio Code", "Cursor", "Zed", "Sublime Text"]
            .first { ToolLocator.shared.appPath(named: $0) != nil }
    }

    /// The same duplicate rule Settings applies: compare Carbon identities,
    /// not typed strings, and include every built-in key already configured.
    private func validateShortcut(_ display: String, current: String) -> String? {
        guard let spec = HotKeySpec.parse(display) else {
            return "Not a valid shortcut."
        }
        if let currentSpec = HotKeySpec.parse(current), currentSpec.identity == spec.identity {
            return nil
        }
        let owned = [
            config.hotkey, config.clipboardHotkey, config.terminalHotkey,
            config.scratchpadHotkey, config.askHotkey, config.screenshotHotkey,
            config.regionScreenshotHotkey, config.windowScreenshotHotkey,
            config.recordingHotkey,
        ].filter { $0 != current }
        return ShortcutAvailability.message(for: spec, ownedKeys: owned)
    }

    private func pretty(_ raw: String) -> String {
        raw.isEmpty ? "Off" : (HotKeySpec.parse(raw)?.prettyDisplay ?? raw)
    }

    private func finish() {
        onFinish(Self.applying(preset, to: config, providers: providers))
    }

    /// The starting set is also what Skip applies, so declining setup never
    /// leaves all 30+ providers in the rail.
    static func applying(
        _ preset: Preset,
        to config: PaletteConfig,
        providers: [ProviderSettingsInfo]
    ) -> PaletteConfig {
        var updated = config
        updated.disabledProviders = providers
            .filter { $0.id != "apps" && $0.trigger != nil && !preset.providerIDs.contains($0.id) }
            .map(\.id)
        return updated
    }
}
