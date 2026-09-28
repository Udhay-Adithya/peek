import Foundation

/// In-memory ``SecretStore`` for tests and previews.
///
/// Exists in the shipping module rather than the test target so SwiftUI
/// previews and future UI tests can run without a Keychain, and so the
/// contract has exactly one definition both implementations are checked
/// against.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [SecretKey: String] = [:]

    public init() {}

    public func store(_ secret: String, for key: SecretKey) throws {
        lock.withLock { storage[key] = secret }
    }

    public func secret(for key: SecretKey) throws -> String? {
        lock.withLock { storage[key] }
    }

    public func remove(_ key: SecretKey) throws {
        // The removed value is discarded deliberately; `remove` is idempotent
        // and reports nothing about whether the key existed.
        _ = lock.withLock { storage.removeValue(forKey: key) }
    }
}
