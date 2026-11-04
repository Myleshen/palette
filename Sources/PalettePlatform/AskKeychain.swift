import CryptoKit
import Foundation
import PaletteCore
import Security

/// API keys for `/ask` live in a user-only encrypted file, not the login
/// Keychain. Ad-hoc development builds change signature constantly, which made
/// Keychain ACL prompts appear on every rebuild. The file is encrypted with a
/// random 32-byte key stored beside it; both are mode 0600. Nothing in this type
/// returns a saved key to the Settings UI, and no key enters config.toml or logs.
public enum AskKeychain {
    private static var configDirectory: URL {
        PalettePaths.resolve().configDir
    }

    private static var keysURL: URL {
        configDirectory.appendingPathComponent("ask-keys.bin")
    }

    private static var keyURL: URL {
        configDirectory.appendingPathComponent("ask-key.bin")
    }

    private static func account(for endpoint: AskEndpoint) -> String {
        "api-key-\(endpoint.rawValue)"
    }

    public static func hasStoredKey(for endpoint: AskEndpoint) -> Bool {
        loadStored(endpoint: endpoint) != nil
    }

    public static func save(_ key: String, for endpoint: AskEndpoint) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var values = loadAll()
        values[account(for: endpoint)] = trimmed
        return writeAll(values)
    }

    public static func delete(endpoint: AskEndpoint) {
        var values = loadAll()
        values.removeValue(forKey: account(for: endpoint))
        _ = writeAll(values)
    }

    /// Environment first (for tests and shell launches), then the saved file.
    public static func resolve(
        endpoint: AskEndpoint,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for name in endpoint.keyEnvironment {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return loadStored(endpoint: endpoint)
    }

    private static func loadStored(endpoint: AskEndpoint) -> String? {
        loadAll()[account(for: endpoint)]
    }

    private static func loadAll() -> [String: String] {
        guard let keyData = try? Data(contentsOf: keyURL),
              keyData.count == 32,
              let sealed = try? Data(contentsOf: keysURL),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let clear = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)),
              let values = try? JSONDecoder().decode([String: String].self, from: clear) else {
            return [:]
        }
        return values
    }

    @discardableResult
    private static func writeAll(_ values: [String: String]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let keyData: Data
            if let existing = try? Data(contentsOf: keyURL), existing.count == 32 {
                keyData = existing
            } else {
                var bytes = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                    Log.shared.warn("Could not create the Ask key file", source: "ask")
                    return false
                }
                keyData = Data(bytes)
                try keyData.write(to: keyURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            }
            let clear = try JSONEncoder().encode(values)
            let sealed = try AES.GCM.seal(clear, using: SymmetricKey(data: keyData)).combined
            try sealed?.write(to: keysURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysURL.path)
            return true
        } catch {
            Log.shared.warn("Could not save the Ask key file: \(error.localizedDescription)", source: "ask")
            return false
        }
    }
}
