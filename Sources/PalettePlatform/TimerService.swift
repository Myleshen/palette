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

/// One running timer at a time, ticking once a second and reporting when it
/// finishes. Lives for the app's lifetime, so it keeps counting while the panel
/// is closed.
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
    private var askedForNotificationPermission = false

    public init() {}

    public func configure(sound: Bool, notifications: Bool) {
        soundEnabled = sound
        notificationsEnabled = notifications
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
        total = seconds
        self.label = label
        endsAt = Date().addingTimeInterval(seconds)
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let ticker { RunLoop.main.add(ticker, forMode: .common) }
        post()
    }

    public func stop() {
        stopTicker()
        endsAt = nil
        total = 0
        label = ""
        post()
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
        endsAt = nil
        total = 0
        label = ""
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
        Task {
            let center = UNUserNotificationCenter.current()
            if !askedForNotificationPermission {
                askedForNotificationPermission = true
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                if !granted {
                    Log.shared.warn("Timer finished, but notifications are not allowed", source: "timer")
                    return
                }
            }
            let content = UNMutableNotificationContent()
            content.title = "Timer finished"
            content.body = finished.isEmpty ? "Your timer is done." : "\(finished) is done."
            content.sound = nil
            let request = UNNotificationRequest(identifier: "palette.timer.\(UUID().uuidString)", content: content, trigger: nil)
            do {
                try await center.add(request)
            } catch {
                Log.shared.warn("Could not show timer notification: \(error.localizedDescription)", source: "timer")
            }
        }
    }
}
