import AppKit
import SwiftUI
import PaletteCore

struct SettingsView: View {
    @State private var config: PaletteConfig
    @State private var engines: [WebSearchEngine]
    @State private var selectedTab = 0

    private let themesDirectory: URL
    private let onSave: (PaletteConfig) -> Void
    private let onOpen: (URL) -> Void

    init(
        config: PaletteConfig,
        themesDirectory: URL,
        onSave: @escaping (PaletteConfig) -> Void,
        onOpen: @escaping (URL) -> Void
    ) {
        _config = State(initialValue: config)
        _engines = State(initialValue: config.webSearchEngines)
        self.themesDirectory = themesDirectory
        self.onSave = onSave
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                general.tabItem { Label("General", systemImage: "slider.horizontal.3") }.tag(0)
                appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }.tag(1)
                clipboard.tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }.tag(2)
                search.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(3)
                providers.tabItem { Label("Providers", systemImage: "square.stack.3d.up") }.tag(4)
            }
            .padding(20)

            Divider()

            HStack {
                Button("Open config.toml") { onOpen(configURL) }
                Spacer()
                Button("Cancel") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 660, height: 560)
    }

    private var configURL: URL {
        PalettePaths.resolve().configFile
    }

    private var general: some View {
        Form {
            Section("Launcher") {
                TextField("Hotkey", text: $config.hotkey)
                TextField("Clipboard hotkey", text: $config.clipboardHotkey)
                TextField("Provider prefix", text: $config.providerPrefix)
                TextField("Terminal", text: $config.terminalApp)
                TextField("Editor", text: $config.editorOpenWith)
            }
            Section("Layout") {
                Toggle("Show applications as a grid", isOn: $config.appGrid)
                Stepper("Grid columns: \(config.appGridColumns)", value: $config.appGridColumns, in: 3...8)
                    .disabled(!config.appGrid)
                Text("Grid is only used for an empty, unprefixed query.")
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
                Toggle("Offer web searches for every query", isOn: $config.webSearchEnabled)
                ForEach($engines) { $engine in
                    HStack {
                        TextField("Name", text: $engine.name)
                        TextField("https://example.com/?q={query}", text: $engine.urlTemplate)
                        Button(role: .destructive) {
                            engines.removeAll { $0.id == engine.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Engine") {
                    engines.append(WebSearchEngine(name: "New Engine", urlTemplate: "https://example.com/?q={query}"))
                }
            }
            Section {
                Text("Web results appear after apps; {query} is replaced with the URL-encoded text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var providers: some View {
        Form {
            Section("Locations") {
                Button("Open Providers Folder") { onOpen(PalettePaths.resolve().providersDir) }
                Button("Open Themes Folder") { onOpen(PalettePaths.resolve().themesDir) }
                Button("Open config.toml") { onOpen(configURL) }
            }
            Section("Manifest providers") {
                Text("Add a folder under providers/ with provider.toml. User providers override bundled ones with the same id. Press ⌘R after editing files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var themeNames: [String] {
        ThemeLoader.catalog(themesDirectory: themesDirectory).map(\.name)
    }

    private func displayName(_ name: String) -> String {
        ThemeLoader.catalog(themesDirectory: themesDirectory).first(where: { $0.name == name })?.displayName
            ?? name.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    private func save() {
        config.webSearchEngines = engines.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && $0.urlTemplate.contains("{query}")
        }
        config.appGridColumns = min(8, max(3, config.appGridColumns))
        onSave(config)
    }
}
