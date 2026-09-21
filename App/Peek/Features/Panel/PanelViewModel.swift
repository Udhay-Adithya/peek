import AppKit
import Observation
import PeekCore

/// State behind the floating panel.
@MainActor
@Observable
final class PanelViewModel {

    /// Result of the most recent context capture. `nil` before the first one.
    private(set) var selection: SelectionOutcome?
    private(set) var isCapturing = false

    /// Set when the user dismisses the context chip, so a re-capture does not
    /// silently bring back context they explicitly removed.
    private(set) var contextDismissed = false

    var prompt: String = ""

    let session: AssistantSession

    private let capture: AccessibilitySelectionCapture
    private let clipboardCapture: ClipboardSelectionCapture
    private let settings: AppSettings
    private let engine: AssistantEngine
    private var captureTask: Task<Void, Never>?

    /// Invoked when the user asks for settings from inside the panel.
    var onOpenSettings: (() -> Void)?

    init(settings: AppSettings,
         engine: AssistantEngine,
         capture: AccessibilitySelectionCapture = AccessibilitySelectionCapture(),
         clipboardCapture: ClipboardSelectionCapture = ClipboardSelectionCapture()) {
        self.settings = settings
        self.engine = engine
        self.capture = capture
        self.clipboardCapture = clipboardCapture
        self.session = AssistantSession(engine: engine)
    }

    var hasCredentials: Bool { engine.hasCredentials }

    /// The context actually in play, honouring an explicit dismissal.
    var activeContext: SelectionContext? {
        guard !contextDismissed, case .captured(let context) = selection else { return nil }
        return context
    }

    var canSend: Bool {
        PromptComposer.canSend(prompt: prompt, context: activeContext)
    }

    // MARK: - Context

    /// Reads the selection for `frontApp` without blocking the panel.
    ///
    /// The panel is already on screen by the time this runs. Accessibility
    /// calls are synchronous IPC into another process, so they happen off the
    /// main actor and only the resulting value comes back.
    func refreshContext(frontApp: FrontmostApp?) {
        captureTask?.cancel()
        contextDismissed = false
        isCapturing = true

        let capture = self.capture
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0

        captureTask = Task { [weak self] in
            // Task.detached, not a bare `await`: capture must not inherit the
            // main actor. Swift 6.2 is in the middle of changing whether a
            // nonisolated async function runs on the caller's actor, and an
            // Accessibility round-trip on the main actor would stall the panel.
            let outcome = await Task.detached(priority: .userInitiated) {
                await capture.capture(frontApp: frontApp, primaryScreenMaxY: primaryMaxY)
            }.value

            guard !Task.isCancelled, let self else { return }

            // Accessibility is always tried first: it is instantaneous, has no
            // side effects, and gives selection bounds. The clipboard fallback
            // only runs where the app genuinely exposes nothing.
            let final: SelectionOutcome
            if case .unsupported = outcome, self.settings.clipboardFallbackEnabled {
                final = await self.clipboardCapture.capture(frontApp: frontApp)
            } else {
                final = outcome
            }

            guard !Task.isCancelled else { return }
            self.selection = final
            self.isCapturing = false
            self.autoSendIfConfigured()
        }
    }

    /// Fires the request immediately, when the user has opted in.
    ///
    /// Gated on an explicit setting, on the conversation being fresh, and on
    /// credentials existing. Sending on every invocation would spend tokens and
    /// ship the selection to a third party on what may have been a misfire.
    private func autoSendIfConfigured() {
        guard settings.autoSendOnInvoke,
              session.isEmpty,
              engine.hasCredentials,
              activeContext != nil else { return }
        send()
    }

    func dismissContext() {
        contextDismissed = true
    }

    // MARK: - Sending

    func send() {
        guard canSend, !session.isStreaming else { return }
        let outgoing = prompt
        prompt = ""
        session.send(prompt: outgoing, context: activeContext)
    }

    func newConversation() {
        session.reset()
        prompt = ""
    }

    func openSettings() {
        onOpenSettings?()
    }

    // MARK: - Permissions

    func requestAccessibilityPermission() {
        AccessibilityPermission.prompt()
    }

    func openAccessibilitySettings() {
        AccessibilityPermission.openSettings()
    }
}
