import AppKit
import ApplicationServices
import PeekCore

/// Reads the user's current selection through the Accessibility API.
///
/// Intentionally `Sendable` and free of actor isolation so it can run off the
/// main actor: every `AXUIElementCopyAttributeValue` is a synchronous IPC call
/// into the target application, and a busy or wedged app would otherwise block
/// the panel from appearing.
///
/// Not every app participates. Electron and Chromium expose nothing until
/// `AXManualAccessibility` is set, and some Java, Catalyst and custom text
/// views never expose a selection at all. That is reported as
/// ``SelectionOutcome/unsupported(appName:)`` rather than treated as an error,
/// because it is not something the user can fix.
struct AccessibilitySelectionCapture: Sendable {

    let policy: CapturePolicy

    /// Caps how long a single Accessibility round-trip may take.
    ///
    /// The system default is measured in seconds. An unresponsive app must not
    /// be able to stall context capture, and a selection that takes longer than
    /// this to read is not worth waiting for.
    private static let messagingTimeout: Float = 0.25

    init(policy: CapturePolicy = CapturePolicy()) {
        self.policy = policy
    }

    func capture(frontApp: FrontmostApp?, primaryScreenMaxY: CGFloat) -> SelectionOutcome {
        guard AXIsProcessTrusted() else { return .permissionRequired }

        guard policy.allowsCapture(fromBundleID: frontApp?.bundleID) else {
            return .withheld(appName: frontApp?.name)
        }

        if let pid = frontApp?.processID {
            activateChromiumAccessibility(pid: pid)
        }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)

        guard let focused = copyElement(systemWide, kAXFocusedUIElementAttribute) else {
            return .unsupported(appName: frontApp?.name)
        }
        AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)

        // Never read a password field, even in an app that is not deny-listed.
        // A secure field reports role AXTextField with subrole
        // AXSecureTextField, so both are checked — some views set only one.
        if isSecureField(focused) {
            return .withheld(appName: frontApp?.name)
        }

        guard let raw = copyString(focused, kAXSelectedTextAttribute) else {
            // The attribute is absent entirely: this app does not expose
            // selections. Distinct from an empty selection.
            return .unsupported(appName: frontApp?.name)
        }

        guard let sanitized = policy.sanitize(raw) else {
            return .empty(appName: frontApp?.name)
        }

        return .captured(SelectionContext(
            text: sanitized.text,
            sourceAppName: frontApp?.name,
            sourceBundleID: frontApp?.bundleID,
            selectionBounds: selectionBounds(of: focused, primaryScreenMaxY: primaryScreenMaxY),
            wasTruncated: sanitized.wasTruncated
        ))
    }

    /// Asks a Chromium-based app to switch its accessibility tree on.
    ///
    /// Chromium (and therefore every Electron app — VS Code, Slack, Discord,
    /// Claude) keeps its accessibility tree switched off until an assistive
    /// client sets `AXManualAccessibility` on the application element. Without
    /// this, those apps expose no selection at all and are indistinguishable
    /// from apps that genuinely do not support it.
    ///
    /// Best-effort and deliberately unchecked: on a non-Chromium app the
    /// attribute is simply unknown and the call fails harmlessly. Gecko-based
    /// apps such as Firefox and Zen use their own activation path and are not
    /// covered by this.
    private func activateChromiumAccessibility(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: - Selection bounds

    /// On-screen bounds of the selected range, when the app supports it.
    ///
    /// Lets the panel anchor to the text rather than the pointer. Optional by
    /// design: many apps expose `kAXSelectedText` but not the parameterized
    /// bounds attribute, and that must degrade quietly.
    private func selectionBounds(of element: AXUIElement, primaryScreenMaxY: CGFloat) -> CGRect? {
        guard let rangeValue = copyAXValue(element, kAXSelectedTextRangeAttribute) else { return nil }

        var boundsRef: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef
        )
        guard status == .success,
              let boundsRef,
              CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
        let axValue = boundsRef as! AXValue   // safe: type ID checked above

        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect), !rect.isEmpty else { return nil }

        // Accessibility reports top-left-origin coordinates; the panel works in
        // AppKit's bottom-left space.
        return ScreenGeometry.flipToAppKit(rect, primaryScreenMaxY: primaryScreenMaxY)
    }

    /// Whether the focused element is a password field.
    private func isSecureField(_ element: AXUIElement) -> Bool {
        let secure = "AXSecureTextField"
        if copyString(element, kAXRoleAttribute) == secure { return true }
        if copyString(element, kAXSubroleAttribute) == secure { return true }
        return false
    }

    // MARK: - AX plumbing

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)   // safe: type ID checked immediately above
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func copyAXValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)   // safe: type ID checked immediately above
    }
}
