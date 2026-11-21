import Foundation

/// One styled run of inline text. Kept as plain data so the block parser can
/// live in Core (and be tested) while PaletteApp applies the theme fonts.
public struct AskInlineSpan: Equatable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var code: Bool
    public var strike: Bool
    public var link: URL?

    public init(
        text: String,
        bold: Bool = false,
        italic: Bool = false,
        code: Bool = false,
        strike: Bool = false,
        link: URL? = nil
    ) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
        self.strike = strike
        self.link = link
    }
}

public enum AskMarkdownBlock: Equatable, Sendable {
    public struct ListItem: Equatable, Sendable {
        public var marker: String
        public var level: Int
        public var spans: [AskInlineSpan]

        public init(marker: String, level: Int, spans: [AskInlineSpan]) {
            self.marker = marker
            self.level = level
            self.spans = spans
        }
    }

    case heading(level: Int, spans: [AskInlineSpan])
    case paragraph([AskInlineSpan])
    case list([ListItem])
    case code(language: String?, code: String)
    case quote([AskInlineSpan])
    case rule
}

/// The small markdown subset `/ask` answers actually use. Line-based and
/// tolerant: anything it cannot read stays literal text.
public enum AskMarkdown {
    public static func blocks(_ source: String) -> [AskMarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [AskMarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                // An unterminated fence keeps everything to EOF. The code is
                // shown verbatim rather than swallowing the rest of the answer.
                if index < lines.count { index += 1 }
                result.append(.code(
                    language: language.isEmpty ? nil : language,
                    code: code.joined(separator: "\n")
                ))
                continue
            }
            if let heading = heading(trimmed) {
                result.append(.heading(level: heading.level, spans: spans(heading.text)))
                index += 1
                continue
            }
            if isRule(trimmed) {
                result.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                result.append(.quote(spans(quote.joined(separator: " "))))
                continue
            }
            if listItem(lines[index]) != nil {
                var items: [AskMarkdownBlock.ListItem] = []
                while index < lines.count, let item = listItem(lines[index]) {
                    items.append(item)
                    index += 1
                }
                result.append(.list(items))
                continue
            }
            var paragraph: [String] = []
            while index < lines.count {
                let raw = lines[index]
                let text = raw.trimmingCharacters(in: .whitespaces)
                if text.isEmpty || text.hasPrefix("```") || heading(text) != nil
                    || isRule(text) || text.hasPrefix(">") || listItem(raw) != nil {
                    break
                }
                paragraph.append(text)
                index += 1
            }
            result.append(.paragraph(spans(paragraph.joined(separator: " "))))
        }
        return result
    }

    public static func spans(_ source: String) -> [AskInlineSpan] {
        var result: [AskInlineSpan] = []
        var plain = ""
        var index = source.startIndex
        let end = source.endIndex

        func flushPlain() {
            if !plain.isEmpty {
                result.append(AskInlineSpan(text: plain))
                plain = ""
            }
        }

        func appendStyled(
            _ inner: String,
            bold: Bool = false,
            italic: Bool = false,
            strike: Bool = false,
            code: Bool = false
        ) {
            flushPlain()
            var innerSpans = spans(inner)
            if innerSpans.isEmpty { innerSpans = [AskInlineSpan(text: inner)] }
            for var span in innerSpans {
                span.bold = span.bold || bold
                span.italic = span.italic || italic
                span.strike = span.strike || strike
                span.code = span.code || code
                result.append(span)
            }
        }

        while index < end {
            let rest = source[index...]
            if rest.hasPrefix("`") {
                let after = source.index(after: index)
                if let close = source[after...].firstIndex(of: "`") {
                    appendStyled(String(source[after..<close]), code: true)
                    index = source.index(after: close)
                } else {
                    plain.append("`")
                    index = after
                }
                continue
            }
            if rest.hasPrefix("**") {
                let after = source.index(index, offsetBy: 2)
                if let close = source.range(of: "**", range: after..<end) {
                    appendStyled(String(source[after..<close.lowerBound]), bold: true)
                    index = close.upperBound
                } else {
                    plain.append("**")
                    index = after
                }
                continue
            }
            if rest.hasPrefix("~~") {
                let after = source.index(index, offsetBy: 2)
                if let close = source.range(of: "~~", range: after..<end) {
                    appendStyled(String(source[after..<close.lowerBound]), strike: true)
                    index = close.upperBound
                } else {
                    plain.append("~~")
                    index = after
                }
                continue
            }
            if rest.hasPrefix("*") || rest.hasPrefix("_") {
                let marker = source[index]
                let after = source.index(after: index)
                let previous = index > source.startIndex ? source[source.index(before: index)] : nil
                // `_` only starts emphasis at a word boundary, so snake_case
                // survives intact.
                let mayOpen = marker == "*" || isBoundary(previous)
                if mayOpen, let close = source[after...].firstIndex(of: marker) {
                    let inner = String(source[after..<close])
                    let next = source.index(after: close)
                    let trailing = next < end ? source[next] : nil
                    if !inner.isEmpty, marker == "*" || isBoundary(trailing) {
                        appendStyled(inner, italic: true)
                        index = next
                        continue
                    }
                }
                plain.append(marker)
                index = after
                continue
            }
            if rest.hasPrefix("[") {
                if let closeBracket = source[index...].firstIndex(of: "]"),
                   let openParen = source.index(closeBracket, offsetBy: 1, limitedBy: end),
                   openParen < end, source[openParen] == "(",
                   let closeParen = source[source.index(after: openParen)...].firstIndex(of: ")") {
                    let label = String(source[source.index(after: index)..<closeBracket])
                    let urlText = String(source[source.index(after: openParen)..<closeParen])
                    if !label.isEmpty, let url = URL(string: urlText) {
                        flushPlain()
                        var labelSpans = spans(label)
                        if labelSpans.isEmpty { labelSpans = [AskInlineSpan(text: label)] }
                        for var span in labelSpans {
                            span.link = url
                            result.append(span)
                        }
                        index = source.index(after: closeParen)
                        continue
                    }
                }
                plain.append("[")
                index = source.index(after: index)
                continue
            }
            plain.append(source[index])
            index = source.index(after: index)
        }
        flushPlain()
        return result
    }

    private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (hashes.count, text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> AskMarkdownBlock.ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let level = indent >= 2 ? 1 : 0
        let body = String(line.dropFirst(indent))
        guard body.count > 2 else { return nil }
        let characters = Array(body)
        if let first = characters.first, "-*+".contains(first), characters[1] == " " {
            let rest = String(characters.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }
            return .init(marker: level == 0 ? "•" : "◦", level: level, spans: spans(rest))
        }
        let digits = characters.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let markerIndex = digits.count
        guard markerIndex + 1 < characters.count,
              characters[markerIndex] == "." || characters[markerIndex] == ")",
              characters[markerIndex + 1] == " " else { return nil }
        let rest = String(characters.dropFirst(markerIndex + 2)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return .init(marker: "\(String(digits)).", level: level, spans: spans(rest))
    }

    private static func isBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        return character.isWhitespace || character.isPunctuation || character.isSymbol
    }
}
