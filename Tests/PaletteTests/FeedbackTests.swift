import XCTest
import Foundation
import PaletteCore
import PalettePlatform
@testable import PaletteProviders
import PaletteRuntime
@testable import PaletteApp

final class FeedbackTests: XCTestCase {
    private final class StubProvider: PaletteProvider, @unchecked Sendable {
        let descriptor: ProviderDescriptor
        let items: [PaletteItem]
        let delay: UInt64

        init(id: String, items: [PaletteItem] = [], delay: UInt64 = 0) {
            descriptor = ProviderDescriptor(id: id, name: id, trigger: id, isGlobal: true)
            self.items = items
            self.delay = delay
        }

        func search(_ request: SearchRequest) async throws -> [PaletteItem] {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            return items
        }
    }

    // MARK: - Pastes

    func testPasteFallbackStatusOnlyWhenNothingWasDelivered() {
        XCTAssertNil(PasteOutcome.pasted.fallbackStatus)
        XCTAssertEqual(PasteOutcome.copiedOnly.fallbackStatus, "Copied — paste with ⌘V")
        XCTAssertEqual(PasteOutcome.noTarget.fallbackStatus, "Copied — paste with ⌘V")
        XCTAssertEqual(
            PasteOutcome.needsAccessibility.fallbackStatus,
            "Copied — enable Accessibility to paste automatically."
        )
    }

    // MARK: - Opening paths

    func testOpenPathPlanCreatesOnlyWhenTheActionOptsIn() {
        XCTAssertEqual(OpenPathPlan.plan(path: "/tmp/a", exists: true, create: false), .open)
        XCTAssertEqual(OpenPathPlan.plan(path: "/tmp/a", exists: false, create: true), .createAndOpen)
        XCTAssertEqual(
            OpenPathPlan.plan(path: "/tmp/a", exists: false, create: false),
            .missing("No longer exists at /tmp/a")
        )
        XCTAssertTrue(OpenPathPlan.createAndOpen.createsFile)
        XCTAssertFalse(OpenPathPlan.open.createsFile)
    }

    func testFailedOpenKeepsThePanelAndSucceededHidesIt() {
        XCTAssertTrue(OpenAttempt.succeeded.hidesPanel)
        XCTAssertFalse(OpenAttempt.failed("Could not find app").hidesPanel)
    }

    // MARK: - Opening links

    func testBrowserOpenPlanUsesAnInstalledBrowser() {
        XCTAssertEqual(BrowserOpenPlan.plan(browser: "Helium", installed: true), .browser("Helium"))
        XCTAssertEqual(BrowserOpenPlan.plan(browser: " Helium ", installed: true), .browser("Helium"))
    }

    func testBrowserOpenPlanFallsBackWhenTheBrowserIsMissing() {
        XCTAssertEqual(BrowserOpenPlan.plan(browser: "Helium", installed: false), .fallback("Helium"))
        XCTAssertEqual(BrowserOpenPlan.plan(browser: nil, installed: false), .systemDefault)
        XCTAssertEqual(BrowserOpenPlan.plan(browser: "  ", installed: true), .systemDefault)
    }

    func testURLOpenOutcomeStatusOnlyKeepsThePanelForAFallbackOrFailure() {
        XCTAssertTrue(URLOpenOutcome.opened.hidesPanel)
        XCTAssertNil(URLOpenOutcome.opened.status)

        let fallback = URLOpenOutcome.openedInDefault(requested: "Helium")
        XCTAssertFalse(fallback.hidesPanel)
        XCTAssertEqual(fallback.status, "Could not open the link in Helium — opened in your default browser")

        let tab = URLOpenOutcome.openedAsTab(browser: "Helium")
        XCTAssertFalse(tab.hidesPanel)
        XCTAssertEqual(tab.status, "Could not open a web-app window in Helium — opened a browser tab instead")

        let failed = URLOpenOutcome.failed("no application accepted it")
        XCTAssertFalse(failed.hidesPanel)
        XCTAssertEqual(failed.status, "Could not open the link — no application accepted it")
    }

    // MARK: - Timer

    func testTimerFeedbackText() {
        XCTAssertEqual(TimerProvider.feedback(for: "start:1500"), "Timer started · 25 minutes")
        XCTAssertEqual(TimerProvider.feedback(for: "stop"), "Timer stopped")
        XCTAssertNil(TimerProvider.feedback(for: "start:0"))
        XCTAssertNil(TimerProvider.feedback(for: "something-else"))
    }

    // MARK: - Rows without a route

    func testNoActionHintForARowWithoutActions() {
        let item = PaletteItem(id: "empty", title: "Nothing", providerID: "test")
        XCTAssertNil(item.returnRoute)
        XCTAssertEqual(item.noActionHint, "Nothing to run on this row")
    }

    // MARK: - Global deadline

    func testGlobalSearchReturnsFastProvidersWhenOneHangs() async {
        let fast = StubProvider(id: "fast", items: [
            PaletteItem(id: "fast:1", title: "Fast", providerID: "fast"),
        ])
        // Longer than the test's deadline, so it can only finish after the race.
        let slow = StubProvider(id: "slow", items: [
            PaletteItem(id: "slow:1", title: "Slow", providerID: "slow"),
        ], delay: 5_000_000_000)
        let registry = ProviderRegistry(
            providers: [fast, slow],
            prefix: "/",
            global: ["fast", "slow"],
            globalDeadline: .milliseconds(100)
        )

        let result = await registry.search(raw: "")

        XCTAssertEqual(result.items.map { $0.id }, ["fast:1"])
        XCTAssertEqual(result.timedOutProviders, ["slow"])
    }

    /// A provider blocked in non-suspending work cannot be cancelled, so the
    /// race must not await it: the search returns at the deadline.
    func testGlobalDeadlineBoundsAProviderThatNeverSuspends() async {
        final class BlockingProvider: PaletteProvider, @unchecked Sendable {
            let descriptor = ProviderDescriptor(id: "blocked", name: "blocked", trigger: "blocked", isGlobal: true)

            // Synchronous on purpose: cancellation cannot interrupt it.
            private func block() {
                Thread.sleep(forTimeInterval: 1)
            }

            func search(_ request: SearchRequest) async throws -> [PaletteItem] {
                block()
                return [PaletteItem(id: "blocked:1", title: "Blocked", providerID: "blocked")]
            }
        }

        let fast = StubProvider(id: "fast", items: [
            PaletteItem(id: "fast:1", title: "Fast", providerID: "fast"),
        ])
        let registry = ProviderRegistry(
            providers: [fast, BlockingProvider()],
            prefix: "/",
            global: ["fast", "blocked"],
            globalDeadline: .milliseconds(50)
        )

        let started = Date()
        let result = await registry.search(raw: "")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.5)
        XCTAssertEqual(result.items.map { $0.id }, ["fast:1"])
        XCTAssertEqual(result.timedOutProviders, ["blocked"])
    }

    // MARK: - Scratchpad saves

    func testScratchpadSaveFailureIsReportedWithItsReason() {
        let error = CocoaError(.fileWriteNoPermission)
        let status = ScratchpadSave.failureStatus(for: error)

        XCTAssertTrue(status.hasPrefix("Could not save the note:"))
        XCTAssertTrue(status.contains(error.localizedDescription))
    }
}
