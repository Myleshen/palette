import AppKit
import PaletteCore
import SwiftUI

/// Renders the parsed markdown blocks of one answer with the house theme.
/// Parsing happens in the chat state; this view only turns spans into
/// `AttributedString`s, so streaming re-renders stay cheap.
struct AskMarkdownView: View {
    var blocks: [AskMarkdownBlock]
    var theme: Theme

    @State private var copiedCode: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AskMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let spans):
            plainText(spans, size: headingSize(level), weight: .semibold)
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 2 : 0)
        case .paragraph(let spans):
            plainText(spans, size: bodySize)
                .lineSpacing(2)
                .textSelection(.enabled)
        case .list(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(theme.font(size: bodySize))
                            .foregroundStyle(theme.color(theme.palette.fgMuted))
                        plainText(item.spans, size: bodySize)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.level) * 16)
                }
            }
        case .code(let language, let code):
            codeBlock(language: language, code: code)
        case .quote(let spans):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(theme.color(theme.palette.accent).opacity(0.5))
                    .frame(width: 2)
                plainText(spans, size: bodySize)
                    .foregroundStyle(theme.color(theme.palette.fgMuted))
                    .textSelection(.enabled)
            }
        case .rule:
            Rectangle()
                .fill(theme.color(theme.palette.separator))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func plainText(
        _ spans: [AskInlineSpan],
        size: Double,
        weight: Font.Weight = .regular
    ) -> Text {
        var out = AttributedString()
        let base = theme.font(size: size, weight: weight)
        let mono = theme.monoFont(size: size)
        for span in spans {
            var piece = AttributedString(span.text)
            if span.code {
                piece.font = mono
            } else {
                var font = base
                if span.bold { font = font.bold() }
                if span.italic { font = font.italic() }
                piece.font = font
            }
            if span.strike { piece.strikethroughStyle = .single }
            if let url = span.link {
                piece.link = url
                piece.foregroundColor = theme.color(theme.palette.accent)
            }
            out += piece
        }
        return Text(out)
    }

    private func codeBlock(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(theme.font(size: max(8, bodySize - 4)))
                        .foregroundStyle(theme.color(theme.palette.fgMuted))
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copiedCode = code
                    Task {
                        try? await Task.sleep(for: .milliseconds(1_200))
                        if copiedCode == code { copiedCode = nil }
                    }
                } label: {
                    Label(
                        copiedCode == code ? "Copied" : "Copy",
                        systemImage: copiedCode == code ? "checkmark" : "doc.on.doc"
                    )
                    .font(theme.font(size: max(8, bodySize - 3)))
                    .foregroundStyle(theme.color(theme.palette.fgMuted))
                }
                .buttonStyle(.plain)
                .help("Copy this code block")
            }
            Text(code)
                .font(theme.monoFont(size: max(9, bodySize - 1)))
                .foregroundStyle(theme.color(theme.palette.fg))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.color(theme.palette.elevated).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.color(theme.palette.border).opacity(0.7), lineWidth: 0.5)
        )
    }

    private var bodySize: Double {
        theme.typography.size
    }

    private func headingSize(_ level: Int) -> Double {
        bodySize + 5 - Double(level - 1) * 1.2
    }
}
