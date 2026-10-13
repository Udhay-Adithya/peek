import Foundation

/// What a model is allowed to fetch when it calls the web tool.
///
/// The URL here is chosen by the model, not the user, and the model's choice
/// can be steered by the very text it was asked to look at — a page or document
/// containing "fetch http://…" is an instruction Peek must not simply follow.
/// So this is a deny-by-default gate, not a sanity check:
///
/// * **HTTPS only.** A model-chosen URL must not silently downgrade to
///   cleartext, and `file:`, `peek:` and friends are not web fetches at all.
/// * **No private or loopback hosts.** The machine Peek runs on can reach
///   routers, databases, dev servers and cloud metadata endpoints that nothing
///   on the internet can. A summarise-this-page tool must not become a way to
///   read them.
/// * **No credentials in the URL.** `https://user:pass@host` would send them
///   onward on the model's initiative.
public enum WebFetchPolicy {

    /// Why a URL was refused. Reported back to the model so it can say what
    /// happened rather than inventing a page.
    public enum Refusal: Error, Equatable, Sendable {
        case notAURL
        case notHTTPS(String)
        case privateHost(String)
        case embeddedCredentials

        public var message: String {
            switch self {
            case .notAURL:
                return "That is not a valid URL."
            case .notHTTPS(let scheme):
                return "Only https URLs can be fetched, not \(scheme)."
            case .privateHost(let host):
                return "\(host) is a private or local address, which Peek will not fetch."
            case .embeddedCredentials:
                return "A URL containing a username or password will not be fetched."
            }
        }
    }

    /// The most text handed back to the model from one page.
    ///
    /// A whole page is often far larger than the context it is worth spending,
    /// and the tail of a long article is rarely what was asked about.
    public static let maxCharacters = 20_000

    public static func validate(_ raw: String) -> Result<URL, Refusal> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              let url = components.url else {
            return .failure(.notAURL)
        }

        guard let scheme = components.scheme?.lowercased() else { return .failure(.notAURL) }
        guard scheme == "https" else { return .failure(.notHTTPS(scheme)) }

        if components.user != nil || components.password != nil {
            return .failure(.embeddedCredentials)
        }

        guard !isPrivate(host: host) else { return .failure(.privateHost(host)) }

        return .success(url)
    }

    /// Whether a host names something only this machine or this network can
    /// reach.
    public static func isPrivate(host: String) -> Bool {
        let host = host.lowercased()
            // An IPv6 literal arrives bracketed from a URL.
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        // Bonjour names resolve only on the local network.
        if host.hasSuffix(".local") || host.hasSuffix(".internal") { return true }
        // Reserved by RFC 6761/2606 for testing and documentation.
        if host.hasSuffix(".test") || host.hasSuffix(".invalid")
            || host.hasSuffix(".localdomain") { return true }
        // A bare name with no dot cannot be a public DNS name.
        if !host.contains(".") && !host.contains(":") { return true }

        if let v4 = IPv4(host) { return v4.isPrivate }
        if host.contains(":") { return isPrivateIPv6(host) }

        return false
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        if host == "::1" || host == "::" { return true }
        // fc00::/7 unique-local and fe80::/10 link-local.
        if host.hasPrefix("fc") || host.hasPrefix("fd") { return true }
        if host.hasPrefix("fe8") || host.hasPrefix("fe9")
            || host.hasPrefix("fea") || host.hasPrefix("feb") { return true }
        // An IPv4-mapped address is still that IPv4 address.
        if let mapped = host.split(separator: ":").last.map(String.init),
           let v4 = IPv4(mapped) {
            return v4.isPrivate
        }
        return false
    }

    /// A dotted-quad address, for range checks only.
    private struct IPv4 {
        let octets: [Int]

        init?(_ text: String) {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var octets: [Int] = []
            for part in parts {
                guard let value = Int(part), (0...255).contains(value),
                      !part.isEmpty else { return nil }
                octets.append(value)
            }
            self.octets = octets
        }

        var isPrivate: Bool {
            switch (octets[0], octets[1]) {
            case (0, _), (10, _), (127, _):                     return true
            case (169, 254):                                    return true   // link-local
            case (172, 16...31):                                return true
            case (192, 168):                                    return true
            case (100, 64...127):                               return true   // carrier NAT
            case (192, 0):                                      return true   // 192.0.0/24, 192.0.2/24
            case (198, 18), (198, 19):                          return true   // benchmarking
            case (203, 0):                                      return true   // documentation
            case (224...255, _):                                return true   // multicast and reserved
            default:                                            return false
            }
        }
    }
}
