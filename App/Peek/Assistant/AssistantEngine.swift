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

    func selectModel(_ id: String) {
        settings.modelID = id
    }

    /// Every provider the app can offer, in the order they appear in settings.
    ///
    /// On-device first: it needs no key, sends nothing off the machine, and is
    /// therefore the right default for a utility that reads whatever you had
    /// selected.
    var availableProviders: [AssistantProvider] {
        [makeProvider(.appleIntelligence), makeProvider(.gemini)]
    }

    func currentProvider() -> AssistantProvider {
        makeProvider(settings.providerID)
    }

    /// Whether the selected provider is ready to use.
    ///
    /// The on-device provider has no credential, so "configured" cannot mean
    /// "has a key" — that would permanently show a key warning for a provider
    /// that never needs one.
    var hasCredentials: Bool {
        let provider = currentProvider()
        guard provider.requiresAPIKey else { return true }
        let key = SecretKey.provider(settings.providerID.rawValue)
        return (try? secrets.secret(for: key))?.isEmpty == false
    }

    /// Non-nil when the selected provider cannot run on this Mac.
    var unavailabilityReason: String? {
        guard settings.providerID == .appleIntelligence else { return nil }
        if case .providerUnavailable(let reason)? = AppleIntelligenceProvider.systemAvailability() {
            return reason
        }
        return nil
    }

    /// Switches provider, moving the model selection to one it actually offers.
    func selectProvider(_ identifier: ProviderIdentifier) {
        guard settings.providerID != identifier else { return }
        settings.providerID = identifier
        let models = makeProvider(identifier).models
        if !models.contains(where: { $0.id == settings.modelID }) {
            settings.modelID = models.first?.id ?? settings.modelID
        }
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
        case .appleIntelligence:
            // No retry wrapper: an on-device failure is a device or setting
            // problem, not a transient network one, so retrying only delays
            // the explanation.
            return AppleIntelligenceProvider()
        case .gemini:
            return RetryingProvider(wrapping: GeminiProvider(apiKey: keyProvider))
        default:
            return RetryingProvider(wrapping: GeminiProvider(apiKey: keyProvider))
        }
    }
}
