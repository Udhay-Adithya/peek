import Foundation

public struct HTTPRequestSpec: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String = "POST",
                headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponseHead: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]

    public init(statusCode: Int, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.headers = headers
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// The transport seam.
///
/// Deliberately expressed in plain value types and a stream of lines rather
/// than `URLRequest`/`URLSession`: it makes every provider adapter testable
/// against recorded fixtures with no network, no sockets and no timing.
public protocol StreamingHTTPClient: Sendable {
    func stream(_ request: HTTPRequestSpec) async throws
        -> (HTTPResponseHead, AsyncThrowingStream<String, Error>)
}

/// `URLSession`-backed transport.
public struct URLSessionStreamingClient: StreamingHTTPClient {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func stream(_ request: HTTPRequestSpec) async throws
        -> (HTTPResponseHead, AsyncThrowingStream<String, Error>) {

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AssistantTransportError.notHTTP
        }

        let head = HTTPResponseHead(
            statusCode: http.statusCode,
            headers: Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value in
                guard let key = key as? String, let value = value as? String else { return nil }
                return (key, value)
            })
        )

        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancelling the consuming stream must tear down the HTTP read,
            // otherwise a dismissed panel leaves a request running.
            continuation.onTermination = { _ in task.cancel() }
        }

        return (head, lines)
    }
}

public enum AssistantTransportError: Error, Equatable, Sendable {
    case notHTTP
}
