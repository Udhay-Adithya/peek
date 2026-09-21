import Testing
import Foundation
@testable import PeekCore

@Suite("PromptComposer")
struct PromptComposerTests {

    private func context(_ text: String,
                         app: String? = "Notes",
                         truncated: Bool = false) -> SelectionContext {
        SelectionContext(text: text, sourceAppName: app, wasTruncated: truncated)
    }

    @Test("a bare prompt passes through unchanged")
    func promptOnly() {
        let message = PromptComposer.userMessage(prompt: "what is a monad", context: nil)
        #expect(message.role == .user)
        #expect(message.plainText == "what is a monad")
    }

    @Test("trims surrounding whitespace from the prompt")
    func trimsPrompt() {
        let message = PromptComposer.userMessage(prompt: "  hello\n ", context: nil)
        #expect(message.plainText == "hello")
    }

    @Test("fences the selection and names its source app")
    func fencesSelection() {
        let message = PromptComposer.userMessage(prompt: "translate this",
                                                 context: context("Hola mundo"))
        let text = message.plainText
        #expect(text.contains("Selected text from Notes:"))
        #expect(text.contains("Hola mundo"))
        #expect(text.contains("translate this"))
        // The fence is a prompt-injection boundary, not just formatting.
        #expect(text.contains("\"\"\""))
    }

    @Test("substitutes an implicit question when the user types nothing")
    func implicitPromptWithContext() {
        let message = PromptComposer.userMessage(prompt: "", context: context("obtund"))
        #expect(message.plainText.contains(PromptComposer.implicitPrompt))
        #expect(message.plainText.contains("obtund"))
    }

    @Test("notes truncation so the model knows the selection is partial")
    func mentionsTruncation() {
        let message = PromptComposer.userMessage(prompt: "summarise",
                                                 context: context("long text", truncated: true))
        #expect(message.plainText.contains("truncated"))
    }

    @Test("omits the source clause when the app is unknown")
    func handlesUnknownApp() {
        let message = PromptComposer.userMessage(prompt: "x", context: context("y", app: nil))
        #expect(message.plainText.contains("Selected text:"))
    }

    @Test("selection alone is enough to send, empty prompt alone is not")
    func canSendRules() {
        #expect(PromptComposer.canSend(prompt: "", context: context("something")))
        #expect(PromptComposer.canSend(prompt: "ask", context: nil))
        #expect(PromptComposer.canSend(prompt: "", context: nil) == false)
        #expect(PromptComposer.canSend(prompt: "   \n ", context: nil) == false)
    }

    // MARK: - Titles

    @Test("titles from the prompt when one was typed")
    func titleFromPrompt() {
        let title = PromptComposer.title(fromPrompt: "what is a monad",
                                         context: context("unrelated selection"))
        #expect(title == "what is a monad")
    }

    @Test("falls back to the selection when no prompt was typed")
    func titleFromSelection() {
        #expect(PromptComposer.title(fromPrompt: "", context: context("obtund")) == "obtund")
    }

    @Test("collapses newlines and runs of whitespace")
    func titleCollapsesWhitespace() {
        let title = PromptComposer.title(fromPrompt: "line one\n\n   line two", context: nil)
        #expect(title == "line one line two")
    }

    @Test("truncates long titles with an ellipsis")
    func titleTruncates() {
        let title = PromptComposer.title(fromPrompt: String(repeating: "word ", count: 40),
                                         context: nil)
        #expect(title.count <= 50)
        #expect(title.hasSuffix("…"))
    }

    @Test("falls back to a placeholder when there is nothing to title with")
    func titlePlaceholder() {
        #expect(PromptComposer.title(fromPrompt: "", context: nil) == "New Conversation")
        #expect(PromptComposer.title(fromPrompt: "   ", context: nil) == "New Conversation")
    }
}
