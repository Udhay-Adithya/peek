import Foundation
import PeekProviders

/// The part of ``AssistantEngine`` that a conversation actually needs.
///
/// Exists so `AssistantSession` can be tested without a Keychain, a network,
/// or an on-device model: the session's job is turn management and persistence,
/// and neither should require a real provider to verify.
@MainActor
protocol ProviderResolving {
    var selectedModelID: String { get }
    /// Whether the selected provider is usable. Always true for the on-device
    /// model, which has no credential to be missing.
    var hasCredentials: Bool { get }
    func currentProvider() -> AssistantProvider
}

extension AssistantEngine: ProviderResolving {}
