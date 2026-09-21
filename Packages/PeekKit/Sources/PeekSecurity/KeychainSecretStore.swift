import Foundation
import Security

/// Keychain-backed credential storage.
///
/// Uses the data-protection keychain (`kSecUseDataProtectionKeychain`), which
/// is the modern behaviour on macOS and avoids the legacy file-based keychain's
/// ACL prompts.
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
            kSecUseDataProtectionKeychain as String: true,
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
