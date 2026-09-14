import Foundation
import Security

/// Keychain-backed secret storage for LLM API keys.
///
/// Rule from the brief, restated because it is easy to violate accidentally:
/// API keys never touch UserDefaults, never touch a plist, never get encoded
/// into the settings JSON. `Settings` stores only a *reference* -- the provider
/// enum -- and asks Keychain for the key at request time.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is chosen over the default
/// so the key is not carried to a new machine by an iCloud Keychain sync or a
/// migration-assistant transfer, and so background approval/LLM work still
/// functions while the screen is locked.
enum Keychain {
    private static let service = "com.notchbuddy.app.apikeys"

    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        // SecItemUpdate cannot create, SecItemAdd cannot overwrite. Delete-then-add
        // is the standard idiom and is atomic enough for a single-writer app.
        delete(account)
        guard !value.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Log.llm.error("keychain add failed: \(status)")
        }
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func has(_ account: String) -> Bool {
        // Deliberately does not pull the secret into memory just to test presence.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
