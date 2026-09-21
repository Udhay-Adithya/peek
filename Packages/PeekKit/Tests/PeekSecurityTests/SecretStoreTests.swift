import Testing
import Foundation
@testable import PeekSecurity

@Suite("SecretStore contract")
struct SecretStoreContractTests {

    /// Exercised against the in-memory store. The Keychain implementation is
    /// held to the same contract but is not tested here: touching the real
    /// Keychain prompts for authorisation, depends on the signing identity, and
    /// leaves state behind on the machine running the tests.
    private func makeStore() -> SecretStore { InMemorySecretStore() }

    @Test("stores and retrieves a secret")
    func roundTrip() throws {
        let store = makeStore()
        let key = SecretKey.provider("gemini")
        try store.store("AIzaSyExampleKey123456", for: key)
        #expect(try store.secret(for: key) == "AIzaSyExampleKey123456")
    }

    @Test("a missing secret is nil, not an error")
    func missingIsNil() throws {
        #expect(try makeStore().secret(for: .provider("nobody")) == nil)
    }

    @Test("storing twice replaces rather than duplicating")
    func replacesOnSecondWrite() throws {
        let store = makeStore()
        let key = SecretKey.provider("gemini")
        try store.store("first", for: key)
        try store.store("second", for: key)
        #expect(try store.secret(for: key) == "second")
    }

    @Test("removal is idempotent")
    func removalIsIdempotent() throws {
        let store = makeStore()
        let key = SecretKey.provider("gemini")
        try store.store("value", for: key)
        try store.remove(key)
        try store.remove(key)   // must not throw
        #expect(try store.secret(for: key) == nil)
    }

    @Test("keys for different providers do not collide")
    func providersAreIsolated() throws {
        let store = makeStore()
        try store.store("gemini-key", for: .provider("gemini"))
        try store.store("openai-key", for: .provider("openai"))
        #expect(try store.secret(for: .provider("gemini")) == "gemini-key")
        #expect(try store.secret(for: .provider("openai")) == "openai-key")
    }

    @Test("contains reflects presence")
    func containsReflectsPresence() throws {
        let store = makeStore()
        let key = SecretKey.provider("gemini")
        #expect(try store.contains(key) == false)
        try store.store("value", for: key)
        #expect(try store.contains(key))
    }

    @Test("round-trips non-ASCII secrets")
    func handlesUnicode() throws {
        let store = makeStore()
        let key = SecretKey.provider("test")
        try store.store("клю́ч-🔑-key", for: key)
        #expect(try store.secret(for: key) == "клю́ч-🔑-key")
    }
}

@Suite("SecretMask")
struct SecretMaskTests {

    @Test("reveals only a short head and tail")
    func masksMiddle() {
        let masked = SecretMask.mask("AIzaSyD-1234567890abcdefXYZ")
        #expect(masked.hasPrefix("AIza"))
        #expect(masked.hasSuffix("fXYZ"))
        #expect(masked.contains("1234567890") == false)
    }

    @Test("masks short secrets entirely")
    func masksShortSecretsFully() {
        // Revealing 4 of 10 characters would give away nearly half the key.
        let masked = SecretMask.mask("short12345")
        #expect(masked.allSatisfy { $0 == "•" })
    }

    @Test("never returns the original secret")
    func neverEchoesInput() {
        for secret in ["a", "abcd", "abcdefgh", "AIzaSyD-1234567890abcdefXYZ"] {
            #expect(SecretMask.mask(secret) != secret)
        }
    }

    @Test("masks an empty secret without crashing")
    func handlesEmpty() {
        #expect(SecretMask.mask("").allSatisfy { $0 == "•" })
    }
}
