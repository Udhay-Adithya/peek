import AppKit
import Observation
import OSLog
import PeekCore
import PeekProviders

/// One rewrite, from invocation to replacement.
///
/// Separate from ``PanelViewModel`` because the shapes genuinely differ: a
/// conversation accumulates turns, whereas a rewrite is a single transformation
/// with one decision at the end — accept it or do not.
@MainActor
@Observable
final class RewriteViewModel {

    enum Phase: Equatable {
        case running
        case proposed
        case replaced(via: SelectionWriter.Route)
        case failed(String)
    }

    /// The text as the user had it. Kept for the whole lifetime so it can
    /// always be handed back.
    let original: String
    let sourceAppName: String?

    private(set) var action: RewriteAction
    private(set) var proposed: String = ""
    private(set) var phase: Phase = .running
    private(set) var didCopyOriginal = false

    private let engine: any ProviderResolving
    private let writer: SelectionWriter
    private let frontApp: FrontmostApp?
    private var task: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "rewrite")

    init(original: String,
         action: RewriteAction,
         frontApp: FrontmostApp?,
         engine: any ProviderResolving,
         writer: SelectionWriter = SelectionWriter()) {
        self.original = original
        self.action = action
        self.frontApp = frontApp
        self.sourceAppName = frontApp?.name
        self.engine = engine
        self.writer = writer
    }

    var canReplace: Bool {
        guard case .proposed = phase else { return false }
        return !proposed.isEmpty && proposed != original
    }

    /// True when the model handed back something indistinguishable from the
    /// input — worth saying plainly rather than offering a no-op replacement.
    var isUnchanged: Bool {
        guard case .proposed = phase else { return false }
        return proposed == original
    }

    // MARK: - Running

    func run() {
        task?.cancel()
        phase = .running
        proposed = ""

        let request = RewritePrompt.request(action: action,
                                            text: original,
                                            model: engine.selectedModelID)
        let provider = engine.currentProvider()

        task = Task { [weak self] in
            var accumulator = StreamAccumulator()
            do {
                for try await event in provider.stream(request) {
                    try Task.checkCancellation()
                    try accumulator.apply(event)
                    // Streamed into the preview so a long rewrite shows
                    // progress rather than sitting blank.
                    switch event {
                    case .textDelta, .textSnapshot:
                        self?.proposed = accumulator.text
                    default:
                        break
                    }
                }
                self?.finish(with: accumulator)
            } catch is CancellationError {
                // cancel() owns the resulting state.
            } catch {
                let message = (error as? AssistantError)?.errorDescription
                    ?? error.localizedDescription
                self?.phase = .failed(message)
            }
        }
    }

    private func finish(with accumulator: StreamAccumulator) {
        let cleaned = RewritePrompt.clean(accumulator.text)
        guard !cleaned.isEmpty else {
            phase = .failed("The model returned nothing.")
            return
        }
        proposed = cleaned
        phase = .proposed
    }

    func change(to action: RewriteAction) {
        self.action = action
        run()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - Applying

    func replace() {
        guard canReplace else { return }
        do {
            let route = try writer.replaceSelection(with: proposed, in: frontApp)
            phase = .replaced(via: route)
            Self.logger.debug("rewrite applied via \(String(describing: route), privacy: .public)")
        } catch {
            let message = (error as? SelectionWriter.Failure)?.errorDescription
                ?? error.localizedDescription
            phase = .failed(message)
        }
    }

    /// Puts the original back on the clipboard.
    ///
    /// Offered instead of a Revert button, and deliberately so: replacing the
    /// selection generally collapses it, so a second write would *insert* the
    /// original beside the new text rather than replace it. Handing back a
    /// clipboard the user can paste is the one recovery that behaves
    /// predictably in every app.
    func copyOriginal() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(original, forType: .string)
        didCopyOriginal = true
    }

    func copyProposed() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(proposed, forType: .string)
    }

    isolated deinit {
        task?.cancel()
    }
}
