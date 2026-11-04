import AppKit
import SwiftUI
import PaletteCore
import PalettePlatform
import ServiceManagement

struct OnboardingView: View {
    @State private var config: PaletteConfig
    @State private var disabled: [String]
    @State private var step = 0
    @State private var askKey = ""
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
        _disabled = State(initialValue: config.disabledProviders)
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
                Text("Step \(step + 1) of 3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            Group {
                switch step {
                case 0: shortcuts
                case 1: providerStep
                default: askStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(20)

            Divider()

            HStack {
                Button("Skip setup") { onSkip() }
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                if step < 2 {
                    Button("Continue") { step += 1 }
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
                Text("You can change all of this later with ⌘, or /sys settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var providerStep: some View {
        Form {
            Section("Show these in the tab bar") {
                ForEach(providers.filter { $0.id != "apps" }) { provider in
                    Toggle(provider.name, isOn: Binding(
                        get: { !disabled.contains(provider.id) },
                        set: { enabled in
                            if enabled { disabled.removeAll { $0 == provider.id } }
                            else if !disabled.contains(provider.id) { disabled.append(provider.id) }
                        }
                    ))
                }
            }
            Section("Apps") {
                TextField("Terminal", text: $config.terminalApp)
                TextField("Editor", text: $config.editorOpenWith)
                Text("Examples: kitty, Terminal, neovide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var askStep: some View {
        Form {
            Section("Ask (optional)") {
                Text("OpenCode Go powers /ask. Add a Go API key now or later in Settings → Ask.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("OpenCode Go API key", text: $askKey)
                if AskKeychain.hasStoredKey(for: .opencodeGo) {
                    Text("A key is already saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Ready") {
                Text("Palette will apply these choices immediately. Press ⌘, anytime to refine them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func finish() {
        let key = askKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { _ = AskKeychain.save(key, for: .opencodeGo) }
        config.disabledProviders = disabled.filter { $0 != "apps" }
        onFinish(config)
    }
}
