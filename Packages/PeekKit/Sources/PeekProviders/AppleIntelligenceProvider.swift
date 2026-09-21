import Foundation
import FoundationModels
import PeekCore

/// Apple Intelligence, running entirely on this Mac.
///
/// The strongest privacy option in the product and the only one that needs no
/// credential: nothing leaves the machine, so selected text and screenshots
/// never reach a third party. Also the best test of the provider abstraction,
/// because it is not an HTTP API at all — no SSE, no JSON, no key.
///
/// Two genuine differences from a cloud provider are handled here rather than
/// leaking outward:
///
/// * **It streams cumulative snapshots, not deltas.** Emitted as
///   ``AssistantStreamEvent/textSnapshot(_:)`` so a revision cannot corrupt the
///   transcript.
/// * **It is text-only.** A request carrying an image is refused with a clear
///   error instead of silently dropping the attachment.
public struct AppleIntelligenceProvider: AssistantProvider {

    public let identifier = ProviderIdentifier.appleIntelligence
    public let displayName = "Apple Intelligence"
    public let requiresAPIKey = false

    public let models: [ModelDescriptor] = [
        ModelDescriptor(id: "system", displayName: "On-device", supportsImages: false),
    ]

    /// Produces cumulative text snapshots for a request.
    ///
    /// Injected so the translation layer can be tested on any machine: whether
    /// Apple Intelligence is enabled is a property of the user's Mac, not of
    /// this code.
    public typealias SnapshotSource =
        @Sendable (AssistantRequest) -> AsyncThrowingStream<String, Error>

    private let snapshots: SnapshotSource
    private let availability: @Sendable () -> AssistantError?

    public init(snapshots: @escaping SnapshotSource = AppleIntelligenceProvider.systemSnapshots,
                availability: @escaping @Sendable () -> AssistantError? = AppleIntelligenceProvider.systemAvailability) {
        self.snapshots = snapshots
        self.availability = availability
    }

    public func stream(_ request: AssistantRequest) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if let unavailable = availability() {
                    continuation.finish(throwing: unavailable)
                    return
                }

                if request.messages.contains(where: { $0.parts.contains(where: Self.isImage) }) {
                    continuation.finish(throwing: AssistantError.unsupportedContent(
                        "Apple Intelligence is text-only. Remove the screenshot, or switch provider in Settings."
                    ))
                    return
                }

                continuation.yield(.responseStarted(id: nil))
                do {
                    for try await snapshot in snapshots(request) {
                        try Task.checkCancellation()
                        continuation.yield(.textSnapshot(snapshot))
                    }
                    // The framework reports no token accounting, so no usage
                    // event is emitted — the field is genuinely absent rather
                    // than zero.
                    continuation.yield(.finished(.stop))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AssistantError.cancelled)
                } catch let error as AssistantError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func isImage(_ part: ContentPart) -> Bool {
        if case .image = part { return true }
        return false
    }

    // MARK: - System model

    /// `nil` when the on-device model can be used here.
    public static let systemAvailability: @Sendable () -> AssistantError? = {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return .providerUnavailable(describe(reason))
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence. Choose a cloud provider in Settings."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off. Enable it in System Settings › Apple Intelligence & Siri."
        case .modelNotReady:
            return "The on-device model is still downloading. Try again shortly."
        @unknown default:
            return "Apple Intelligence is unavailable on this Mac."
        }
    }

    /// Drives a real `LanguageModelSession`.
    ///
    /// A fresh session per request, with prior turns rendered into the prompt.
    /// The provider is stateless by contract — the conversation lives in
    /// ``ConversationStore`` — so carrying a long-lived session here would put
    /// the same history in two places and let them disagree.
    public static let systemSnapshots: SnapshotSource = { request in
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: request.systemInstruction)
                    let prompt = renderPrompt(request)

                    var options = GenerationOptions()
                    if let temperature = request.temperature {
                        options = GenerationOptions(temperature: temperature)
                    }

                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Flattens the conversation into a single prompt.
    ///
    /// The framework's `Transcript` type could carry structured history, but a
    /// rendered prompt keeps this provider's contract identical to every other
    /// one and keeps the on-device context window — which is small — visible in
    /// one place.
    static func renderPrompt(_ request: AssistantRequest) -> String {
        guard request.messages.count > 1 else {
            return request.messages.last?.plainText ?? ""
        }

        let history = request.messages.dropLast().map { message in
            let speaker = message.role == .user ? "User" : "Assistant"
            return "\(speaker): \(message.plainText)"
        }.joined(separator: "\n\n")

        let latest = request.messages.last?.plainText ?? ""
        return """
            Conversation so far:
            \(history)

            \(latest)
            """
    }

    static func map(_ error: Error) -> AssistantError {
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return .network(error.localizedDescription)
        }
        switch generation {
        case .exceededContextWindowSize:
            return .serverError(status: 0, message:
                "This conversation is too long for the on-device model. Start a new one with ⌘N.")
        case .assetsUnavailable:
            return .providerUnavailable("The on-device model is not downloaded yet.")
        case .guardrailViolation, .refusal:
            return .serverError(status: 0, message: "Apple Intelligence declined to answer this.")
        case .rateLimited:
            return .rateLimited(retryAfter: nil)
        case .concurrentRequests:
            return .rateLimited(retryAfter: 1)
        case .unsupportedLanguageOrLocale:
            return .unsupportedContent("Apple Intelligence does not support this language yet.")
        default:
            return .invalidResponse(generation.localizedDescription)
        }
    }
}
