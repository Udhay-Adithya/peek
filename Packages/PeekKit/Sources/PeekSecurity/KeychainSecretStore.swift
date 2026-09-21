import Foundation
import Security

/// Keychain-backed credential storage.
///
/// Deliberately does **not** set `kSecUseDataProtectionKeychain`. On macOS that
/// flag requires the process to carry a `keychain-access-groups` entitlement or
/// to be sandboxed; Peek is neither, and `SecItemAdd` then fails with
/// `errSecMissingEntitlement` (-34018). Obtaining that entitlement for a
/// non-sandboxed Developer ID app means dragging in a provisioning profile for
/// no functional gain, so the file-based keychain is used instead.
///
/// The tradeoff: keychain item ACLs are tied to the code signature, so changing
/// signing identity produces a one-time "allow access" prompt. That is a
/// development-time annoyance, not a shipping one.
///
/// Accessibility is `AfterFirstUnlock`: Peek can be a login item, so it may
/// need its key before the user has interacted with the machine, but the key
/// should still be unavailable while the disk is locked.
public struct KeychainSecretStore: SecretStore {

    private let service: String

    public init(service: String = "com.udhayadithya.Peek") {
        self.service = service
    }

    private func baseQuery(for key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
    }

    public func store(_ secret: String, for key: SecretKey) throws {
        let data = Data(secret.utf8)

        var addQuery = baseQuery(for: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Replace the value in place, preserving the item's attributes.
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(for: key) as CFDictionary,
                                             update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SecretStoreError.unexpectedStatus(updateStatus)
            }
        default:
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    public func secret(for key: SecretKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw SecretStoreError.dataCorrupted }
            guard let string = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.dataCorrupted
            }
            return string
        case errSecItemNotFound:
            // A missing credential is an ordinary state, not an error.
            return nil
        default:
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    public func remove(_ key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }
}
