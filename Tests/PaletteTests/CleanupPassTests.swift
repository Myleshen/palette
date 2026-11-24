import XCTest
import AppKit
import Foundation
import PaletteCore
import PalettePlatform

final class CleanupPassTests: XCTestCase {
    // MARK: - Hotkey collision ordering

    func testHotKeyPlanOrdersBuiltInsWebAppsBindingsCatalogue() throws {
        let key = "ctrl+alt+g"
        let requests = [
            HotKeyRequest(id: "launcher", label: "Launcher shortcut", keys: "opt+space"),
            HotKeyRequest(id: "web:abc", label: "Web GitHub", keys: key),
            HotKeyRequest(id: "binding-0", label: "Custom hotkey 1", keys: key),
            HotKeyRequest(id: "reload", label: "Reload Configuration", keys: key),
        ]
        let plan = HotKeyPlan.resolve(requests)
        XCTAssertNil(plan[0].unavailable)
        XCTAssertNil(plan[1].unavailable, "web apps outrank bindings")
        XCTAssertEqual(plan[2].unavailable, HotKeyUnavailable.usedBy("Web GitHub"))
        XCTAssertEqual(plan[3].unavailable, HotKeyUnavailable.usedBy("Web GitHub"))
    }

    func testHotKeyPlanKeepsFirstBuiltInAndMarksLaterOnes() {
        let plan = HotKeyPlan.resolve([
            HotKeyRequest(id: "launcher", label: "Launcher shortcut", keys: "opt+space"),
            HotKeyRequest(id: "clipboard", label: "Clipboard shortcut", keys: "OPT+SPACE"),
            HotKeyRequest(id: "terminal", label: "Terminal shortcut", keys: "not-a-key"),
        ])
        XCTAssertNil(plan[0].unavailable)
        XCTAssertEqual(plan[1].unavailable, HotKeyUnavailable.usedBy("Launcher shortcut"))
        XCTAssertEqual(plan[2].unavailable, HotKeyUnavailable.invalid)
    }

    func testHotKeyPlanIsStableAcrossRuns() {
        let requests = [
            HotKeyRequest(id: "launcher", label: "Launcher shortcut", keys: "opt+space"),
            HotKeyRequest(id: "web:abc", label: "Web app", keys: "opt+space"),
            HotKeyRequest(id: "binding-0", label: "Custom hotkey 1", keys: "opt+space"),
        ]
        XCTAssertEqual(HotKeyPlan.resolve(requests), HotKeyPlan.resolve(requests))
    }

    func testHotKeyRegistryReportsWinnerAndLoser() {
        HotKeyRegistry.replaceAll([
            HotKeyStatus(id: "web:abc", label: "Web app", keys: "opt+space"),
            HotKeyStatus(id: "binding-0", label: "Custom hotkey 1", keys: "opt+space",
                         unavailable: HotKeyUnavailable.usedBy("Web app")),
        ])
        XCTAssertNil(HotKeyRegistry.unavailable(id: "web:abc"))
        XCTAssertEqual(HotKeyRegistry.unavailable(id: "binding-0"), "Unavailable — used by Web app")
        XCTAssertNil(HotKeyRegistry.unavailable(id: "missing"))
    }

    // MARK: - Retention

    private func makeStore() throws -> (PaletteStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("palette.sqlite")
        let store = try PaletteStore(
            path: url.path,
            imagesDirectory: root.appendingPathComponent("clipboard")
        )
        return (store, root)
    }

    func testClipboardRetentionKeepsPinnedAndEnforcesImageCap() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date()
        let old = now.addingTimeInterval(-40 * 24 * 60 * 60)
        _ = try await store.insertClipboard(text: "old text", maxEntries: 100, at: old)
        _ = try await store.insertClipboard(text: "fresh text", maxEntries: 100, at: now)
        _ = try await store.insertClipboardImage(
            png: Data(repeating: 1, count: 10), thumbnail: nil,
            width: 2, height: 2, maxEntries: 100, at: now.addingTimeInterval(-2)
        )
        _ = try await store.insertClipboardImage(
            png: Data(repeating: 2, count: 10), thumbnail: nil,
            width: 2, height: 2, maxEntries: 100, at: now.addingTimeInterval(-1)
        )

        let report = try await store.maintain(
            clipboardRetentionDays: 30,
            maxImageBytes: 15,
            askRetentionDays: 30,
            now: now
        )
        XCTAssertEqual(report.clipboardRemoved, 2, "one expired text and the oldest image")
        let entries = try await store.clipboardEntries(limit: 100)
        XCTAssertTrue(entries.contains { $0.text == "fresh text" })
        XCTAssertEqual(entries.filter { $0.kind == .image }.count, 1)
        XCTAssertEqual(entries.first { $0.kind == .image }?.imageWidth, 2)

        // max_entries is still applied by the insert path.
        for index in 0..<5 {
            _ = try await store.insertClipboard(text: "cap \(index)", maxEntries: 3)
        }
        let capped = try await store.clipboardCount()
        XCTAssertEqual(capped, 3)
    }

    func testLargeTrimVacuumsOnlyOncePerLaunch() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        // Image bytes are files now, so fill the database with text to make the
        // freelist large enough for the vacuum gate.
        let old = Date().addingTimeInterval(-40 * 24 * 60 * 60)
        for index in 0..<30 {
            let text = String(
                repeating: Character(UnicodeScalar(65 + index)!),
                count: 190_000
            )
            _ = try await store.insertClipboard(text: text, maxEntries: 100, at: old)
        }
        let first = try await store.maintain(
            clipboardRetentionDays: 30, maxImageBytes: 0, askRetentionDays: 30
        )
        XCTAssertTrue(first.vacuumed)
        XCTAssertLessThan(first.bytesAfter, first.bytesBefore)
        let second = try await store.maintain(
            clipboardRetentionDays: 30, maxImageBytes: 0, askRetentionDays: 30
        )
        XCTAssertFalse(second.vacuumed, "VACUUM runs at most once per launch")
    }

    func testAskChatRetentionDeletesOldChatsAndMessages() async throws {        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date()
        let old = now.addingTimeInterval(-40 * 24 * 60 * 60)
        let stale = try await store.createAskChat(title: "stale", model: "m", at: old)
        _ = try await store.appendAskChatMessage(chatID: stale.id, role: .user, content: "old", at: old)
        let fresh = try await store.createAskChat(title: "fresh", model: "m", at: now)
        _ = try await store.appendAskChatMessage(chatID: fresh.id, role: .user, content: "new", at: now)

        let report = try await store.maintain(
            clipboardRetentionDays: 30,
            maxImageBytes: 200 * 1024 * 1024,
            askRetentionDays: 30,
            now: now
        )
        XCTAssertEqual(report.chatsRemoved, 1)
        let chats = try await store.askChats()
        XCTAssertEqual(chats.map(\.title), ["fresh"])
        let staleMessages = try await store.askChatMessages(chatID: stale.id)
        XCTAssertTrue(staleMessages.isEmpty, "cascade removes the stale chat's messages")
        let freshMessages = try await store.askChatMessages(chatID: fresh.id)
        XCTAssertEqual(freshMessages.count, 1)
    }

    // MARK: - Capture names

    func testSameSecondCaptureNamesNeverCollide() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let first = CaptureService.uniqueFileName(kind: "shot", ext: "png", in: directory, date: date)
        try Data().write(to: directory.appendingPathComponent(first))
        let second = CaptureService.uniqueFileName(kind: "shot", ext: "png", in: directory, date: date)

        XCTAssertNotEqual(first, second)
        print("same-second names: \(first) / \(second)")
        XCTAssertTrue(first.hasPrefix("shot-"), "milliseconds are part of the name")
        XCTAssertTrue(second.hasSuffix("-2.png"), "a taken name gets a numeric suffix")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(first).path))
    }

    @MainActor
    func testRecordingTargetChangeIsReportedForPersistence() {
        let service = CaptureService()
        var saved: CaptureConfig?
        service.onConfigChanged = { saved = $0 }
        service.config.recordingTarget = "display"
        service.config.recordingDisplay = 2
        XCTAssertEqual(saved?.recordingTarget, "display")
        XCTAssertEqual(saved?.recordingDisplay, 2)
    }

    // MARK: - Hotkey re-register

    func testFailedReRegisterKeepsThePreviousKey() throws {
        let manager = HotKeyManager(hotKeyID: 1)
        let blocker = HotKeyManager(hotKeyID: 2)
        defer {
            manager.unregister()
            blocker.unregister()
        }
        try manager.register("ctrl+alt+7")
        try blocker.register("ctrl+alt+8")
        XCTAssertThrowsError(try manager.register("ctrl+alt+8")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Kept"), "the error names the kept key")
        }
        XCTAssertEqual(manager.current?.display, "ctrl+alt+7")
    }

    // MARK: - Annotator

    @MainActor
    func testAnnotationSaveFailureLeavesNoTempFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-annotate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        image.unlockFocus()
        let editor = AnnotationEditor(image: image, url: nil)
        let destination = directory.appendingPathComponent("out.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: destination.path, contents: Data()))
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: destination.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: destination.path)
        }

        // The immutable destination makes replaceItemAt fail after the temp
        // was written.
        XCTAssertThrowsError(try editor.save(to: destination))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(leftovers.allSatisfy { !$0.hasSuffix(".tmp") }, "no hidden temp survives: \(leftovers)")
    }
}
