import Foundation
import Observation
import PeekProviders

/// Non-secret user preferences.
///
/// `UserDefaults` for preferences, Keychain for credentials — the split is
/// deliberate and enforced by this type holding no secret at all.
@MainActor
@Observable
final class AppSettings {

    private enum Key {
        static let providerID = "provider.selected"
        static let modelID = "model.selected"
        static let autoSend = "behaviour.autoSendOnInvoke"
        static let clipboardFallback = "capture.clipboardFallbackEnabled"
        static let continueRecent = "behaviour.continueRecentConversation"
        static let forceClick = "triggers.forceClickEnabled"
    }

    /// How recently a conversation must have been touched to be resumed.
    ///
    /// Five minutes: long enough to cover a follow-up thought, short enough
    /// that this morning's conversation does not absorb this afternoon's
    /// unrelated question.
    static let continuationWindow: TimeInterval = 5 * 60

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Default to the on-device model where the Mac supports it: no key to
        // configure, and nothing leaves the machine. Falls back to a cloud
        // provider on hardware without Apple Intelligence.
        let fallbackProvider = AppleIntelligenceProvider.systemAvailability() == nil
            ? ProviderIdentifier.appleIntelligence
            : ProviderIdentifier.gemini
        let storedProvider = defaults.string(forKey: Key.providerID)
        let resolvedProvider = ProviderIdentifier(rawValue: storedProvider ?? fallbackProvider.rawValue)
        self.providerID = resolvedProvider

        let fallbackModel = resolvedProvider == .appleIntelligence ? "system" : GeminiProvider.defaultModelID
        self.modelID = defaults.string(forKey: Key.modelID) ?? fallbackModel
        self.autoSendOnInvoke = defaults.bool(forKey: Key.autoSend)
        // Defaults to on: without it, Electron and Gecko apps supply no
        // context at all, which is most browsers and most chat apps.
        self.clipboardFallbackEnabled = defaults.object(forKey: Key.clipboardFallback) as? Bool ?? true
        self.continueRecentConversation = defaults.object(forKey: Key.continueRecent) as? Bool ?? true
        // Off by default: it depends on a private framework and competes with
        // the system's own Look Up, so it is the user's decision to switch on.
        self.forceClickEnabled = defaults.object(forKey: Key.forceClick) as? Bool ?? false
    }

    var providerID: ProviderIdentifier {
        didSet { defaults.set(providerID.rawValue, forKey: Key.providerID) }
    }

    var modelID: String {
        didSet { defaults.set(modelID, forKey: Key.modelID) }
    }

    /// Whether invoking with a selection immediately starts a request.
    ///
    /// Off by default. Auto-sending on every invocation spends money and ships
    /// the selection to a third party on what may have been a misfire.
    var autoSendOnInvoke: Bool {
        didSet { defaults.set(autoSendOnInvoke, forKey: Key.autoSend) }
    }

    var clipboardFallbackEnabled: Bool {
        didSet { defaults.set(clipboardFallbackEnabled, forKey: Key.clipboardFallback) }
    }

    /// Whether Force Click invokes Peek.
    var forceClickEnabled: Bool {
        didSet { defaults.set(forceClickEnabled, forKey: Key.forceClick) }
    }

    /// Whether invoking from the same app shortly after continues that thread.
    var continueRecentConversation: Bool {
        didSet { defaults.set(continueRecentConversation, forKey: Key.continueRecent) }
    }
}
