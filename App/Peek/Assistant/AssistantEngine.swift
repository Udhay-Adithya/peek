import Foundation
import PeekCore
import PeekProviders
import PeekSecurity

/// Resolves which provider to use and whether it is usable.
///
/// The API key is read from the Keychain per request through a closure rather
/// than being held on a long-lived provider instance, so a key that is changed
/// or revoked in settings takes effect on the very next request and no copy
/// lingers in memory.
@MainActor
final class AssistantEngine {

    private let settings: AppSettings
    private let secrets: SecretStore

    init(settings: AppSettings, secrets: SecretStore = KeychainSecretStore()) {
        self.settings = settings
        self.secrets = secrets
    }

    var selectedModelID: String { settings.modelID }

    var availableProviders: [AssistantProvider] { [makeProvider(.gemini)] }

    func currentProvider() -> AssistantProvider {
        makeProvider(settings.providerID)
    }

    /// Whether a key is present for the selected provider.
    var hasCredentials: Bool {
        let key = SecretKey.provider(settings.providerID.rawValue)
        return (try? secrets.secret(for: key))?.isEmpty == false
    }

    func storeKey(_ key: String, for provider: ProviderIdentifier) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = SecretKey.provider(provider.rawValue)
        if trimmed.isEmpty {
            try secrets.remove(secretKey)
        } else {
            try secrets.store(trimmed, for: secretKey)
        }
    }

    func maskedKey(for provider: ProviderIdentifier) -> String? {
        guard let key = try? secrets.secret(for: SecretKey.provider(provider.rawValue)),
              !key.isEmpty else { return nil }
        return SecretMask.mask(key)
    }

    private func makeProvider(_ identifier: ProviderIdentifier) -> AssistantProvider {
        let secrets = self.secrets
        let account = SecretKey.provider(identifier.rawValue)
        let keyProvider: APIKeyProvider = {
            guard let key = try secrets.secret(for: account), !key.isEmpty else {
                throw AssistantError.missingCredentials
            }
            return key
        }

        // Only one provider today. The switch exists so adding the next one is
        // a case rather than a refactor.
        // Retry wrapper applied here rather than inside the adapter, so the
        // policy is one decision for every provider instead of each vendor's
        // idea of transience.
        switch identifier {
        case .gemini:
            return RetryingProvider(wrapping: GeminiProvider(apiKey: keyProvider))
        default:
            return RetryingProvider(wrapping: GeminiProvider(apiKey: keyProvider))
        }
    }
}
