import XCTest
import AppKit
@testable import PalettePlatform

@MainActor
final class PasteboardTests: XCTestCase {
    func testConcealedPasteSchedulesAClear() async throws {
        let secret = "palette-secret-\(UUID().uuidString)"
        let service = PasteboardService()
        service.requestsAccessibility = false
        service.paste(text: secret, concealed: true, clearAfterMs: 60, into: nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), secret)

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotEqual(NSPasteboard.general.string(forType: .string), secret)
    }

    func testAnUnrelatedLaterClipboardValueIsNotCleared() async throws {
        let service = PasteboardService()
        service.requestsAccessibility = false
        service.paste(text: "old-secret", concealed: true, clearAfterMs: 60, into: nil)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("later-value", forType: .string)

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "later-value")
    }

    func testAPasteWritesTheClipboardOnce() {
        let service = PasteboardService()
        service.requestsAccessibility = false
        service.accessibilityTrustedOverride = true

        let outcome = service.paste(text: "single-write", into: nil)

        XCTAssertEqual(service.writes, 1)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "single-write")
        XCTAssertEqual(outcome, .noTarget)
    }

    func testACopyOnlyTargetWritesOnceAndPostsNoKeystroke() {
        let service = PasteboardService()
        service.requestsAccessibility = false
        service.accessibilityTrustedOverride = true

        let outcome = service.paste(text: "copy-only", into: NSRunningApplication.current, route: .copyOnly)

        XCTAssertEqual(service.writes, 1)
        XCTAssertEqual(outcome, .copiedOnly)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "copy-only")
    }

    func testMissingAccessibilityIsReportedAfterTheWrite() {
        let service = PasteboardService()
        service.requestsAccessibility = false
        service.accessibilityTrustedOverride = false

        let outcome = service.paste(text: "untrusted", into: nil)

        XCTAssertEqual(service.writes, 1)
        XCTAssertEqual(outcome, .needsAccessibility)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "untrusted")
    }
}
