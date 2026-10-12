import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog
import PeekCore

/// Replaces the user's selection with new text.
///
/// The only part of Peek that *writes* anywhere. Everything else reads, so the
/// guards here are deliberately stricter than on the read paths: a mistaken
/// read shows the wrong context, a mistaken write destroys the user's work.
///
/// Two routes, in order:
///
/// 1. **Accessibility** — setting `kAXSelectedTextAttribute` on the focused
///    element. Clean, synchronous, and leaves the clipboard alone.
/// 2. **Synthetic paste** — for apps whose selection attribute is read-only.
///    Mutates the pasteboard, so it is snapshotted and restored.
///
/// Neither participates in the target app's undo stack, which is why the UI
/// previews the result first and keeps the original for reverting.
@MainActor
struct SelectionWriter {

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "write")

    enum Failure: LocalizedError, Equatable {
        case noFocusedElement
        case refused
        case secureInputActive
        case writeRejected

        var errorDescription: String? {
            switch self {
            case .noFocusedElement:  return "Could not find where to write the text back."
            case .refused:           return "Peek does not write into this app."
            case .secureInputActive: return "Another app has secure input enabled."
            case .writeRejected:     return "This app would not accept the replacement."
            }
        }
    }

    /// How the text reached the document, for the UI to report honestly.
    enum Route: Equatable {
        case accessibility
        case paste
    }

    let policy: CapturePolicy

    init(policy: CapturePolicy = CapturePolicy()) {
        self.policy = policy
    }

    /// Replaces the selection in `frontApp` with `text`.
    ///
    /// Asynchronous because the target application has to be brought forward
    /// first. Both write routes need it: a synthetic ⌘V posted to a background
    /// process is simply ignored, and several apps expose
    /// `kAXSelectedTextAttribute` as read-only while they are inactive.
    @discardableResult
    func replaceSelection(with text: String, in frontApp: FrontmostApp?) async throws -> Route {
        guard let frontApp else { throw Failure.noFocusedElement }

        // The deny-list governs writing as firmly as reading. Pasting a model's
        // output over a password field is a worse outcome than reading one.
        guard policy.allowsCapture(fromBundleID: frontApp.bundleID) else {
            Self.logger.debug("write refused: deny-listed")
            throw Failure.refused
        }

        // Bring the target forward before touching it. Peek's panel holds key
        // focus by this point, which is exactly why the first version of this
        // silently wrote nowhere.
        try await activate(frontApp)

        let appElement = AXUIElementCreateApplication(frontApp.processID)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            // No focused element at all: the paste route needs a focused text
            // view just as much, so there is nothing to fall back to.
            // Logged at error level so it survives in the unified log —
            // debug-level messages are not persisted, which is why this path
            // was invisible the first time it failed.
            Self.logger.error("write failed: no focused element in \(frontApp.bundleID ?? "unknown", privacy: .public)")
            throw Failure.noFocusedElement
        }
        let focused = focusedRef as! AXUIElement   // safe: type ID checked above

        if isSecureField(focused) {
            Self.logger.debug("write refused: secure field")
            throw Failure.refused
        }

        // Preferred route: ask the app to replace its own selection. Asking
        // first whether the attribute is writable turns a blind attempt into a
        // decision, and says so in the log either way.
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(focused,
                                       kAXSelectedTextAttribute as CFString,
                                       &settable)

        if settable.boolValue {
            let status = AXUIElementSetAttributeValue(focused,
                                                      kAXSelectedTextAttribute as CFString,
                                                      text as CFTypeRef)
            if status == .success {
                Self.logger.info("write ok via accessibility chars=\(text.count, privacy: .public)")
                return .accessibility
            }
            Self.logger.error("accessibility write rejected status=\(status.rawValue, privacy: .public) app=\(frontApp.bundleID ?? "unknown", privacy: .public)")
        } else {
            Self.logger.info("selected text not settable in \(frontApp.bundleID ?? "unknown", privacy: .public), using paste")
        }

        try pasteReplacement(text, to: frontApp.processID)
        Self.logger.info("write ok via paste chars=\(text.count, privacy: .public)")
        return .paste
    }

    // MARK: - Activation

    /// Brings `app` forward and waits for it to actually become frontmost.
    ///
    /// Polled rather than slept on: activation is asynchronous and a fixed
    /// delay is either too short on a loaded machine or latency the user feels
    /// on every rewrite.
    private func activate(_ app: FrontmostApp) async throws {
        guard let running = NSRunningApplication(processIdentifier: app.processID) else {
            throw Failure.noFocusedElement
        }
        guard !running.isActive else { return }

        running.activate(options: [])

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if running.isActive { return }
            try? await Task.sleep(for: .milliseconds(20))
        }

        // Carry on regardless: some apps report activation late, and the write
        // may still land. A failure here is reported by the write itself.
        Self.logger.error("activation timed out for \(app.bundleID ?? "unknown", privacy: .public)")
    }

    // MARK: - Paste fallback

    /// Puts `text` on the pasteboard, sends ⌘V to `pid`, then restores it.
    private func pasteReplacement(_ text: String, to pid: pid_t) throws {
        guard !IsSecureEventInputEnabled() else {
            throw Failure.secureInputActive
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(capturing: pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(to: pasteboard)
            throw Failure.writeRejected
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            snapshot.restore(to: pasteboard)
            throw Failure.writeRejected
        }
        down.flags = .maskCommand
        up.flags = .maskCommand

        // Targeted at the source process: Peek's own panel may hold key focus.
        down.postToPid(pid)
        up.postToPid(pid)

        // Restored after a delay, not immediately: the paste is asynchronous in
        // the target app, and clearing the pasteboard too early makes it paste
        // nothing. The user's clipboard is briefly ours either way.
        let restoreAfter = DispatchTime.now() + .milliseconds(400)
        DispatchQueue.main.asyncAfter(deadline: restoreAfter) {
            snapshot.restore(to: pasteboard)
        }
    }

    private func isSecureField(_ element: AXUIElement) -> Bool {
        let secure = "AXSecureTextField"
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               (value as? String) == secure {
                return true
            }
        }
        return false
    }
}
