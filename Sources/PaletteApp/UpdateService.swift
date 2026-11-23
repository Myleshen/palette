import Combine
import Foundation
import PaletteCore
import PalettePlatform

/// Background release check. It never installs anything: the menu item it
/// feeds runs the Homebrew command in the embedded terminal.
@MainActor
final class UpdateService: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case failed(String)
    }

    struct Release: Equatable {
        let version: String
        let url: URL
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var available: Release?
    @Published private(set) var lastChecked: Date?

    /// Fires whenever `available` changes so the status menu can be rebuilt.
    var onAvailabilityChange: (() -> Void)?

    private enum Key {
        static let lastCheck = "updates.lastCheck"
        static let notifiedVersion = "updates.notifiedVersion"
        static let latestVersion = "updates.latestVersion"
        static let latestURL = "updates.latestURL"
        static let failures = "updates.failures"
        static let retryAfter = "updates.retryAfter"
    }

    private enum UpdateError: Error {
        case http(Int)
        case malformed
    }

    private let defaults: UserDefaults
    private let currentVersion: String
    private var automaticEnabled = true
    private var failures = 0
    private var isChecking = false

    init(defaults: UserDefaults = .standard, currentVersion: String? = nil) {
        self.defaults = defaults
        self.currentVersion = currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    /// Restores the cached answer immediately, then checks only when the daily
    /// window and the failure backoff both allow it.
    func start(automatic: Bool) {
        automaticEnabled = automatic
        lastChecked = defaults.object(forKey: Key.lastCheck) as? Date
        failures = defaults.integer(forKey: Key.failures)
        if let version = defaults.string(forKey: Key.latestVersion),
           let raw = defaults.string(forKey: Key.latestURL),
           let url = URL(string: raw),
           UpdatePolicy.isNewer(version, than: currentVersion) {
            available = Release(version: version, url: url)
        }
        onAvailabilityChange?()
        checkAutomatically()
    }

    func setAutomatic(_ enabled: Bool) {
        automaticEnabled = enabled
        if enabled { checkAutomatically() }
    }

    /// Silent by design: failures leave the last known answer on screen.
    func checkAutomatically() {
        guard automaticEnabled, !isChecking else { return }
        let now = Date()
        let retryAfter = defaults.object(forKey: Key.retryAfter) as? Date
        guard UpdatePolicy.isCheckDue(lastCheck: lastChecked, now: now),
              UpdatePolicy.isRetryAllowed(retryAfter: retryAfter, now: now) else { return }
        run(automatic: true, now: now)
    }

    /// The Settings button: ignores the daily window and the backoff, and
    /// reports a failure instead of hiding it.
    func checkNow() {
        guard !isChecking else { return }
        run(automatic: false, now: Date())
    }

    private func run(automatic: Bool, now: Date) {
        guard SemanticVersion(currentVersion) != nil else {
            if !automatic { status = .failed("Couldn't read the installed version.") }
            return
        }
        isChecking = true
        status = .checking
        Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await Self.fetchLatest()
                self.finish(release: release, checkedAt: now)
            } catch {
                self.fail(error, automatic: automatic, now: now)
            }
        }
    }

    private func finish(release: ReleaseInfo, checkedAt: Date) {
        isChecking = false
        lastChecked = checkedAt
        defaults.set(checkedAt, forKey: Key.lastCheck)
        failures = 0
        defaults.set(0, forKey: Key.failures)
        defaults.removeObject(forKey: Key.retryAfter)

        guard let current = SemanticVersion(currentVersion) else { return }
        if release.version > current {
            let version = release.version.description
            available = Release(version: version, url: release.url)
            defaults.set(version, forKey: Key.latestVersion)
            defaults.set(release.url.absoluteString, forKey: Key.latestURL)
            status = .available(version)
            if UpdatePolicy.shouldNotify(
                version: version,
                lastNotified: defaults.string(forKey: Key.notifiedVersion)
            ) {
                defaults.set(version, forKey: Key.notifiedVersion)
                SystemNotification.postIfPermitted(
                    title: "Palette \(version) is available",
                    body: "Update with Homebrew from the Palette menu.",
                    identifier: "palette.update.\(version)"
                )
            }
        } else {
            available = nil
            status = .upToDate
            defaults.removeObject(forKey: Key.latestVersion)
            defaults.removeObject(forKey: Key.latestURL)
        }
        onAvailabilityChange?()
    }

    private func fail(_ error: Error, automatic: Bool, now: Date) {
        isChecking = false
        failures += 1
        defaults.set(failures, forKey: Key.failures)
        defaults.set(
            now.addingTimeInterval(UpdatePolicy.retryDelay(failures: failures)),
            forKey: Key.retryAfter
        )
        let message = Self.describe(error)
        status = automatic ? .idle : .failed(message)
        Log.shared.warn("Update check failed: \(message)", source: "updates")
    }

    private static func fetchLatest() async throws -> ReleaseInfo {
        var request = URLRequest(url: UpdatePolicy.releasesAPI)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Palette", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.malformed }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }
        guard let release = UpdatePolicy.parseRelease(data) else { throw UpdateError.malformed }
        return release
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case UpdateError.http(403), UpdateError.http(429):
            return "GitHub is rate-limiting update checks. Try again later."
        case UpdateError.http(let status):
            return "GitHub returned HTTP \(status)."
        case UpdateError.malformed:
            return "GitHub's answer didn't look like a release."
        case let urlError as URLError:
            return urlError.code == .notConnectedToInternet || urlError.code == .networkConnectionLost
                ? "You're offline; couldn't check for updates."
                : "Couldn't reach GitHub: \(urlError.localizedDescription)"
        default:
            return "Couldn't check for updates: \(error.localizedDescription)"
        }
    }
}
