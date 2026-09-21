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

@Suite("StreamAccumulator snapshots")
struct StreamAccumulatorSnapshotTests {

    @Test("a snapshot replaces the text rather than appending")
    func snapshotReplaces() throws {
        var acc = StreamAccumulator()
        try acc.apply(.textSnapshot("Force"))
        try acc.apply(.textSnapshot("Force Touch"))
        try acc.apply(.textSnapshot("Force Touch trackpad"))
        #expect(acc.text == "Force Touch trackpad")
    }

    @Test("a snapshot that revises earlier text is handled correctly")
    func snapshotHandlesRevision() throws {
        // The on-device model can rewrite what it already emitted. Diffing
        // snapshots into deltas would produce "Thehe cat" here.
        var acc = StreamAccumulator()
        try acc.apply(.textSnapshot("The dog"))
        try acc.apply(.textSnapshot("The cat sat"))
        #expect(acc.text == "The cat sat")
    }

    @Test("a shorter snapshot truncates rather than leaving stale text")
    func snapshotCanShrink() throws {
        var acc = StreamAccumulator()
        try acc.apply(.textSnapshot("a long first attempt"))
        try acc.apply(.textSnapshot("short"))
        #expect(acc.text == "short")
    }

    @Test("snapshots and terminal events combine as usual")
    func snapshotsWithFinish() throws {
        var acc = StreamAccumulator()
        try acc.apply(.textSnapshot("done"))
        try acc.apply(.finished(.stop))
        #expect(acc.text == "done")
        #expect(acc.isFinished)
    }

    @Test("a snapshot after finish is rejected like any other late event")
    func lateSnapshotRejected() throws {
        var acc = StreamAccumulator()
        try acc.apply(.finished(.stop))
        #expect(throws: StreamProtocolError.eventAfterFinish) {
            try acc.apply(.textSnapshot("late"))
        }
    }
}
