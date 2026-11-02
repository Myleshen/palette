import Foundation

/// The Chromium-based browsers Palette is willing to hand web apps to.
/// Validation lives here so the Settings UI and tests share one rule.
public enum BrowserCatalog {
    public static let chromiumChoices = [
        "Helium",
        "Google Chrome",
        "Brave Browser",
        "Microsoft Edge",
        "Arc",
        "Chromium",
        "Vivaldi",
        "Opera",
    ]

    public static func validationError(for name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Choose a browser for web apps."
        }
        guard chromiumChoices.contains(trimmed) else {
            return "\(trimmed) is not a supported Chromium browser. Choose one from the list."
        }
        guard ToolLocator.shared.appPath(named: trimmed) != nil else {
            return "\(trimmed) is not installed. Install it, or choose an installed Chromium browser."
        }
        return nil
    }
}
