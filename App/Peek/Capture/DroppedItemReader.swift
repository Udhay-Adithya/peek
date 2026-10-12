import AppKit
import OSLog
import PDFKit
import PeekCore
import UniformTypeIdentifiers

/// Turns something dropped on Peek into context or an attachment.
@MainActor
struct DroppedItemReader {

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "drop")

    enum Payload {
        /// Supplied as context, as though it had been selected.
        case text(String, sourceName: String)
        /// Attached for the model to look at.
        case image(ImageAttachment, sourceName: String)
    }

    enum Failure: LocalizedError, Equatable {
        case refused(String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .refused(let reason): return reason
            case .unreadable:         return "That file could not be read."
            }
        }
    }

    func read(fileAt url: URL) throws -> Payload {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let type = values?.contentType
        let size = values?.fileSize ?? 0

        let kind = DropPolicy.kind(
            for: type?.identifier ?? "",
            conformsTo: type?.supertypes.map(\.identifier) ?? []
        )

        if let reason = DropPolicy.refusalReason(kind: kind, byteCount: size) {
            Self.logger.debug("drop refused kind=\(String(describing: kind), privacy: .public) bytes=\(size, privacy: .public)")
            throw Failure.refused(reason)
        }

        let name = url.lastPathComponent
        switch kind {
        case .text:
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                throw Failure.unreadable
            }
            return .text(contents, sourceName: name)

        case .image:
            guard let attachment = imageAttachment(at: url) else { throw Failure.unreadable }
            return .image(attachment, sourceName: name)

        case .pdf:
            return try readPDF(at: url, name: name)

        case .unsupported:
            throw Failure.refused("Peek can read text, images and PDFs.")
        }
    }

    /// Text dragged directly, rather than a file.
    func read(text: String) throws -> Payload {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.refused("There was no text in that.")
        }
        return .text(text, sourceName: "Dropped text")
    }

    // MARK: - PDF

    /// Prefers the document's text layer, falling back to rendering a page.
    ///
    /// A text layer is better in every way when present — exact, cheap, and
    /// unlimited in length. A scanned PDF has none, and rendering the first
    /// page at least gives the model something to look at rather than failing.
    private func readPDF(at url: URL, name: String) throws -> Payload {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable }

        if let text = document.string,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text, sourceName: name)
        }

        guard let page = document.page(at: 0) else { throw Failure.unreadable }
        let bounds = page.bounds(for: .mediaBox)
        let target = ImageBudget.targetSize(for: bounds.size)

        let image = NSImage(size: target, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(.white)
            context.fill(rect)
            context.scaleBy(x: rect.width / bounds.width, y: rect.height / bounds.height)
            page.draw(with: .mediaBox, to: context)
            return true
        }

        var proposed = CGRect(origin: .zero, size: target)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let attachment = ImageEncoder.attachment(from: cgImage) else {
            throw Failure.unreadable
        }
        Self.logger.debug("pdf had no text layer, rendered page 1")
        return .image(attachment, sourceName: name)
    }

    // MARK: - Images

    private func imageAttachment(at url: URL) -> ImageAttachment? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return ImageEncoder.attachment(from: image)
    }
}
