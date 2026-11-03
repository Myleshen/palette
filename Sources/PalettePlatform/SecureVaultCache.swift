import CryptoKit
import Foundation
import PaletteCore
import Security

/// Encrypted, six-hour cache for Bitwarden vault listings.
///
/// The vault payload is personal data, so it never lands on disk in plaintext.
/// A random key lives in the login Keychain and the cached JSON is sealed with
/// AES-GCM. The cache is scoped to a CLI profile so test and real vaults cannot
/// read each other's data.
public enum SecureVaultCache {
    public static let ttl: TimeInterval = 6 * 60 * 60

    public struct Snapshot: Sendable {
        public var date: Date
        public var email: String?
        public var data: Data
    }

    private struct Envelope: Codable {
        var saved: Double
        var email: String?
        var data: Data
    }

    public static func scope(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let profile = environment["BITWARDENCLI_APPDATA_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = profile.isEmpty ? "default" : profile
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func load(scope: String, now: Date = Date()) -> Snapshot? {
        let url = fileURL(scope: scope)
        guard let sealed = try? Data(contentsOf: url),
              let key = cacheKey(),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let clear = try? AES.GCM.open(box, using: key),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: clear) else {
            return nil
        }
        let saved = Date(timeIntervalSince1970: envelope.saved)
        guard now.timeIntervalSince(saved) < ttl, now.timeIntervalSince(saved) >= 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return Snapshot(date: saved, email: envelope.email, data: envelope.data)
    }

    public static func save(data: Data, email: String?, scope: String) {
        guard let key = cacheKey(), !data.isEmpty else { return }
        let envelope = Envelope(saved: Date().timeIntervalSince1970, email: email, data: data)
        guard let clear = try? JSONEncoder().encode(envelope),
              let sealed = try? AES.GCM.seal(clear, using: key).combined else { return }
        let url = fileURL(scope: scope)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try sealed.write(to: url, options: Data.WritingOptions.atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.shared.warn("Could not save the Bitwarden cache: \(error.localizedDescription)", source: "bitwarden")
        }
    }

    public static func remove(scope: String) {
        try? FileManager.default.removeItem(at: fileURL(scope: scope))
    }

    private static func directory() -> URL {
        PalettePaths.resolve().cacheDir.appendingPathComponent("Bitwarden", isDirectory: true)
    }

    private static func fileURL(scope: String) -> URL {
        directory().appendingPathComponent(String(scope.prefix(32)) + ".bin")
    }

    private static func cacheKey() -> SymmetricKey? {
        let url = directory().appendingPathComponent("key.bin")
        if let data = try? Data(contentsOf: url), data.count == 32 {
            return SymmetricKey(data: data)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let data = Data(bytes)
        do {
            try FileManager.default.createDirectory(
                at: directory(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: url, options: Data.WritingOptions.atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.shared.warn("Could not create the cache key: \(error.localizedDescription)", source: "bitwarden")
            return nil
        }
        return SymmetricKey(data: data)
    }
}
