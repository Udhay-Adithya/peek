import Foundation
import PeekCore

/// Wraps a provider and retries transient failures.
///
/// Motivated by measurement, not theory: on Gemini's free tier the newer model
/// aliases return 503 "experiencing high demand" often enough that a single
/// unlucky request would otherwise surface to the user as a hard failure.
///
/// The critical rule is that a retry is only allowed **before the first event
/// has been forwarded**. Once a text delta reaches the UI it cannot be
/// un-emitted, so retrying mid-stream would duplicate or contradict text the
/// user has already read. After that point the error propagates.
public struct RetryingProvider<Base: AssistantProvider>: AssistantProvider {

    private let base: Base
    private let maxAttempts: Int
    private let delay: @Sendable (Int) -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(wrapping base: Base,
                maxAttempts: Int = 3,
                delay: @escaping @Sendable (Int) -> Duration = { attempt in
                    // 400ms, 800ms — short enough that the panel still feels live.
                    .milliseconds(400 * (1 << (attempt - 1)))
                },
                sleep: @escaping @Sendable (Duration) async throws -> Void = {
                    try await Task.sleep(for: $0)
                }) {
        self.base = base
        self.maxAttempts = maxAttempts
        self.delay = delay
        self.sleep = sleep
    }

    public var identifier: ProviderIdentifier { base.identifier }
    public var displayName: String { base.displayName }
    public var models: [ModelDescriptor] { base.models }

    public func stream(_ request: AssistantRequest) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 0
                while true {
                    attempt += 1
                    var forwardedAny = false
                    do {
                        for try await event in base.stream(request) {
                            forwardedAny = true
                            continuation.yield(event)
                        }
                        continuation.finish()
                        return
                    } catch {
                        let retryable = (error as? AssistantError)?.isRetryable ?? false

                        // Never retry once the user has seen output, and never
                        // retry a cancellation.
                        guard retryable, !forwardedAny, attempt < maxAttempts,
                              !(error is CancellationError) else {
                            continuation.finish(throwing: error)
                            return
                        }

                        let wait = (error as? AssistantError).flatMap { error -> Duration? in
                            // Honour the provider's own Retry-After when given.
                            if case .rateLimited(let after) = error, let after {
                                return .milliseconds(Int(after * 1000))
                            }
                            return nil
                        } ?? delay(attempt)

                        do {
                            try await sleep(wait)
                        } catch {
                            continuation.finish(throwing: AssistantError.cancelled)
                            return
                        }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
