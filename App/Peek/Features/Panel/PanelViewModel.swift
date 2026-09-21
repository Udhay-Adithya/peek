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

    private let capture: AccessibilitySelectionCapture
    private var captureTask: Task<Void, Never>?

    init(capture: AccessibilitySelectionCapture = AccessibilitySelectionCapture()) {
        self.capture = capture
    }

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

            guard !Task.isCancelled else { return }
            self?.selection = outcome
            self?.isCapturing = false
        }
    }

    /// Drops the captured context for this invocation.
    func dismissContext() {
        contextDismissed = true
    }

    func requestAccessibilityPermission() {
        AccessibilityPermission.prompt()
    }

    func openAccessibilitySettings() {
        AccessibilityPermission.openSettings()
    }

    /// The context actually in play, honouring an explicit dismissal.
    var activeContext: SelectionContext? {
        guard !contextDismissed, case .captured(let context) = selection else { return nil }
        return context
    }
}
