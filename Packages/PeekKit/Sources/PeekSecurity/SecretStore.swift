import Foundation
import Security

/// Identifies one stored secret.
public struct SecretKey: Hashable, Sendable {
    public let account: String
    public init(account: String) { self.account = account }

    public static func provider(_ identifier: String) -> SecretKey {
        SecretKey(account: "provider.\(identifier).apiKey")
    }
}

public enum SecretStoreError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case dataCorrupted
}

extension SecretStoreError: LocalizedError {
    /// Includes the raw `OSStatus`.
    ///
    /// Keychain failures are otherwise indistinguishable from each other, and a
    /// bare "could not save" gives neither the user nor a bug report anything
    /// to act on. Status codes describe the API call, not the secret.
    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain error \(status)\(detail.map { ": \($0)" } ?? "")"
        case .dataCorrupted:
            return "The stored credential could not be decoded."
        }
    }
}

/// Somewhere to keep credentials.
///
/// A protocol so the Keychain stays out of tests: touching the real Keychain
/// from a test suite prompts for authorisation, depends on the signing
/// identity, and leaves state on the developer's machine. Behaviour is
/// verified against an in-memory implementation of this same contract.
public protocol SecretStore: Sendable {
    func store(_ secret: String, for key: SecretKey) throws
    func secret(for key: SecretKey) throws -> String?
    func remove(_ key: SecretKey) throws
}

public extension SecretStore {
    func contains(_ key: SecretKey) throws -> Bool {
        try secret(for: key) != nil
    }
}

/// Presentation-safe rendering of a credential.
///
/// The settings UI must never show a full key: it is shoulder-surfable, it ends
/// up in screenshots and screen shares, and this app's own screenshot feature
/// makes that a live hazard rather than a theoretical one.
public enum SecretMask {

    /// Masks a secret, revealing only a short head and tail.
    ///
    /// Short secrets are masked entirely rather than partially — revealing four
    /// of eight characters gives away half the key.
    public static func mask(_ secret: String, visibleHead: Int = 4, visibleTail: Int = 4) -> String {
        let bullets = String(repeating: "•", count: 8)
        guard secret.count > visibleHead + visibleTail + 4 else {
            return bullets
        }
        let head = secret.prefix(visibleHead)
        let tail = secret.suffix(visibleTail)
        return "\(head)\(bullets)\(tail)"
    }
}
