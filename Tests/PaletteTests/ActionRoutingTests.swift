import XCTest
@testable import PaletteProviders

/// The providers emit `.custom` actions by id and route them in `activate`.
/// This contract test reads the item builders' own source and fails when an id
/// is emitted that neither the provider nor the host handles — the shape of the
/// OCR bug where `ocr-copy` fell through to `default`.
final class ActionRoutingTests: XCTestCase {
    private struct Provider {
        var file: String
        var handled: Set<String>
        var hostHandled: Set<String>
    }

    private var providers: [Provider] {
        [
            Provider(
                file: "ClipboardProvider",
                handled: ClipboardProvider.handledCustomActions,
                hostHandled: ClipboardProvider.hostHandledCustomActions
            ),
            Provider(
                file: "SnippetProvider",
                handled: SnippetProvider.handledCustomActions,
                hostHandled: SnippetProvider.hostHandledCustomActions
            ),
            Provider(
                file: "CommandProvider",
                handled: CommandProvider.handledCustomActions,
                hostHandled: CommandProvider.hostHandledCustomActions
            ),
            Provider(
                file: "ProjectProvider",
                handled: ProjectProvider.handledCustomActions,
                hostHandled: ProjectProvider.hostHandledCustomActions
            ),
            Provider(
                file: "GitHubProvider",
                handled: GitHubProvider.handledCustomActions,
                hostHandled: GitHubProvider.hostHandledCustomActions
            ),
            Provider(
                file: "BitwardenProvider",
                handled: BitwardenProvider.handledCustomActions,
                hostHandled: BitwardenProvider.hostHandledCustomActions
            ),
            Provider(
                file: "ZellijProvider",
                handled: ZellijProvider.handledCustomActions,
                hostHandled: ZellijProvider.hostHandledCustomActions
            ),
            Provider(
                file: "PinProvider",
                handled: PinProvider.handledCustomActions,
                hostHandled: PinProvider.hostHandledCustomActions
            ),
        ]
    }

    func testEveryCustomActionIDFromItemBuildersIsRouted() throws {
        for provider in providers {
            let emitted = try customActionIDs(source: source(for: provider.file))
            XCTAssertFalse(emitted.isEmpty, "\(provider.file) emits no custom actions; the scan broke")
            let unrouted = emitted.subtracting(provider.handled).subtracting(provider.hostHandled)
            XCTAssertTrue(
                unrouted.isEmpty,
                "\(provider.file) emits custom actions nobody routes: \(unrouted.sorted())"
            )
            XCTAssertTrue(
                provider.handled.isDisjoint(with: provider.hostHandled),
                "\(provider.file) claims one id for both the provider and the host"
            )
        }
    }

    private func source(for file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PaletteTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
        let url = root
            .appendingPathComponent("Sources/PaletteProviders")
            .appendingPathComponent("\(file).swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Reads each `PaletteAction(…)` call as a balanced expression, so titles
    /// containing brackets (`Copy Text (OCR)`) do not truncate the scan.
    private func customActionIDs(source: String) -> Set<String> {
        var ids: Set<String> = []
        var cursor = source.startIndex
        while let opening = source.range(of: "PaletteAction(", range: cursor..<source.endIndex) {
            var index = opening.upperBound
            var depth = 1
            var inString = false
            var escaped = false
            while index < source.endIndex, depth > 0 {
                let character = source[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                } else if character == "\"" {
                    inString = true
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                }
                index = source.index(after: index)
            }
            let body = source[opening.upperBound..<index]
            if body.contains("kind: .custom"), let id = firstQuotedID(in: body) {
                ids.insert(id)
            }
            cursor = index
        }
        return ids
    }

    private func firstQuotedID(in body: Substring) -> String? {
        guard let idRange = body.range(of: "id:") else { return nil }
        let rest = body[idRange.upperBound...]
        guard let open = rest.firstIndex(of: "\""),
              let close = rest[rest.index(after: open)...].firstIndex(of: "\"") else { return nil }
        return String(rest[rest.index(after: open)..<close])
    }
}
