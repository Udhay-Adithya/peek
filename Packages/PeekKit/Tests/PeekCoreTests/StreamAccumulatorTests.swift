import Testing
import Foundation
@testable import PeekCore

@Suite("StreamAccumulator")
struct StreamAccumulatorTests {

    @Test("concatenates text deltas in arrival order")
    func concatenatesText() throws {
        var acc = StreamAccumulator()
        for chunk in ["Force ", "Touch ", "trackpad"] {
            try acc.apply(.textDelta(chunk))
        }
        #expect(acc.text == "Force Touch trackpad")
        #expect(acc.isFinished == false)
    }

    @Test("keeps reasoning separate from user-visible text")
    func separatesReasoning() throws {
        var acc = StreamAccumulator()
        try acc.apply(.reasoningDelta("considering"))
        try acc.apply(.textDelta("answer"))
        #expect(acc.text == "answer")
        #expect(acc.reasoning == "considering")
    }

    @Test("records usage and terminal reason")
    func recordsUsageAndFinish() throws {
        var acc = StreamAccumulator()
        try acc.apply(.responseStarted(id: "resp_1"))
        try acc.apply(.textDelta("hi"))
        try acc.apply(.usage(TokenUsage(inputTokens: 12, outputTokens: 3)))
        try acc.apply(.finished(.stop))

        #expect(acc.responseID == "resp_1")
        #expect(acc.usage?.totalTokens == 15)
        #expect(acc.finishReason == .stop)
        #expect(acc.isFinished)
    }

    @Test("rejects a second terminal event")
    func rejectsDuplicateTerminal() throws {
        var acc = StreamAccumulator()
        try acc.apply(.finished(.stop))
        #expect(throws: StreamProtocolError.duplicateTerminalEvent) {
            try acc.apply(.finished(.maxTokens))
        }
    }

    @Test("rejects content arriving after finish")
    func rejectsLateContent() throws {
        var acc = StreamAccumulator()
        try acc.apply(.finished(.stop))
        #expect(throws: StreamProtocolError.eventAfterFinish) {
            try acc.apply(.textDelta("late"))
        }
    }

    @Test("a cancelled stream still reduces to a usable partial result")
    func cancellationKeepsPartialText() throws {
        var acc = StreamAccumulator()
        try acc.apply(.textDelta("partial ans"))
        try acc.apply(.finished(.cancelled))
        #expect(acc.text == "partial ans")
        #expect(acc.finishReason == .cancelled)
    }
}
