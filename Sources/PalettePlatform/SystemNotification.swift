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
    /// When the permission state was last read from the system.
    nonisolated(unsafe) private static var lastCheck = Date.distantPast
    /// Denying and then enabling notifications in System Settings must take
    /// effect without a relaunch, but every answer should not pay for a
    /// notification-center round trip.
    private static let checkInterval: TimeInterval = 1

    /// Whether the system has granted banners. False until `prepare()` resolved.
    /// This is the cached value; `post` re-reads the live setting first.
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
        // Native by necessity: macOS owns the notification permission prompt.
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
        Task.detached(priority: .utility) {
            let center = UNUserNotificationCenter.current()
            if claimPermissionRequest() {
                // Native by necessity: macOS owns the notification permission prompt.
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                setAllowed(granted)
                guard granted else { return }
            } else if !(await permissionAllowed(center)) {
                return
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

    /// Posts only when the user already granted notifications. A background
    /// release check must never open a permission prompt; the ask window still
    /// owns that first request.
    public static func postIfPermitted(title: String, body: String, identifier: String) {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        Task.detached(priority: .utility) {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            let granted = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
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

    /// The live permission state, re-read at most once a second.
    private static func permissionAllowed(_ center: UNUserNotificationCenter) async -> Bool {
        let state = permissionCacheState()
        guard state.stale else { return state.allowed }

        let settings = await center.notificationSettings()
        let granted = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        storePermission(granted)
        return granted
    }

    /// Claims the stale check before the await so two answers in one second
    /// share one notification-center round trip.
    private static func permissionCacheState() -> (stale: Bool, allowed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let stale = Date().timeIntervalSince(lastCheck) >= checkInterval
        if stale { lastCheck = Date() }
        return (stale, allowed)
    }

    private static func storePermission(_ granted: Bool) {
        lock.lock()
        allowed = granted
        lock.unlock()
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
