import PaletteCore

/// The rows behind the browser picker on a web-search engine. Shared by
/// Settings and the scripted probe, so the harness checks the rows the UI
/// really builds rather than a copy that could drift.
enum EngineBrowserMenu {
    static func items(browser: String, browsers: [String], appMode: Bool) -> [PaletteMenuItem] {
        var items: [PaletteMenuItem] = [
            PaletteMenuItem(id: "default-browser", title: "Default browser", checked: browser.isEmpty),
            .separator("browsers"),
        ]
        items += browsers.map { name in
            PaletteMenuItem(id: "browser:\(name)", title: name, checked: browser == name)
        }
        if !browser.isEmpty, !browsers.contains(browser) {
            items.append(PaletteMenuItem(
                id: "missing-browser",
                title: "\(browser) (not installed)",
                enabled: false
            ))
        }
        items.append(.separator("mode"))
        // A Toggle inside the old native menu crashed: the menu dismissed while
        // the array-element binding wrote, and the reload invalidated the
        // index. Two plain actions mutate the engine by identity instead.
        items.append(PaletteMenuItem(id: "app-mode", title: "Open in web app", checked: appMode))
        items.append(PaletteMenuItem(id: "tab-mode", title: "Open in a browser tab", checked: !appMode))
        return items
    }
}
