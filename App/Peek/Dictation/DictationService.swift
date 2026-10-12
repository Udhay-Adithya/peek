import AVFoundation
import AppKit
import Foundation
import OSLog
import PeekCore
import Speech

/// Dictation state, as the composer needs to show it.
enum DictationState: Equatable {
    case idle
    /// Asking for microphone access, or fetching the on-device model.
    case preparing(String)
    case listening
    case failed(String)
}

/// Turns speech into text for the composer.
///
/// A protocol so the panel's dictation behaviour can be tested without a
/// microphone, a permission grant, or a downloaded model.
@MainActor
protocol DictationServing: AnyObject {
    var state: DictationState { get }
    /// Called with the transcript so far, repeatedly, as it is recognised.
    var onTranscript: ((String) -> Void)? { get set }
    /// Called whenever ``state`` changes, so an observable view model can
    /// mirror it. The service is a plain object, not `@Observable`, because it
    /// owns an audio engine rather than view state.
    var onStateChange: ((DictationState) -> Void)? { get set }
    func start() async
    func stop()
}

/// Dictation via Apple's on-device speech models.
///
/// Uses `SpeechAnalyzer` and `DictationTranscriber` — the macOS 26 API — rather
/// than `SFSpeechRecognizer`. The distinction matters for this app: the newer
/// models run on-device, so dictating a follow-up does not send audio to a
/// server, which would sit badly beside an assistant whose default provider is
/// local.
@MainActor
final class DictationService: DictationServing {

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "dictation")

    private(set) var state: DictationState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onTranscript: ((String) -> Void)?
    var onStateChange: ((DictationState) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var engine: AVAudioEngine?
    private var inputStream: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// Text accumulated across finalized segments.
    ///
    /// Progressive results replace the volatile tail repeatedly, so finalized
    /// text is kept separately — otherwise each update would overwrite
    /// everything said so far.
    private var finalizedText = ""

    /// Tears the audio graph down if the service is released while listening.
    ///
    /// Deliberately not a call to ``stop()``: that schedules a task, and
    /// escaping `self` from a deinit is unsound. Releasing the engine is what
    /// actually closes the microphone.
    isolated deinit {
        resultsTask?.cancel()
        inputStream?.finish()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    func start() async {
        guard case .idle = state else { return }

        state = .preparing("Checking microphone access…")
        guard await requestMicrophoneAccess() else {
            state = .failed("Microphone access is needed to dictate.")
            return
        }

        // Not `Locale.current` directly: see ``DictationLocale``.
        let supported = await DictationTranscriber.supportedLocales
        guard let locale = DictationLocale.resolve(preferred: .current, supported: supported) else {
            let name = Locale.current.localizedString(forLanguageCode:
                Locale.current.language.languageCode?.identifier ?? "") ?? "this language"
            state = .failed("Dictation is not available for \(name).")
            return
        }

        let transcriber = DictationTranscriber(locale: locale,
                                               preset: .progressiveShortDictation)
        self.transcriber = transcriber

        state = .preparing("Preparing the speech model…")
        do {
            // The model is downloaded on first use. Reported rather than
            // silently waited on, because it can take a noticeable moment.
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await request.downloadAndInstall()
            }
            // Reserving keeps the installed assets from being reclaimed. The
            // system allows a handful per app; failing to reserve costs a
            // re-download later, not this attempt, so it is not fatal.
            _ = try? await AssetInventory.reserve(locale: locale)
        } catch {
            Self.logger.error("speech asset install failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("The speech model could not be prepared.")
            return
        }

        // The recogniser wants a specific format — 16kHz mono on current
        // systems — which is never what the microphone hands over. Feeding it
        // the input node's own format produces no transcript at all rather
        // than an error, so the buffers are converted.
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        do {
            try startAudio(feeding: transcriber, converting: analyzerFormat)
        } catch {
            Self.logger.error("audio start failed: \(error.localizedDescription, privacy: .public)")
            stop()
            state = .failed("The microphone could not be started.")
            return
        }

        finalizedText = ""
        state = .listening
        Self.logger.info("dictation started")
    }

    func stop() {
        resultsTask?.cancel()
        resultsTask = nil

        inputStream?.finish()
        inputStream = nil

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        let analyzer = self.analyzer
        self.analyzer = nil
        transcriber = nil

        // Finishing is best-effort: the user has already stopped, and a
        // failure here changes nothing they can see.
        Task { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }

        if case .failed = state {} else { state = .idle }
    }

    // MARK: - Audio

    private func startAudio(feeding transcriber: DictationTranscriber,
                            converting analyzerFormat: AVAudioFormat?) throws {
        let engine = AVAudioEngine()
        self.engine = engine

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "Peek.Dictation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio input."])
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputStream = continuation

        let converter = analyzerFormat.flatMap { AudioFormatConverter(from: format, to: $0) }
        if analyzerFormat != nil && converter == nil {
            Self.logger.error("no converter from input format; feeding microphone format directly")
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
            guard let converter else {
                continuation.yield(AnalyzerInput(buffer: buffer))
                return
            }
            if let converted = converter.convert(buffer) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }

        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber])
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    self?.handle(result)
                }
            } catch {
                Self.logger.error("transcription ended: \(error.localizedDescription, privacy: .public)")
            }
        }

        engine.prepare()
        try engine.start()
    }

    private func handle(_ result: DictationTranscriber.Result) {
        let text = String(result.text.characters)

        // A progressive transcriber reports a volatile tail that is replaced as
        // it firms up. Appending every update would repeat words; replacing
        // everything would lose earlier sentences. Finalized segments
        // accumulate, and only the tail is transient.
        if result.isFinal {
            finalizedText += finalizedText.isEmpty ? text : " \(text)"
            onTranscript?(finalizedText)
        } else {
            let combined = finalizedText.isEmpty ? text : "\(finalizedText) \(text)"
            onTranscript?(combined)
        }
    }

    // MARK: - Permission and availability

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            // Requested at the point of use, like every other permission here.
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}

/// Microphone permission, requested only when dictation is attempted.
enum MicrophonePermission {

    static var isGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Converts microphone buffers into the format the recogniser expects.
///
/// `@unchecked Sendable` because `AVAudioConverter` is not `Sendable` but is
/// only ever touched from the audio tap, which Core Audio invokes serially on
/// one thread. Nothing else holds a reference.
private final class AudioFormatConverter: @unchecked Sendable {

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    /// The buffer being handed to the converter.
    ///
    /// Held here rather than captured by the input block: a captured `var` is
    /// not expressible as safe under strict concurrency, while a property of
    /// this (audio-thread-serialized) object is.
    private var pending: AVAudioPCMBuffer?

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter
        self.outputFormat = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // Sample-rate conversion means the output frame count differs from the
        // input's, so capacity is derived from the ratio rather than copied.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        pending = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { [self] _, inputStatus in
            // The whole buffer is offered once; asking again means the
            // converter has drained it.
            guard let next = pending else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            pending = nil
            inputStatus.pointee = .haveData
            return next
        }
        pending = nil

        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
