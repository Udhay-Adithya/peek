import Foundation

/// Splits a byte stream into lines, **preserving empty ones**.
///
/// Exists because Foundation's `AsyncLineSequence` (`bytes.lines`) discards
/// empty lines. That is fatal for server-sent events, where a blank line is
/// what dispatches an event: without it every `data:` payload accumulates and
/// the whole response decodes as one malformed blob. Measured against a real
/// Gemini stream, `.lines` emitted five data lines and not one of the five
/// blank separators between them.
///
/// Synchronous and byte-at-a-time so the framing rule is a plain unit test
/// rather than something only reproducible against a live socket.
struct LineBuffer {

    private var bytes: [UInt8] = []

    /// Feeds one byte.
    /// - Returns: the completed line when this byte ended one, including `""`.
    mutating func append(_ byte: UInt8) -> String? {
        guard byte == 0x0A else {          // LF terminates a line
            bytes.append(byte)
            return nil
        }
        // Strip a single trailing CR so CRLF streams yield the same lines as
        // LF ones. Gemini frames its SSE with CRLF.
        if bytes.last == 0x0D { bytes.removeLast() }
        let line = String(decoding: bytes, as: UTF8.self)
        bytes.removeAll(keepingCapacity: true)
        return line
    }

    /// Returns any trailing bytes not terminated by a newline.
    mutating func flush() -> String? {
        guard !bytes.isEmpty else { return nil }
        if bytes.last == 0x0D { bytes.removeLast() }
        let line = String(decoding: bytes, as: UTF8.self)
        bytes.removeAll()
        return line
    }
}
