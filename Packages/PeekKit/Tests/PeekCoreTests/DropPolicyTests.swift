import Testing
import Foundation
@testable import PeekCore

@Suite("DropPolicy")
struct DropPolicyTests {

    @Test("recognises an image by its conformance, not its exact type")
    func recognisesImageSubtypes() {
        // Matching exact identifiers would reject most of what people drop.
        #expect(DropPolicy.kind(for: "public.heic", conformsTo: ["public.image", "public.data"]) == .image)
        #expect(DropPolicy.kind(for: "public.png", conformsTo: ["public.image"]) == .image)
    }

    @Test("recognises a PDF")
    func recognisesPDF() {
        #expect(DropPolicy.kind(for: "com.adobe.pdf", conformsTo: ["public.data"]) == .pdf)
    }

    @Test("recognises source files as text")
    func recognisesTextSubtypes() {
        #expect(DropPolicy.kind(for: "public.swift-source",
                                conformsTo: ["public.plain-text", "public.text"]) == .text)
        #expect(DropPolicy.kind(for: "public.json",
                                conformsTo: ["public.text", "public.data"]) == .text)
    }

    @Test("prefers PDF over text for a PDF that also claims text")
    func pdfWinsOverText() {
        // A searchable PDF conforms to both; treating it as text would read
        // the raw file rather than the document.
        #expect(DropPolicy.kind(for: "com.adobe.pdf",
                                conformsTo: ["public.data", "public.text"]) == .pdf)
    }

    @Test("prefers image over text for an image that also claims data")
    func imageWinsOverText() {
        #expect(DropPolicy.kind(for: "public.svg-image",
                                conformsTo: ["public.image", "public.text"]) == .image)
    }

    @Test("refuses what it cannot read")
    func refusesUnsupported() {
        #expect(DropPolicy.kind(for: "public.archive", conformsTo: ["public.data"]) == .unsupported)
        #expect(DropPolicy.acceptsFile(kind: .unsupported, byteCount: 100) == false)
    }

    @Test("refuses an empty file")
    func refusesEmpty() {
        #expect(DropPolicy.acceptsFile(kind: .text, byteCount: 0) == false)
        #expect(DropPolicy.refusalReason(kind: .text, byteCount: 0) == "That file is empty.")
    }

    @Test("caps a text file well below what would be sent anyway")
    func capsTextFiles() {
        // CapturePolicy truncates to 8k characters regardless, so reading a
        // gigabyte off disk to discard nearly all of it helps nobody.
        #expect(DropPolicy.acceptsFile(kind: .text, byteCount: DropPolicy.maxTextFileBytes))
        #expect(DropPolicy.acceptsFile(kind: .text,
                                       byteCount: DropPolicy.maxTextFileBytes + 1) == false)
    }

    @Test("caps image files before they are decoded")
    func capsImageFiles() {
        // Decoding is where the memory goes: a 200MB TIFF becomes far more
        // than that in memory before any downscale can apply.
        #expect(DropPolicy.acceptsFile(kind: .image, byteCount: DropPolicy.maxImageFileBytes))
        #expect(DropPolicy.acceptsFile(kind: .image,
                                       byteCount: DropPolicy.maxImageFileBytes + 1) == false)
    }

    @Test("explains a refusal in terms a person can act on")
    func explainsRefusals() {
        #expect(DropPolicy.refusalReason(kind: .unsupported, byteCount: 10)?
            .contains("text, images and PDFs") == true)
        #expect(DropPolicy.refusalReason(kind: .text,
                                         byteCount: DropPolicy.maxTextFileBytes + 1)?
            .contains("too large") == true)
        #expect(DropPolicy.refusalReason(kind: .image, byteCount: 1_000) == nil)
    }
}
