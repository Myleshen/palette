import CoreGraphics
import Foundation
import XCTest
@testable import PaletteCore

/// The status panel is pure state plus one geometry rule, so both are pinned
/// without opening a window.
final class StatusPanelMenuTests: XCTestCase {
    private func sections(_ snapshot: StatusPanelSnapshot) -> [String: StatusPanelSection] {
        Dictionary(uniqueKeysWithValues: StatusPanelMenu.sections(snapshot).map { ($0.id, $0) })
    }

    private func row(
        _ command: StatusPanelCommand,
        in sections: [String: StatusPanelSection]
    ) -> StatusPanelRow? {
        sections.values.flatMap(\.rows).first { $0.command == command }
    }

    func testOnlyTheApplicableRecordingRowIsVisible() throws {
        let idle = sections(StatusPanelSnapshot(isRecording: false))
        XCTAssertNotNil(row(.capture(.startRecording), in: idle))
        XCTAssertNil(row(.capture(.stopRecording), in: idle))

        let recording = sections(StatusPanelSnapshot(isRecording: true, recordingElapsed: 65))
        XCTAssertNil(row(.capture(.startRecording), in: recording))
        XCTAssertEqual(
            row(.capture(.stopRecording), in: recording)?.title,
            "Stop Recording · 1:05"
        )
    }

    func testCaptureRowsFollowTheLastCapture() throws {
        let sections = sections(StatusPanelSnapshot(
            lastCapturePath: "/tmp/shot.png",
            lastScreenshotPath: "/tmp/shot.png"
        ))
        XCTAssertEqual(row(.capture(.copyLastPath), in: sections)?.enabled, true)
        XCTAssertEqual(row(.capture(.revealLastCapture), in: sections)?.enabled, true)
        // Screenshot-only rows appear; recording-only rows stay out.
        XCTAssertNotNil(row(.capture(.pinLastScreenshot), in: sections))
        XCTAssertNotNil(row(.capture(.copyTextFromLastScreenshot), in: sections))
        XCTAssertNotNil(row(.capture(.openLastScreenshotLink), in: sections))
        XCTAssertNil(row(.capture(.showLastRecording), in: sections))
    }

    func testLauncherPositionMarksTheCurrentChoice() throws {
        let sections = sections(StatusPanelSnapshot(launcherPosition: .center))
        XCTAssertEqual(row(.setPosition(.top), in: sections)?.checked, false)
        XCTAssertEqual(row(.setPosition(.center), in: sections)?.checked, true)
        XCTAssertEqual(row(.setPosition(.top), in: sections)?.enabled, true)
    }

    func testKeepAwakeDetailAndStopFollowTheSession() throws {
        let inactive = StatusPanelSnapshot()
        XCTAssertEqual(StatusPanelMenu.keepAwakeDetail(inactive), "Not keeping awake")
        XCTAssertEqual(
            row(.stopKeepAwake, in: sections(inactive))?.enabled,
            false
        )

        let timed = StatusPanelSnapshot(
            keepAwakeActive: true,
            keepAwakeRemaining: "42m"
        )
        XCTAssertEqual(StatusPanelMenu.keepAwakeDetail(timed), "Awake · 42m left")
        XCTAssertEqual(row(.stopKeepAwake, in: sections(timed))?.enabled, true)

        let indefinite = StatusPanelSnapshot(keepAwakeActive: true)
        XCTAssertEqual(StatusPanelMenu.keepAwakeDetail(indefinite), "Awake · indefinitely")
    }

    func testKeepAwakeClamshellIsCheckedAndArmedStateIsNamed() throws {
        let armed = StatusPanelSnapshot(
            keepAwakeClamshell: true,
            keepAwakeClamshellRequiresPower: true
        )
        let section = sections(armed)["keepAwake"]
        XCTAssertEqual(section?.rows.first?.command, .toggleClamshell)
        XCTAssertEqual(section?.rows.first?.checked, true)
        XCTAssertEqual(
            section?.rows.first?.title,
            "Clamshell (Lid Closed) — armed, inactive"
        )
    }

    func testDurationsCoverTheRequestedChoicesPlusIndefinite() throws {
        let titles = StatusPanelMenu.keepAwakeChoices.map(\.title)
        XCTAssertEqual(
            titles,
            [
                "For 15 Minutes", "For 30 Minutes", "For 1 Hour",
                "For 2 Hours", "For 4 Hours", "For 8 Hours", "Indefinitely",
            ]
        )
        XCTAssertNotNil(StatusPanelMenu.keepAwakeChoices.last)
        XCTAssertNil(StatusPanelMenu.keepAwakeChoices.last?.seconds)
    }

    func testFixedSectionsAreAlwaysPresent() throws {
        let sections = sections(StatusPanelSnapshot())
        XCTAssertNotNil(row(.openPalette, in: sections))
        XCTAssertEqual(row(.reloadConfig, in: sections)?.keyHint, "⌘R")
        XCTAssertNotNil(row(.refreshBitwarden, in: sections))
        XCTAssertNotNil(row(.settings, in: sections))
        XCTAssertNotNil(row(.openConfig, in: sections))
        XCTAssertNotNil(row(.openLog, in: sections))
        XCTAssertNotNil(row(.openProviders, in: sections))
        XCTAssertNotNil(row(.openThemes, in: sections))
        XCTAssertNotNil(row(.exportBackup, in: sections))
        XCTAssertEqual(row(.quit, in: sections)?.keyHint, "⌘Q")
        // No update nudge until a check finds a release.
        XCTAssertNil(row(.updatePalette, in: sections))
        XCTAssertNil(row(.releaseNotes, in: sections))
    }

    func testUpdateRowsAppearOnlyWithARelease() throws {
        let sections = sections(StatusPanelSnapshot(updateVersion: "2.19.0"))
        XCTAssertEqual(
            row(.updatePalette, in: sections)?.title,
            "Palette 2.19.0 available — Update…"
        )
        XCTAssertNotNil(row(.releaseNotes, in: sections))
    }

    func testDefaultSnapshotProducesRowsToDraw() throws {
        let built = StatusPanelMenu.sections(StatusPanelSnapshot())
        XCTAssertFalse(built.isEmpty)
        XCTAssertFalse(built.flatMap(\.rows).isEmpty)
        XCTAssertTrue(built.allSatisfy { !$0.rows.isEmpty })
        let titles = Set(built.flatMap(\.rows).map(\.title))
        for title in [
            "Open Palette", "Reload Configuration", "Settings…", "Quit Palette",
        ] {
            XCTAssertTrue(titles.contains(title), "missing row '\(title)'")
        }
    }

    // MARK: - Geometry

    func testFrameHangsRightAlignedUnderTheButton() {
        let anchor = CGRect(x: 900, y: 900, width: 30, height: 24)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let frame = StatusPanelLayout.frame(
            anchor: anchor,
            size: CGSize(width: 300, height: 200),
            screen: screen
        )
        XCTAssertEqual(frame.maxX, anchor.maxX)
        XCTAssertEqual(frame.maxY, anchor.minY - StatusPanelLayout.gap)
        XCTAssertEqual(frame.width, 300)
        XCTAssertEqual(frame.height, 200)
    }

    func testFrameStaysInsideTheScreenWhenTheButtonIsNearAnEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let right = StatusPanelLayout.frame(
            anchor: CGRect(x: 990, y: 900, width: 10, height: 24),
            size: CGSize(width: 300, height: 200),
            screen: screen
        )
        XCTAssertEqual(right.maxX, screen.maxX - StatusPanelLayout.margin)

        let low = StatusPanelLayout.frame(
            anchor: CGRect(x: 900, y: 20, width: 30, height: 24),
            size: CGSize(width: 300, height: 200),
            screen: screen
        )
        XCTAssertEqual(low.minY, screen.minY + StatusPanelLayout.margin)

        let left = StatusPanelLayout.frame(
            anchor: CGRect(x: 5, y: 900, width: 10, height: 24),
            size: CGSize(width: 300, height: 200),
            screen: screen
        )
        XCTAssertEqual(left.minX, screen.minX + StatusPanelLayout.margin)
    }

    func testTallContentIsCappedToTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let frame = StatusPanelLayout.frame(
            anchor: CGRect(x: 900, y: 580, width: 30, height: 24),
            size: CGSize(width: 300, height: 900),
            screen: screen
        )
        XCTAssertEqual(
            frame.height,
            screen.height - StatusPanelLayout.margin * 2
        )
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY + StatusPanelLayout.margin)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY - StatusPanelLayout.margin)
    }

    func testPanelHeightUsesContentCapsTallContentAndNeverCollapses() {
        let roomy = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        XCTAssertEqual(StatusPanelLayout.panelHeight(content: 420, screen: roomy), 420)

        let short = CGRect(x: 0, y: 0, width: 1000, height: 600)
        XCTAssertEqual(
            StatusPanelLayout.panelHeight(content: 900, screen: short),
            short.height - StatusPanelLayout.margin * 2 - StatusPanelLayout.gap
        )
        XCTAssertEqual(StatusPanelLayout.panelHeight(content: 0, screen: roomy), 1)
    }
}
