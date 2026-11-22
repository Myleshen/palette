import AppKit
import Foundation
import UserNotifications

public struct TimerSnapshot: Sendable {
    public var isRunning: Bool
    public var total: TimeInterval
    public var remaining: TimeInterval
    public var label: String
    public var endsAt: Date?
}

/// What `adopt` found in `timer.json` at launch.
public enum TimerAdoption: Equatable, Sendable {
    /// The deadline is still ahead; the countdown and its ticker are running.
    case running
    /// The deadline passed while Palette was closed.
    case expired(label: String)
}

/// One running timer at a time, ticking once a second and reporting when it
/// finishes. Lives for the app's lifetime, so it keeps counting while the panel
/// is closed. A copy is kept in `stateDir/timer.json`, so quitting does not
/// lose the timer, and a system notification is scheduled for the deadline so
/// it fires even when Palette is not running.
@MainActor
public final class TimerService {
    public private(set) var soundEnabled = true
    public private(set) var notificationsEnabled = true
    /// Posted on every tick and when the timer finishes.
    public static let tickNotification = Notification.Name("palette.timer.tick")

    private var endsAt: Date?
    private var total: TimeInterval = 0
    private var label = ""
    private var ticker: Timer?
    private var notificationID: String?
    private var stateURL: URL?

    public init() {}

    public func configure(sound: Bool, notifications: Bool) {
        soundEnabled = sound
        notificationsEnabled = notifications
    }

    /// Loads `stateDir/timer.json` once at launch. A timer still in the future
    /// resumes; one whose deadline passed while Palette was closed announces
    /// itself once and is cleared.
    @discardableResult
    public func adopt(stateDir: URL) -> TimerAdoption? {
        let url = stateDir.appendingPathComponent("timer.json")
        stateURL = url
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(PersistedTimer.self, from: data) else {
            return nil
        }
        let deadline = Date(timeIntervalSince1970: stored.endsAt)
        if deadline.timeIntervalSinceNow > 0 {
            total = stored.total
            label = stored.label
            endsAt = deadline
            notificationID = "palette.timer.\(stored.id)"
            startTicker()
            scheduleNotification(id: notificationID!, at: deadline, label: stored.label)
            post()
            return .running
        }
        // The app was closed when it expired: keep the chime and banner, drop
        // any pending/delivered copy of the scheduled notification.
        cancelNotification("palette.timer.\(stored.id)")
        clearState()
        announce(stored.label)
        return .expired(label: stored.label)
    }

    public func snapshot() -> TimerSnapshot {
        guard let endsAt else {
            return TimerSnapshot(isRunning: false, total: 0, remaining: 0, label: "", endsAt: nil)
        }
        return TimerSnapshot(
            isRunning: true,
            total: total,
            remaining: max(0, endsAt.timeIntervalSinceNow),
            label: label,
            endsAt: endsAt
        )
    }

    public func start(seconds: TimeInterval, label: String) {
        guard seconds > 0 else { return }
        stopTicker()
        cancelNotification(notificationID)
        total = seconds
        self.label = label
        endsAt = Date().addingTimeInterval(seconds)
        let id = UUID().uuidString
        notificationID = "palette.timer.\(id)"
        saveState(id: id)
        startTicker()
        scheduleNotification(id: notificationID!, at: endsAt!, label: label)
        post()
    }

    public func stop() {
        stopTicker()
        cancelNotification(notificationID)
        endsAt = nil
        total = 0
        label = ""
        clearState()
        post()
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let ticker { RunLoop.main.add(ticker, forMode: .common) }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let endsAt else { return }
        if endsAt.timeIntervalSinceNow <= 0 {
            finish()
        } else {
            post()
        }
    }

    private func finish() {
        let finished = label
        stopTicker()
        // The scheduled copy lands at the same moment; drop it so a running
        // app shows one banner/one chime from `announce` only.
        cancelNotification(notificationID)
        endsAt = nil
        total = 0
        label = ""
        notificationID = nil
        clearState()
        post()
        announce(finished)
    }

    private func post() {
        NotificationCenter.default.post(name: Self.tickNotification, object: nil)
    }

    private func announce(_ finished: String) {
        if soundEnabled {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
        guard notificationsEnabled else { return }
        SystemNotification.post(
            title: "Timer finished",
            body: finished.isEmpty ? "Your timer is done." : "\(finished) is done."
        )
    }

    // MARK: - Persistence

    /// `endsAt` is Unix epoch seconds, so the file survives clock formats.
    private struct PersistedTimer: Codable {
        var id: String
        var endsAt: Double
        var total: Double
        var label: String
    }

    private func saveState(id: String) {
        guard let stateURL, let endsAt else { return }
        let stored = PersistedTimer(
            id: id,
            endsAt: endsAt.timeIntervalSince1970,
            total: total,
            label: label
        )
        do {
            let data = try JSONEncoder().encode(stored)
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: stateURL, options: .atomic)
        } catch {
            Log.shared.warn("Timer state could not be saved: \(error.localizedDescription)", source: "timer")
        }
    }

    private func clearState() {
        guard let stateURL else { return }
        try? FileManager.default.removeItem(at: stateURL)
    }

    // MARK: - System notification

    private func scheduleNotification(id: String, at deadline: Date, label: String) {
        guard notificationsEnabled, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let remaining = max(1, deadline.timeIntervalSinceNow)
        let body = label.isEmpty ? "Your timer is done." : "\(label) is done."
        Task.detached(priority: .utility) {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            let content = UNMutableNotificationContent()
            content.title = "Timer finished"
            content.body = body
            // Palette may be closed, so the scheduled copy carries its own sound.
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            do {
                try await center.add(request)
                Log.shared.info("Timer notification scheduled for \(Int(remaining))s", source: "timer")
            } catch {
                Log.shared.warn("Timer notification could not be scheduled: \(error.localizedDescription)", source: "timer")
            }
        }
    }

    private func cancelNotification(_ id: String?) {
        guard let id, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}
