import Testing
import CoreGraphics
@testable import PeekCore

@Suite("ImageBudget")
struct ImageBudgetTests {

    @Test("leaves an image already within budget untouched")
    func passesThroughSmallImages() {
        let size = CGSize(width: 800, height: 600)
        #expect(ImageBudget.targetSize(for: size) == size)
        #expect(ImageBudget.needsDownscale(size) == false)
    }

    @Test("scales a Retina screenshot to the longest-edge limit")
    func downscalesLargeImages() {
        // A typical 6K Retina capture.
        let result = ImageBudget.targetSize(for: CGSize(width: 6016, height: 3384))
        #expect(max(result.width, result.height) == ImageBudget.maxDimension)
        #expect(ImageBudget.needsDownscale(CGSize(width: 6016, height: 3384)))
    }

    @Test("preserves aspect ratio when scaling")
    func preservesAspectRatio() {
        let original = CGSize(width: 4000, height: 2000)
        let result = ImageBudget.targetSize(for: original)
        let originalRatio = original.width / original.height
        let resultRatio = result.width / result.height
        #expect(abs(originalRatio - resultRatio) < 0.01)
    }

    @Test("scales by the taller edge for portrait images")
    func handlesPortrait() {
        let result = ImageBudget.targetSize(for: CGSize(width: 1000, height: 5000))
        #expect(result.height == ImageBudget.maxDimension)
        #expect(result.width < result.height)
    }

    @Test("never produces a zero dimension on an extreme aspect ratio")
    func neverCollapsesToZero() {
        // A thin selection strip would otherwise round to zero width.
        let result = ImageBudget.targetSize(for: CGSize(width: 20000, height: 3))
        #expect(result.width > 0)
        #expect(result.height >= 1)
    }

    @Test("an image exactly at the limit is not resampled")
    func boundaryIsInclusive() {
        let size = CGSize(width: ImageBudget.maxDimension, height: 800)
        #expect(ImageBudget.targetSize(for: size) == size)
        #expect(ImageBudget.needsDownscale(size) == false)
    }

    @Test("degenerate sizes yield zero rather than crashing")
    func handlesDegenerateSizes() {
        #expect(ImageBudget.targetSize(for: .zero) == .zero)
        #expect(ImageBudget.targetSize(for: CGSize(width: 100, height: 0)) == .zero)
    }
}

@Suite("PromptComposer attachments")
struct PromptComposerAttachmentTests {

    private let image = ImageAttachment(mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))

    @Test("an attachment alone is enough to send")
    func attachmentEnablesSend() {
        #expect(PromptComposer.canSend(prompt: "", context: nil, attachments: [image]))
        #expect(PromptComposer.canSend(prompt: "", context: nil, attachments: []) == false)
    }

    @Test("places the image before the question")
    func imagePrecedesText() {
        let message = PromptComposer.userMessage(prompt: "what is this?",
                                                 context: nil,
                                                 attachments: [image])
        #expect(message.parts.count == 2)
        if case .image = message.parts[0] {} else { Issue.record("expected image first") }
        if case .text(let text) = message.parts[1] {
            #expect(text == "what is this?")
        } else {
            Issue.record("expected trailing text part")
        }
    }

    @Test("substitutes the implicit prompt for an image with no question")
    func implicitPromptForBareImage() {
        let message = PromptComposer.userMessage(prompt: "", context: nil, attachments: [image])
        #expect(message.plainText == PromptComposer.implicitPrompt)
    }

    @Test("combines a screenshot with a text selection")
    func combinesImageAndSelection() {
        let context = SelectionContext(text: "obtund", sourceAppName: "Notes")
        let message = PromptComposer.userMessage(prompt: "explain",
                                                 context: context,
                                                 attachments: [image])
        #expect(message.parts.count == 2)
        #expect(message.plainText.contains("obtund"))
        #expect(message.plainText.contains("explain"))
    }
}

import Foundation
