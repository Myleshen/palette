import Foundation
import UserNotifications

/// System notifications (Notification Center banners).
///
/// Permission is asked when the ask window opens — a moment the user is looking
/// at the app — not at launch and not while an answer lands in the background,
/// where a prompt would swallow the notification it was meant to show.
public enum SystemNotification {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var askedForPermission = false
    nonisolated(unsafe) private static var allowed = false

    /// Whether the system has granted banners. False until `prepare()` resolved.
    public static var isAllowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowed
    }

    public static func prepare() {
        // Tests and `swift run` live outside an app bundle; the notification
        // centre throws for those and there is no UI to show anyway.
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        guard claimPermissionRequest() else { return }
        Task.detached(priority: .utility) {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            setAllowed(granted)
            if granted {
                Log.shared.info("Notifications allowed", source: "notify")
            } else {
                Log.shared.info("Notifications not allowed; answers still chime and badge the Dock", source: "notify")
            }
        }
    }

    public static func post(title: String, body: String, identifier: String = UUID().uuidString) {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        guard !alreadyAsked() || isAllowed else { return }
        Task.detached(priority: .utility) {
            let center = UNUserNotificationCenter.current()
            if claimPermissionRequest() {
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                setAllowed(granted)
                guard granted else { return }
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // The caller plays its own sound; a second one would double up.
            content.sound = nil
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            do {
                try await center.add(request)
                Log.shared.info("Notification posted: \(title)", source: "notify")
            } catch {
                Log.shared.warn("Could not show a notification: \(error.localizedDescription)", source: "notify")
            }
        }
    }

    private static func alreadyAsked() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return askedForPermission
    }

    private static func claimPermissionRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !askedForPermission else { return false }
        askedForPermission = true
        return true
    }

    private static func setAllowed(_ value: Bool) {
        lock.lock()
        allowed = value
        lock.unlock()
    }
}
