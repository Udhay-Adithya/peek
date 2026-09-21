import Foundation
import PeekCore

public struct ProviderIdentifier: Hashable, Sendable, RawRepresentable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let gemini = ProviderIdentifier(rawValue: "gemini")
    public static let appleIntelligence = ProviderIdentifier(rawValue: "apple-intelligence")
}

public struct ModelDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let supportsImages: Bool

    public init(id: String, displayName: String, supportsImages: Bool) {
        self.id = id
        self.displayName = displayName
        self.supportsImages = supportsImages
    }
}

/// Supplies the API key at request time.
///
/// A closure rather than a stored string so the key is read from the Keychain
/// per request and never held in a long-lived provider instance.
public typealias APIKeyProvider = @Sendable () async throws -> String

/// What every model vendor must look like from the app's point of view.
public protocol AssistantProvider: Sendable {
    var identifier: ProviderIdentifier { get }
    var displayName: String { get }
    var models: [ModelDescriptor] { get }

    /// Whether this provider needs an API key at all.
    ///
    /// False for the on-device model, which lets the settings UI omit the
    /// credential field rather than asking for a key that does not exist.
    var requiresAPIKey: Bool { get }

    /// Streams a turn as normalised events.
    ///
    /// Errors arrive by the stream throwing, never as an event, so a consumer
    /// cannot forget to handle them. Cancelling the consuming task must abort
    /// the underlying request.
    func stream(_ request: AssistantRequest) -> AsyncThrowingStream<AssistantStreamEvent, Error>
}

public extension AssistantProvider {
    var requiresAPIKey: Bool { true }
}
