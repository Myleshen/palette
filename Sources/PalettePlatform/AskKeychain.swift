import CryptoKit
import Foundation
import PaletteCore
import Security

/// Ask API keys live in a user-only file, not the login Keychain. Ad-hoc
/// development builds change signature constantly, which made Keychain ACL
/// prompts appear on every rebuild. The values are encrypted with a random
/// 32-byte key; that pairing is obfuscation, not confidentiality: anyone who
/// can read both files can decrypt them. Keeping the key outside the config
/// directory stops a synced or backed-up config from carrying the pair
/// together. Nothing in this type returns a saved key to the Settings UI, and
/// no key enters config.toml or logs.
public enum AskKeychain {
    /// One queue serialises every read and write so a save cannot interleave
    /// with a delete and resurrect a removed key.
    private static let queue = DispatchQueue(label: "dev.myleshen.palette.ask-keys")
    /// Set after an unreadable or corrupt file is found. Writes stay off until
    /// the app restarts, so a transient read failure cannot overwrite keys.
    private static var corruptDetected = false

    private static var configDirectory: URL {
        PalettePaths.resolve().configDir
    }

    /// `PALETTE_SUPPORT_DIR` lets tests and debug builds keep their own copy.
    private static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PALETTE_SUPPORT_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: PathExpansion.expand(override), isDirectory: true)
        }
        return URL(fileURLWithPath: PalettePaths.resolve().home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Palette", isDirectory: true)
    }

    private static var keysURL: URL {
        configDirectory.appendingPathComponent("ask-keys.bin")
    }

    private static var keyURL: URL {
        supportDirectory.appendingPathComponent("ask-key.bin")
    }

    /// Pre-2.17 location, inside the config directory.
    private static var legacyKeyURL: URL {
        configDirectory.appendingPathComponent("ask-key.bin")
    }

    private static func account(for endpoint: AskEndpoint) -> String {
        "api-key-\(endpoint.rawValue)"
    }

    /// Clears the refusal latch between isolated keychain tests.
    static func resetCorruptStateForTesting() {
        queue.sync { corruptDetected = false }
    }

    public static func hasStoredKey(for endpoint: AskEndpoint) -> Bool {
        loadStored(endpoint: endpoint) != nil
    }

    public static func save(_ key: String, for endpoint: AskEndpoint) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return queue.sync {
            guard !corruptDetected else {
                Log.shared.warn("Ask key save refused: an unreadable key file was found earlier", source: "ask")
                return false
            }
            var values: [String: String]
            switch loadUnlocked() {
            case .empty:
                values = [:]
            case .values(let loaded):
                values = loaded
            case .corrupt:
                return false
            }
            values[account(for: endpoint)] = trimmed
            return writeUnlocked(values)
        }
    }

    public static func delete(endpoint: AskEndpoint) {
        queue.sync {
            guard !corruptDetected else {
                Log.shared.warn("Ask key delete refused: an unreadable key file was found earlier", source: "ask")
                return
            }
            guard case .values(var values) = loadUnlocked() else { return }
            values.removeValue(forKey: account(for: endpoint))
            _ = writeUnlocked(values)
        }
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
        queue.sync {
            guard case .values(let values) = loadUnlocked() else { return nil }
            return values[account(for: endpoint)]
        }
    }

    private enum Loaded {
        case empty
        case values([String: String])
        case corrupt
    }

    private static func loadUnlocked() -> Loaded {
        migrateLegacyKeyIfNeeded()
        let manager = FileManager.default
        let keyExists = manager.fileExists(atPath: keyURL.path)
        let legacyExists = manager.fileExists(atPath: legacyKeyURL.path)
        let keysExist = manager.fileExists(atPath: keysURL.path)

        var keyData: Data?
        var keyReadFailed = false
        if keyExists {
            if let data = try? Data(contentsOf: keyURL) {
                keyData = data
            } else {
                keyReadFailed = true
            }
        } else if legacyExists {
            if let data = try? Data(contentsOf: legacyKeyURL) {
                keyData = data
            } else {
                keyReadFailed = true
            }
        }
        if keyReadFailed {
            return corrupt(reason: "the key file could not be read")
        }
        guard let keyData else {
            return keysExist ? corrupt(reason: "the key file is missing") : .empty
        }
        guard keyData.count == 32 else {
            return corrupt(reason: "the key file has the wrong size")
        }
        guard keysExist else { return .empty }
        guard let sealed = try? Data(contentsOf: keysURL) else {
            return corrupt(reason: "the saved keys could not be read")
        }
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let clear = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)),
              let values = try? JSONDecoder().decode([String: String].self, from: clear) else {
            return corrupt(reason: "the saved keys could not be decrypted")
        }
        return .values(values)
    }

    /// Preserves whatever is unreadable beside the original and turns writes off.
    private static func corrupt(reason: String) -> Loaded {
        let stamp = String(Int(Date().timeIntervalSince1970))
        preserve(keyURL, stamp: stamp)
        preserve(legacyKeyURL, stamp: stamp)
        preserve(keysURL, stamp: stamp)
        corruptDetected = true
        Log.shared.warn(
            "Ask keys are unreadable (\(reason)); the files were kept as *.corrupt-\(stamp) and writes are disabled until restart",
            source: "ask"
        )
        return .corrupt
    }

    private static func preserve(_ url: URL, stamp: String) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        do {
            try manager.moveItem(at: url, to: backup)
            Log.shared.warn("Kept the unreadable Ask key file as \(backup.lastPathComponent)", source: "ask")
        } catch {
            Log.shared.warn("Could not preserve \(url.lastPathComponent): \(error.localizedDescription)", source: "ask")
        }
    }

    /// Moves the pre-2.17 key out of the config directory once. A failure
    /// leaves the old file readable, so existing users keep their keys.
    private static func migrateLegacyKeyIfNeeded() {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: keyURL.path),
              manager.fileExists(atPath: legacyKeyURL.path) else { return }
        do {
            try manager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try manager.moveItem(at: legacyKeyURL, to: keyURL)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        } catch {
            Log.shared.warn("Could not move the Ask key file: \(error.localizedDescription)", source: "ask")
        }
    }

    @discardableResult
    private static func writeUnlocked(_ values: [String: String]) -> Bool {
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            try manager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
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
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            }
            let clear = try JSONEncoder().encode(values)
            let sealed = try AES.GCM.seal(clear, using: SymmetricKey(data: keyData)).combined
            try sealed?.write(to: keysURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysURL.path)
            return true
        } catch {
            Log.shared.warn("Could not save the Ask key file: \(error.localizedDescription)", source: "ask")
            return false
        }
    }
}
