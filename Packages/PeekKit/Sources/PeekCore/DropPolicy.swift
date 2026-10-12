import Foundation

/// What Peek does with something dropped on it.
///
/// Separated from the drag machinery so the rules — which types are accepted,
/// how large a file may be, what a PDF becomes — are stated once and testable
/// without a pasteboard or a mouse.
public enum DropPolicy {

    /// How a dropped item should be treated.
    public enum Kind: Sendable, Equatable {
        /// Attached as an image for the model to look at.
        case image
        /// Text extracted and supplied as context; rendered as an image when
        /// the document has no text layer.
        case pdf
        /// Read and supplied as context.
        case text
        case unsupported
    }

    /// Upper bound on a text file read into context.
    ///
    /// A dropped log or source file can be enormous, and the whole of it would
    /// be truncated by ``CapturePolicy`` anyway — reading a gigabyte off disk
    /// to then discard most of it helps nobody.
    public static let maxTextFileBytes = 2 * 1_024 * 1_024

    /// Upper bound on an image file before it is even decoded.
    ///
    /// Decoding is where the memory goes: a 200MB TIFF becomes far more than
    /// that in memory before any downscale can apply.
    public static let maxImageFileBytes = 80 * 1_024 * 1_024

    /// Classifies by uniform type identifier and its conformances.
    ///
    /// Takes the conformance chain rather than just the leading identifier,
    /// because the interesting cases are subtypes — a `.swift` file is plain
    /// text, a `.heic` is an image — and matching exact identifiers would
    /// reject most of what people actually drop.
    public static func kind(for identifier: String, conformsTo: [String]) -> Kind {
        let all = [identifier] + conformsTo

        if all.contains("com.adobe.pdf") { return .pdf }
        if all.contains("public.image") { return .image }
        // Checked after image and PDF: both can claim data conformance.
        if all.contains("public.text") || all.contains("public.plain-text") { return .text }
        return .unsupported
    }

    /// Whether a file of this kind and size is worth opening.
    public static func acceptsFile(kind: Kind, byteCount: Int) -> Bool {
        switch kind {
        case .image:       return byteCount > 0 && byteCount <= maxImageFileBytes
        case .pdf:         return byteCount > 0 && byteCount <= maxImageFileBytes
        case .text:        return byteCount > 0 && byteCount <= maxTextFileBytes
        case .unsupported: return false
        }
    }

    /// A human explanation for a refusal, or `nil` when accepted.
    public static func refusalReason(kind: Kind, byteCount: Int) -> String? {
        guard !acceptsFile(kind: kind, byteCount: byteCount) else { return nil }
        switch kind {
        case .unsupported:
            return "Peek can read text, images and PDFs."
        case .text where byteCount > maxTextFileBytes:
            return "That text file is too large to read."
        case .image, .pdf where byteCount > maxImageFileBytes:
            return "That file is too large to open."
        default:
            return "That file is empty."
        }
    }
}
