import AppKit
import SwiftUI
import PaletteCore
import PalettePlatform

struct SettingsView: View {
    @State private var config: PaletteConfig
    @State private var engines: [WebSearchEngine]
    @State private var selectedTab = 0
    @State private var saveError: String?
    @State private var launcherRecordToken = 0
    @State private var clipboardRecordToken = 0

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
                advanced.tabItem { Label("Advanced", systemImage: "gearshape.2") }.tag(4)
            }
            .padding(20)

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
        .frame(width: 720, height: 640)
        .alert("Cannot Save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var configURL: URL {
        PalettePaths.resolve().configFile
    }

    private var general: some View {
        Form {
            Section("Launcher") {
                LabeledContent("Hotkey") {
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
                LabeledContent("Clipboard hotkey") {
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
                TextField("Provider prefix", text: $config.providerPrefix)
                TextField("Terminal", text: $config.terminalApp)
                TextField("Editor", text: $config.editorOpenWith)
                Text("Click Record, then press the shortcut you want. Save applies it immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Launcher position") {
                Picker("Opens at", selection: $config.searchPosition) {
                    Text("Top").tag(SearchPosition.top)
                    Text("Center").tag(SearchPosition.center)
                }
                .pickerStyle(.segmented)
                Text("Top drops down from the menu bar; Center opens in the middle of the screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Search bar", selection: $config.searchStyle) {
                    Text("Classic").tag(SearchStyle.classic)
                    Text("Siri-style pill").tag(SearchStyle.pill)
                }
                .pickerStyle(.segmented)
                Text("The pill rounds the search field, tabs, rows, and panel together; Classic keeps the original layout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show applications as a grid", isOn: $config.appGrid)
                Stepper("Grid columns: \(config.appGridColumns)", value: $config.appGridColumns, in: 3...8)
                    .disabled(!config.appGrid)
                Picker("App order", selection: $config.appSort) {
                    Text("Alphabetical").tag(AppSort.alphabetical)
                    Text("Most used").tag(AppSort.frequent)
                }
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
            Section("Web apps") {
                Picker("Open web apps in", selection: $config.webAppBrowser) {
                    ForEach(BrowserCatalog.chromiumChoices, id: \.self) { Text($0).tag($0) }
                }
                Text("Chromium-based browsers only; Helium is the default. Palette refuses to save a browser that is not installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Web results appear after apps; {query} is replaced with the URL-encoded text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var advanced: some View {
        Form {
            Section("Files") {
                Button("Open config.toml") { onOpen(configURL) }
                Button("Open Providers Folder") { onOpen(PalettePaths.resolve().providersDir) }
                Button("Open Themes Folder") { onOpen(PalettePaths.resolve().themesDir) }
                Button("Open Log") { onOpen(PalettePaths.resolve().logFile) }
            }
            Section("Custom providers") {
                Text("Add a folder under providers/ with provider.toml. User providers override bundled ones with the same id. Press ⌘R after editing files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Config file") {
                Text("Everything above is written to config.toml. Edit it directly only when you need options the Settings window does not expose.")
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
        guard HotKeySpec.parse(config.hotkey) != nil else {
            saveError = "The launcher hotkey is not a valid shortcut. Click the field and press the keys you want."
            return
        }
        guard HotKeySpec.parse(config.clipboardHotkey) != nil else {
            saveError = "The clipboard hotkey is not a valid shortcut. Click the field and press the keys you want."
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
        config.appGridColumns = min(8, max(3, config.appGridColumns))
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

    override var acceptsFirstResponder: Bool { true }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        return true
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }
        guard let spec = HotKeySpec.from(event: event) else { return }
        value = spec.display
        onChange?(spec.display)
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
