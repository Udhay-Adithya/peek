import Testing
import AVFoundation
import Foundation
@testable import Peek

/// Exercises the real ``DictationService`` against real audio hardware.
///
/// This exists because of a crash that no stub could have caught: the audio tap
/// closure inherited `@MainActor` isolation, so the compiler planted an
/// executor assertion inside a block Core Audio calls on a realtime thread, and
/// the app trapped on the first microphone buffer — after the UI had already
/// shown "listening". Every stubbed test passed while dictation was unusable.
///
/// Skipped unless a microphone is present and already authorized, so CI and a
/// machine without an input device report no failure.
@Suite("Dictation service (live audio)", .serialized)
@MainActor
struct DictationServiceLiveTests {

    nonisolated private static var canRecord: Bool {
        MicrophonePermission.isGranted && AVCaptureDevice.default(for: .audio) != nil
    }

    @Test("starting dictation survives real microphone buffers",
          .enabled(if: DictationServiceLiveTests.canRecord))
    func survivesRealAudio() async throws {
        let service = DictationService()
        var transcripts: [String] = []
        service.onTranscript = { transcripts.append($0) }

        await service.start()

        // A failure here is a real refusal (no model, no input), not the crash
        // this test guards; report it rather than asserting blindly.
        if case .failed(let message) = service.state {
            Issue.record("dictation refused to start: \(message)")
            return
        }

        #expect(service.state == .listening)

        // The crash fired on the first buffer, well inside a second. Staying
        // alive through a stretch of real audio is the whole assertion: if the
        // executor check were still in the tap, this process would be gone.
        try await Task.sleep(for: .seconds(2))

        #expect(service.state == .listening, "dictation stopped on its own")

        service.stop()
        #expect(service.state == .idle)
        // Transcripts depend on someone speaking, so their absence proves
        // nothing and is deliberately not asserted.
        _ = transcripts
    }

    @Test("stopping without ever starting is harmless")
    func stopWithoutStart() {
        let service = DictationService()
        service.stop()
        #expect(service.state == .idle)
    }
}
