import Foundation
import PeekCore

/// Where App Intents find the running app's services.
///
/// A global, which is normally worth avoiding — but the system instantiates an
/// `AppIntent` itself and offers no way to inject anything, so some global
/// entry point is unavoidable. It is kept as narrow as possible: set once
/// during launch, read only by intents, and `nil` until the app is ready so an
/// intent fired mid-launch reports that honestly instead of crashing.
@MainActor
enum IntentServices {

    private(set) static var engine: (any ProviderResolving)?
    private(set) static var store: ConversationStore?
    /// Shows the floating panel.
    private(set) static var showPanel: (() -> Void)?

    static func configure(engine: any ProviderResolving,
                          store: ConversationStore,
                          showPanel: @escaping () -> Void) {
        self.engine = engine
        self.store = store
        self.showPanel = showPanel
    }

    /// The assistant an intent should use, or `nil` before launch completes.
    static func assistant() -> HeadlessAssistant? {
        guard let engine else { return nil }
        return HeadlessAssistant(engine: engine, store: store)
    }
}
