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
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.providerID = ProviderIdentifier(
            rawValue: defaults.string(forKey: Key.providerID) ?? ProviderIdentifier.gemini.rawValue
        )
        self.modelID = defaults.string(forKey: Key.modelID) ?? "gemini-2.5-flash"
        self.autoSendOnInvoke = defaults.bool(forKey: Key.autoSend)
        // Defaults to on: without it, Electron and Gecko apps supply no
        // context at all, which is most browsers and most chat apps.
        self.clipboardFallbackEnabled = defaults.object(forKey: Key.clipboardFallback) as? Bool ?? true
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
}
