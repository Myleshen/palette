import Foundation

public enum SnippetExpansion {
    /// Expands the small, deterministic placeholder set used by snippets.
    /// Unknown placeholders are left untouched so a typo is visible instead of
    /// silently deleting text.
    public static func expand(
        _ text: String,
        now: Date = Date(),
        clipboard: String = "",
        home: String = NSHomeDirectory(),
        user: String = NSUserName()
    ) -> String {
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let datetime = DateFormatter()
        datetime.dateFormat = "yyyy-MM-dd HH:mm"

        var result = text
        let replacements = [
            "{{date}}": date.string(from: now),
            "{{time}}": time.string(from: now),
            "{{datetime}}": datetime.string(from: now),
            "{{clipboard}}": clipboard,
            "{{uuid}}": UUID().uuidString,
            "{{home}}": home,
            "{{user}}": user,
            "{{cursor}}": "",
        ]
        for (placeholder, value) in replacements {
            result = result.replacingOccurrences(of: placeholder, with: value)
        }
        return result
    }
}
