import SwiftUI
import PalettePlatform

/// Browser chooser shared by bookmarks and bangs. The bound value is "" for the
/// system default, an installed browser's app name, or free-form text typed in
/// the custom field.
struct BrowserPicker: View {
    @Binding var browser: String

    private static let customTag = "__custom__"
    private static let installed = BrowserCatalog.activeBrowsers()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Browser", selection: selection) {
                Text("Default browser").tag("")
                ForEach(Self.installed, id: \.self) { Text($0).tag($0) }
                Text("Custom…").tag(Self.customTag)
            }
            if isCustom {
                TextField("App name or path", text: customText)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    /// Any value that is not empty and not an installed name was typed here.
    private var isCustom: Bool {
        !browser.isEmpty && !Self.installed.contains(browser)
    }

    private var selection: Binding<String> {
        Binding(
            get: { isCustom ? Self.customTag : browser },
            set: { value in
                if value == Self.customTag {
                    // Keep what was typed; start the field empty when switching
                    // from the default browser.
                    if browser.isEmpty { browser = Self.customTag }
                } else {
                    browser = value
                }
            }
        )
    }

    /// "__custom__" is a UI marker, never stored: typing replaces it.
    private var customText: Binding<String> {
        Binding(
            get: { browser == Self.customTag ? "" : browser },
            set: { browser = $0 }
        )
    }
}
