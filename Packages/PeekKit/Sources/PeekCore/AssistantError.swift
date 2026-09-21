import Foundation

/// Failures a provider can surface, normalised across vendors.
///
/// Distinct cases rather than a wrapped HTTP status because the UI response
/// differs sharply: a missing key sends the user to settings, a rate limit is
/// worth retrying automatically, and a server error is worth retrying manually.
public enum AssistantError: Error, Equatable, Sendable {
    /// No API key configured for the selected provider.
    case missingCredentials
    /// The key was rejected. Distinct from ``missingCredentials`` because the
    /// remedy is replacing a key rather than adding one.
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int, message: String?)
    /// The provider replied with something the adapter could not decode.
    case invalidResponse(String)
    case network(String)
    case cancelled

    /// Whether retrying the identical request could plausibly succeed.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .network:
            return true
        case .serverError(let status, _):
            return status >= 500
        case .missingCredentials, .unauthorized, .invalidResponse, .cancelled:
            return false
        }
    }
}

extension AssistantError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No API key configured."
        case .unauthorized:
            return "The API key was rejected."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limited. Try again in \(Int(retryAfter.rounded()))s."
            }
            return "Rate limited by the provider."
        case .serverError(let status, let message):
            return message.map { "Provider error \(status): \($0)" } ?? "Provider error \(status)."
        case .invalidResponse(let detail):
            return "Unexpected response from the provider: \(detail)"
        case .network(let detail):
            return "Network error: \(detail)"
        case .cancelled:
            return "Cancelled."
        }
    }
}
