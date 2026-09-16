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
    private static let service = "com.notchscotch.app.apikeys"
    /// The service name before the rename. Read-only: secrets are migrated out
    /// of it on first access and it is never written to again.
    private static let previousService = "com.notchbuddy.app.apikeys"

    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        // SecItemUpdate cannot create, SecItemAdd cannot overwrite. Delete-then-add
        // is the standard idiom and is atomic enough for a single-writer app.
        delete(account, in: service)
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
        if let value = read(account, from: service) { return value }
        // Fall back to the pre-rename service, and move anything found across
        // so the next read is a hit. A rename that quietly loses someone's API
        // keys means every integration in the app stops working with no
        // explanation, which is worse than the rename is worth.
        guard let migrated = read(account, from: previousService) else { return nil }
        set(migrated, for: account)
        delete(account, in: previousService)
        Log.llm.info("migrated keychain item to the new service name")
        return migrated
    }

    private static func read(_ account: String, from service: String) -> String? {
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
        delete(account, in: service)
        delete(account, in: previousService)
    }

    private static func delete(_ account: String, in service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func has(_ account: String) -> Bool {
        exists(account, in: service) || exists(account, in: previousService)
    }

    private static func exists(_ account: String, in service: String) -> Bool {
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
