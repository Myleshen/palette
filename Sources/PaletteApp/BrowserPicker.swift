import SwiftUI
import PalettePlatform

/// Browser chooser shared by bookmarks and bangs. The bound value is "" for the
/// system default, an installed browser's app name, or free-form text typed in
/// the custom field.
struct BrowserPicker: View {
    @Binding var browser: String
    /// "Custom…" is a UI mode, never a stored browser. Keeping it here means
    /// picking it leaves `browser` at its previous value until text is typed.
    @State private var customMode: Bool

    private static let customTag = "__custom__"
    private static let installed = BrowserCatalog.activeBrowsers()

    init(browser: Binding<String>) {
        _browser = browser
        let stored = browser.wrappedValue
        _customMode = State(initialValue: !stored.isEmpty && !Self.installed.contains(stored))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Browser", selection: selection) {
                Text("Default browser").tag("")
                ForEach(Self.installed, id: \.self) { Text($0).tag($0) }
                Text("Custom…").tag(Self.customTag)
            }
            if customMode {
                TextField("App name or path", text: customText)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: { customMode ? Self.customTag : browser },
            set: { value in
                if value == Self.customTag {
                    customMode = true
                } else {
                    customMode = false
                    browser = value
                }
            }
        )
    }

    /// An older build could store the sentinel; show it as an empty field and
    /// let the first keystroke replace it.
    private var customText: Binding<String> {
        Binding(
            get: { browser == Self.customTag ? "" : browser },
            set: { browser = $0 }
        )
    }
}
