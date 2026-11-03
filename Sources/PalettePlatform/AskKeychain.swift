import Foundation
import PaletteCore
import Security

/// API keys for `/ask` live in the login Keychain. Nothing in this type ever
/// returns a saved key to the Settings UI, and no key is written to config.toml
/// or the log.
public enum AskKeychain {
    private static let service = "dev.myleshen.palette.ask"

    private static func account(for endpoint: AskEndpoint) -> String {
        "api-key-\(endpoint.rawValue)"
    }

    public static func hasStoredKey(for endpoint: AskEndpoint) -> Bool {
        loadStored(endpoint: endpoint) != nil
    }

    public static func save(_ key: String, for endpoint: AskEndpoint) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        delete(endpoint: endpoint)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: endpoint),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Log.shared.warn("Could not save the Ask API key (Keychain status \(status))", source: "ask")
        }
        return status == errSecSuccess
    }

    public static func delete(endpoint: AskEndpoint) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: endpoint),
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Keychain first, then the endpoint's environment override. The latter is
    /// useful for development and for a shell-launched test build.
    public static func resolve(
        endpoint: AskEndpoint,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let stored = loadStored(endpoint: endpoint) { return stored }
        for name in endpoint.keyEnvironment {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func loadStored(endpoint: AskEndpoint) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: endpoint),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
