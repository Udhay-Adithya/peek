import Testing
import Foundation
import PeekCore
@testable import Peek

/// A dictation service with a scripted transcript and no microphone.
@MainActor
final class StubDictation: DictationServing {
    var state: DictationState = .idle {
        didSet { onStateChange?(state) }
    }
    var onTranscript: ((String) -> Void)?
    var onStateChange: ((DictationState) -> Void)?

    var startCount = 0
    var stopCount = 0
    /// Set to fail `start` the way a refused permission does.
    var failure: String?

    func start() async {
        startCount += 1
        if let failure {
            state = .failed(failure)
        } else {
            state = .listening
        }
    }

    func stop() {
        stopCount += 1
        if case .failed = state {} else { state = .idle }
    }

    /// Emits a transcript as the real service does while listening.
    func emit(_ text: String) { onTranscript?(text) }
}

@Suite("Dictation")
@MainActor
struct DictationTests {

    private func makeModel() -> (PanelViewModel, StubDictation) {
        let settings = makeTestSettings()
        let store = RecordingStore()
        let engine = StubEngine(provider: StubProvider(
            events: [.textDelta("answer"), .finished(.stop)], failure: nil, recorder: nil
        ))
        let session = AssistantSession(engine: engine, store: store)
        let dictation = StubDictation()

        let model = PanelViewModel(
            settings: settings,
            engine: engine,
            store: store,
            session: session,
            history: HistoryViewModel(store: store),
            capture: StubSelectionCapture(outcome: .empty(appName: "Notes")),
            clipboardCapture: StubClipboardCapture(outcome: .empty(appName: "Notes")),
            dictation: dictation
        )
        return (model, dictation)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("dictated text fills the composer")
    func fillsComposer() async {
        let (model, dictation) = makeModel()

        model.toggleDictation()
        await waitUntil { model.dictationState == .listening }

        dictation.emit("what does this error mean")
        #expect(model.prompt == "what does this error mean")
        #expect(model.isDictating)
    }

    @Test("a progressive transcript replaces the previous one rather than repeating it")
    func replacesPartials() async {
        let (model, dictation) = makeModel()
        model.toggleDictation()
        await waitUntil { model.dictationState == .listening }

        // The real transcriber reports a growing transcript, not increments.
        dictation.emit("what does")
        dictation.emit("what does this")
        dictation.emit("what does this mean")

        #expect(model.prompt == "what does this mean")
    }

    @Test("dictating after typing keeps what was typed")
    func appendsToTypedText() async {
        let (model, dictation) = makeModel()
        model.prompt = "translate this:"

        model.toggleDictation()
        await waitUntil { model.dictationState == .listening }
        dictation.emit("into french")

        #expect(model.prompt == "translate this: into french")
    }

    @Test("the button stops dictation it started")
    func togglesOff() async {
        let (model, dictation) = makeModel()

        model.toggleDictation()
        await waitUntil { model.dictationState == .listening }
        model.toggleDictation()

        #expect(dictation.startCount == 1)
        #expect(dictation.stopCount == 1)
        #expect(!model.isDictating)
    }

    @Test("sending stops the microphone")
    func sendingStops() async {
        let (model, dictation) = makeModel()

        model.toggleDictation()
        await waitUntil { model.dictationState == .listening }
        dictation.emit("a question")
        model.send()

        #expect(dictation.stopCount == 1)
        #expect(!model.isDictating)
    }

    @Test("a new invocation stops the microphone")
    func invocationStops() async {
        let (model, dictation) = makeModel()

        model.toggleDictation()
        await waitUntil { model.dictationState == .listening }
        model.prepareForInvocation()

        #expect(dictation.stopCount == 1)
    }

    @Test("refusing the microphone leaves typing unaffected")
    func refusedPermissionKeepsTyping() async {
        let (model, dictation) = makeModel()
        dictation.failure = "Microphone access is needed to dictate."
        model.prompt = "typed by hand"

        model.toggleDictation()
        await waitUntil { if case .failed = model.dictationState { return true }; return false }

        #expect(model.prompt == "typed by hand")
        #expect(!model.isDictating)
        // Still sendable: a refused permission must not block the normal path.
        #expect(model.canSend)
    }

    @Test("an empty transcript does not clear what was typed")
    func emptyTranscriptIsIgnored() async {
        let (model, dictation) = makeModel()
        model.prompt = "typed"

        model.toggleDictation()
        await waitUntil { model.dictationState == .listening }
        dictation.emit("")

        #expect(model.prompt == "typed")
    }
}
