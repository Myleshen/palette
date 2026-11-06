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
                        "ask", "askh", "bw", "bwu", "bwt", "bwn", "bwo",
                        "zj", "web", "awake"]
            }
        }
    }

    @State private var config: PaletteConfig
    @State private var step = 0
    @State private var preset: Preset = .essentials
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    let providers: [ProviderSettingsInfo]
    let onFinish: (PaletteConfig) -> Void
    let onSkip: () -> Void

    init(
        config: PaletteConfig,
        providers: [ProviderSettingsInfo],
        onFinish: @escaping (PaletteConfig) -> Void,
        onSkip: @escaping () -> Void
    ) {
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
        .frame(width: 640, height: 520)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13))
        .preferredColorScheme(.dark)
    }

    private var shortcuts: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Launcher") {
                    ShortcutRecorder(value: $config.hotkey, label: "Launcher shortcut")
                        .frame(width: 190, height: 26)
                }
                LabeledContent("Clipboard") {
                    ShortcutRecorder(value: $config.clipboardHotkey, label: "Clipboard shortcut")
                        .frame(width: 190, height: 26)
                }
            }
            Section("Startup") {
                Toggle("Open Palette at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
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
                    TextField("Terminal", text: $config.terminalApp)
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

    private func finish() {
        let wanted = preset.providerIDs
        config.disabledProviders = providers
            .filter { $0.id != "apps" && $0.trigger != nil && !wanted.contains($0.id) }
            .map(\.id)
        onFinish(config)
    }
}
