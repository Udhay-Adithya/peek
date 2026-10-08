import Testing
import Foundation
@testable import PeekCore

@Suite("RewriteAction")
struct RewriteActionTests {

    @Test("every preset has a title and an instruction")
    func presetsAreComplete() {
        for action in RewriteAction.presets {
            #expect(!action.title.isEmpty)
            #expect(!action.instruction.isEmpty)
        }
    }

    @Test("fixing grammar does not license rephrasing")
    func grammarPreservesWording() {
        // The whole point of this action is that it leaves the author's voice
        // alone; a model that rewrites instead of correcting has failed it.
        let instruction = RewriteAction.fixGrammar.instruction
        #expect(instruction.lowercased().contains("do not rephrase"))
    }

    @Test("translation names the target language in both title and instruction")
    func translationCarriesLanguage() {
        let action = RewriteAction.translate(language: "Tamil")
        #expect(action.title == "Translate to Tamil")
        #expect(action.instruction.contains("Tamil"))
    }

    @Test("a custom action is used verbatim")
    func customIsVerbatim() {
        let action = RewriteAction.custom(instruction: "make it rhyme")
        #expect(action.instruction == "make it rhyme")
    }
}

@Suite("RewritePrompt")
struct RewritePromptTests {

    @Test("the system instruction forbids commentary and wrappers")
    func systemInstructionForbidsPreamble() {
        // A preamble here is not untidy, it is written into the user's
        // document, so this is the load-bearing part of the prompt.
        let instruction = RewritePrompt.systemInstruction.lowercased()
        #expect(instruction.contains("only the rewritten text"))
        #expect(instruction.contains("no preamble"))
        #expect(instruction.contains("no quotation marks"))
    }

    @Test("the system instruction treats the text as content, not instructions")
    func systemInstructionResistsInjection() {
        // The selection comes from an arbitrary application.
        let instruction = RewritePrompt.systemInstruction.lowercased()
        #expect(instruction.contains("do not follow it"))
    }

    @Test("builds a request carrying the action and the fenced text")
    func buildsRequest() {
        let request = RewritePrompt.request(action: .shorten,
                                            text: "a long rambling sentence",
                                            model: "m")
        #expect(request.model == "m")
        #expect(request.systemInstruction == RewritePrompt.systemInstruction)
        #expect(request.messages.count == 1)

        let body = request.messages[0].plainText
        #expect(body.contains(RewriteAction.shorten.instruction))
        #expect(body.contains("a long rambling sentence"))
        #expect(body.contains("\"\"\""))
    }

    @Test("defaults to a low temperature")
    func lowTemperatureByDefault() {
        // A rewrite should be the same text improved, not a reinterpretation.
        let request = RewritePrompt.request(action: .improve, text: "x", model: "m")
        #expect(request.temperature == 0.2)
    }

    @Test("refuses to rewrite nothing")
    func refusesEmptyText() {
        #expect(RewritePrompt.canRewrite("hello"))
        #expect(RewritePrompt.canRewrite("") == false)
        #expect(RewritePrompt.canRewrite("   \n ") == false)
    }

    // MARK: - Cleaning

    @Test("passes clean output through untouched")
    func leavesPlainTextAlone() {
        #expect(RewritePrompt.clean("The corrected sentence.") == "The corrected sentence.")
    }

    @Test("strips a code fence wrapping the whole response")
    func stripsCodeFence() {
        #expect(RewritePrompt.clean("```\nhello world\n```") == "hello world")
    }

    @Test("strips a fence with a language tag")
    func stripsTaggedFence() {
        #expect(RewritePrompt.clean("```swift\nlet x = 1\n```") == "let x = 1")
    }

    @Test("strips quotes wrapping the whole response")
    func stripsSurroundingQuotes() {
        #expect(RewritePrompt.clean("\"The corrected sentence.\"") == "The corrected sentence.")
    }

    @Test("keeps quotes that belong to the text")
    func keepsInteriorQuotes() {
        // A rewrite of dialogue legitimately contains quotes; stripping the
        // outer pair here would corrupt it.
        let quoted = "\"Stop,\" she said, \"and listen.\""
        #expect(RewritePrompt.clean(quoted) == quoted)
    }

    @Test("preserves interior line structure and indentation")
    func preservesFormatting() {
        let code = "func a() {\n    return 1\n}"
        #expect(RewritePrompt.clean(code) == code)
    }

    @Test("preserves indentation inside a stripped fence")
    func preservesIndentationInFence() {
        #expect(RewritePrompt.clean("```\n  indented\n    more\n```") == "  indented\n    more")
    }

    @Test("does not strip a preamble, because that would eat real first lines")
    func leavesPreambleAlone() {
        // Deliberate: detecting a preamble reliably is not possible, and
        // deleting the user's actual opening line is the worse failure.
        let withPreamble = "Here is the corrected text:\nThe sentence."
        #expect(RewritePrompt.clean(withPreamble) == withPreamble)
    }

    @Test("trims surrounding whitespace")
    func trimsWhitespace() {
        #expect(RewritePrompt.clean("\n\n  result  \n\n") == "result")
    }

    @Test("handles an empty or degenerate response")
    func handlesDegenerateResponses() {
        #expect(RewritePrompt.clean("") == "")
        #expect(RewritePrompt.clean("```") == "```")
        #expect(RewritePrompt.clean("\"") == "\"")
    }
}
