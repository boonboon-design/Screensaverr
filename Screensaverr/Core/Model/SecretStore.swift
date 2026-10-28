import Foundation
import Security

/// Somewhere to keep API keys that isn't a plain-text file.
protocol SecretStore {
    func secret(for account: String) throws -> String?
    func setSecret(_ value: String, for account: String) throws
    func removeSecret(for account: String) throws
}

struct KeychainError: LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"
        return "\(message) (\(status))"
    }
}

/// Generic passwords in the user's login Keychain, which macOS encrypts and unlocks with their
/// login password. One item per service, e.g. service "com.boonboondesign.Screensaverr", account "sonarr".
struct KeychainSecretStore: SecretStore {
    let service: String

    /// For the running screen saver: nobody can answer a Keychain dialog hidden behind it, and
    /// waiting for one would freeze it, so make Keychain calls that need one fail instead.
    /// (Process-wide, and only the login keychain's own switch covers its access prompts.)
    static func disallowUserInteraction() {
        SecKeychainSetUserInteractionAllowed(false)
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func secret(for account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Screensaverr API key (\(account))"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func removeSecret(for account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
