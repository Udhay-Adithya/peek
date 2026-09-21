import AppKit
import Carbon.HIToolbox
import OSLog
import PeekCore

/// Last-resort selection capture: ask the source app to copy, then read the
/// pasteboard and put it back as it was.
///
/// Used only where Accessibility genuinely reports no support — Electron apps
/// that ignore `AXManualAccessibility`, Gecko browsers, and custom text views.
/// This is the same technique PopClip and Raycast rely on, and it is the only
/// thing that works in those apps.
///
/// Three things make it delicate, all handled here:
///
/// * **It targets a specific process.** Peek's panel is the key window by the
///   time this runs, so a session-level ⌘C would be delivered to Peek itself.
///   `CGEvent.postToPid` sends it to the app the user was actually in.
/// * **It mutates the pasteboard.** Contents are snapshotted and restored,
///   including every representation of every item, not just plain text.
/// * **It is blocked under Secure Input.** When a password field anywhere has
///   secure input enabled, synthetic keystrokes must not be attempted at all.
@MainActor
struct ClipboardSelectionCapture {

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "capture")

    /// How long to wait for the target app to service the copy.
    private static let pollTimeout = Duration.milliseconds(320)
    private static let pollInterval = Duration.milliseconds(16)

    let policy: CapturePolicy

    init(policy: CapturePolicy = CapturePolicy()) {
        self.policy = policy
    }

    func capture(frontApp: FrontmostApp?) async -> SelectionOutcome {
        guard let frontApp, let pid = Optional(frontApp.processID) else {
            return .unsupported(appName: nil)
        }

        // Belt and braces: the Accessibility path already refuses deny-listed
        // apps, but this path synthesises keystrokes and must never be the way
        // a credential gets read.
        guard policy.allowsCapture(fromBundleID: frontApp.bundleID) else {
            Self.logger.debug("clipboard fallback refused: deny-listed")
            return .withheld(appName: frontApp.name)
        }

        guard !IsSecureEventInputEnabled() else {
            // A password field somewhere owns the input stream.
            Self.logger.debug("clipboard fallback skipped: secure input active")
            return .unsupported(appName: frontApp.name)
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(capturing: pasteboard)
        let changeCountBefore = pasteboard.changeCount

        guard postCopy(to: pid) else {
            Self.logger.debug("clipboard fallback failed: could not synthesise event")
            return .unsupported(appName: frontApp.name)
        }

        let copied = await waitForCopy(pasteboard, changingFrom: changeCountBefore)

        // Restore before interpreting, so an early return cannot leave the
        // user's clipboard clobbered.
        snapshot.restore(to: pasteboard)

        guard let copied, let sanitized = policy.sanitize(copied) else {
            Self.logger.debug("clipboard fallback produced nothing")
            return .empty(appName: frontApp.name)
        }

        Self.logger.debug("clipboard fallback captured chars=\(sanitized.text.count, privacy: .public)")
        return .captured(SelectionContext(
            text: sanitized.text,
            sourceAppName: frontApp.name,
            sourceBundleID: frontApp.bundleID,
            selectionBounds: nil,
            wasTruncated: sanitized.wasTruncated
        ))
    }

    // MARK: - Synthetic copy

    /// Posts ⌘C directly to `pid`.
    private func postCopy(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source,
                                    virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }

    /// Polls `changeCount` until the target app writes to the pasteboard.
    ///
    /// Polled rather than slept-on: a fixed delay would either be too short for
    /// a busy app or add latency the user feels on every capture.
    private func waitForCopy(_ pasteboard: NSPasteboard, changingFrom before: Int) async -> String? {
        var waited = Duration.zero
        while waited < Self.pollTimeout {
            if pasteboard.changeCount != before {
                return pasteboard.string(forType: .string)
            }
            try? await Task.sleep(for: Self.pollInterval)
            waited += Self.pollInterval
        }
        return nil
    }
}

/// A restorable copy of the pasteboard's contents.
///
/// Every representation of every item is preserved, not just plain text: the
/// user may have had rich text, an image or a file promise on the clipboard,
/// and handing them back a plain-text approximation is data loss.
struct PasteboardSnapshot {

    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(capturing pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations[type] = data
                }
            }
            return representations
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restored = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
