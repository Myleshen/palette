import XCTest

/// Settings search is a hand-maintained index; a new card that has no entry is
/// unreachable from ⌘F. This scans the source rather than the running app.
final class SettingsSearchCoverageTests: XCTestCase {
    /// Informational cards with no `anchor` cannot be jumped to. Keep this tiny.
    private let decorativeCards: Set<String> = [
        "Glass and materials", // explains theme fields; it has no anchor on purpose
    ]

    private struct Destination {
        var title: String
        var keywords: String
        var tab: String
    }

    private func sourceLines() throws -> [String] {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PaletteApp/SettingsView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The quoted value after `marker` on one line.
    private func quoted(_ line: String, after marker: String) -> String? {
        guard let start = line.range(of: marker) else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private func isCode(_ line: String) -> Bool {
        !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    private func destinations(_ lines: [String]) -> [Destination] {
        lines.filter(isCode).compactMap { line in
            guard line.contains(".init(title: \""),
                  let title = quoted(line, after: ".init(title: \""),
                  let tab = tabCase(line)
            else { return nil }
            return Destination(
                title: title,
                keywords: quoted(line, after: "keywords: \"") ?? "",
                tab: tab
            )
        }
    }

    /// The case name after `tab: .` in a destination line.
    private func tabCase(_ line: String) -> String? {
        guard let start = line.range(of: "tab: .") else { return nil }
        let name = line[start.upperBound...].prefix { $0.isLetter || $0.isNumber }
        return name.isEmpty ? nil : String(name)
    }

    func testEveryCardTitleHasASearchDestination() throws {
        let lines = try sourceLines()
        let cards = lines.filter(isCode).compactMap { line -> String? in
            guard line.contains("card(\"") else { return nil }
            return quoted(line, after: "card(\"")
        }
        XCTAssertGreaterThan(cards.count, 20, "the card scan found too few titles to be meaningful")

        let entries = destinations(lines)
        for card in cards where !decorativeCards.contains(card) {
            let covered = entries.contains {
                $0.title.localizedCaseInsensitiveContains(card)
                    || $0.keywords.localizedCaseInsensitiveContains(card)
            }
            XCTAssertTrue(covered, "\"\(card)\" has no Settings search destination")
        }
    }

    func testEveryPaneTitleHasAReachableDestination() throws {
        let lines = try sourceLines()

        // The title switch sits between `var title: String {` and `var icon`.
        guard let titleStart = lines.firstIndex(where: { $0.contains("var title: String {") }),
              let titleEnd = lines[titleStart...].firstIndex(where: { $0.contains("var icon: String {") })
        else {
            return XCTFail("could not find SettingsTab.title in SettingsView.swift")
        }
        let panes = lines[titleStart..<titleEnd].compactMap { line -> String? in
            guard line.contains("case ."), line.contains("return \"") else { return nil }
            return quoted(line, after: "return \"")
        }
        XCTAssertGreaterThan(panes.count, 10, "the pane scan found too few titles to be meaningful")

        let entries = destinations(lines)
        for pane in panes {
            let covered = entries.contains {
                $0.tab.caseInsensitiveCompare(pane) == .orderedSame
                    || $0.title.localizedCaseInsensitiveContains(pane)
                    || $0.keywords.localizedCaseInsensitiveContains(pane)
            }
            XCTAssertTrue(covered, "pane \"\(pane)\" has no Settings search destination")
        }
    }
}
