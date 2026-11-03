import Foundation

/// Safe, built-in clipboard transforms. Nothing here executes a shell or a
/// user script: the transformed text is only shown, then copied or pasted.
public enum ClipboardTransform: String, CaseIterable, Identifiable, Sendable {
    case trim
    case jsonPretty
    case jsonMinify
    case base64Encode
    case base64Decode
    case urlEncode
    case urlDecode
    case shellQuote
    case pathQuote
    case uppercase
    case lowercase
    case sortLines
    case dedupeLines
    case stripANSI
    case markdownLink
    case slug

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .trim: return "Trim Whitespace"
        case .jsonPretty: return "Pretty-print JSON"
        case .jsonMinify: return "Minify JSON"
        case .base64Encode: return "Base64 Encode"
        case .base64Decode: return "Base64 Decode"
        case .urlEncode: return "URL Encode"
        case .urlDecode: return "URL Decode"
        case .shellQuote: return "Shell Quote"
        case .pathQuote: return "Quote Paths"
        case .uppercase: return "Uppercase"
        case .lowercase: return "Lowercase"
        case .sortLines: return "Sort Lines"
        case .dedupeLines: return "Dedupe Lines"
        case .stripANSI: return "Strip ANSI Colours"
        case .markdownLink: return "Markdown Link"
        case .slug: return "Slug"
        }
    }

    public func apply(to text: String) -> String? {
        switch self {
        case .trim:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .jsonPretty:
            guard let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
                  let result = String(data: pretty, encoding: .utf8) else { return nil }
            return result
        case .jsonMinify:
            guard let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data),
                  let compact = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let result = String(data: compact, encoding: .utf8) else { return nil }
            return result
        case .base64Encode:
            return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return String(data: data, encoding: .utf8)
        case .urlEncode:
            return text.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        case .urlDecode:
            return text.removingPercentEncoding
        case .shellQuote:
            return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        case .pathQuote:
            let escaped = CharacterSet(charactersIn: " ()[]{}$&;|*?!<>#\"'\\")
            return text.unicodeScalars.map { escaped.contains($0) ? "\\" + String($0) : String($0) }.joined()
        case .uppercase:
            return text.uppercased()
        case .lowercase:
            return text.lowercased()
        case .sortLines:
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .joined(separator: "\n")
        case .dedupeLines:
            var seen = Set<String>()
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { seen.insert(String($0)).inserted }
                .joined(separator: "\n")
        case .stripANSI:
            return text.replacingOccurrences(
                of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]",
                with: "",
                options: .regularExpression
            )
        case .markdownLink:
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.count >= 2 {
                return "[\(lines[0])](\(lines[1]))"
            }
            if let url = lines.first, url.hasPrefix("http://") || url.hasPrefix("https://") {
                return "[\(url)](\(url))"
            }
            return nil
        case .slug:
            let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            let slug = folded
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return slug.isEmpty ? nil : slug
        }
    }
}
