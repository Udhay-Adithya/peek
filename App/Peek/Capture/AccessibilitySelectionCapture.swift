import AppKit
import ApplicationServices
import OSLog
import PeekCore

/// Reads the user's current selection through the Accessibility API.
///
/// Intentionally `Sendable` and free of actor isolation so it can run off the
/// main actor: every `AXUIElementCopyAttributeValue` is a synchronous IPC call
/// into the target application, and a busy or wedged app would otherwise block
/// the panel from appearing.
///
/// Coverage is genuinely uneven across the Mac app ecosystem, and the three
/// families behave differently enough to be worth naming:
///
/// * **Native AppKit** (Notes, Safari, TextEdit, Ghostty) — works directly.
/// * **Chromium/Electron** (Claude, Obsidian, VS Code, Slack) — exposes nothing
///   until `AXManualAccessibility` is set, and then builds its tree
///   *asynchronously*, so the first read after priming still fails. Handled by
///   priming and retrying once.
/// * **Gecko** (Firefox, Zen) — ignores `AXManualAccessibility`; reports the
///   window as the focused element rather than the text view. Handled on the
///   retry path via `AXEnhancedUserInterface`.
struct AccessibilitySelectionCapture: Sendable {

    let policy: CapturePolicy

    /// Caps how long a single Accessibility round-trip may take.
    ///
    /// The system default is measured in seconds. An unresponsive app must not
    /// be able to stall context capture.
    private static let messagingTimeout: Float = 0.25

    /// How long to let a Chromium app build its accessibility tree after the
    /// tree is first requested. The panel is already on screen and showing a
    /// pending state, so this is latency the user does not sit blocked on.
    private static let treeBuildDelay = Duration.milliseconds(250)

    /// Roles that represent editable or selectable text.
    ///
    /// Used to tell "this app does not support selections" from "this app
    /// supports them and nothing is selected". Several apps — Ghostty among
    /// them — drop `AXSelectedText` entirely rather than returning an empty
    /// string when there is no selection.
    private static let textRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXStaticText",
        "AXComboBox", "AXSearchField", "AXWebArea",
    ]

    init(policy: CapturePolicy = CapturePolicy()) {
        self.policy = policy
    }

    // MARK: - Entry point

    func capture(frontApp: FrontmostApp?, primaryScreenMaxY: CGFloat) async -> SelectionOutcome {
        guard AXIsProcessTrusted() else { return .permissionRequired }

        guard policy.allowsCapture(fromBundleID: frontApp?.bundleID) else {
            Self.log(outcome: "withheld-denylist", app: frontApp)
            return .withheld(appName: frontApp?.name)
        }

        if let pid = frontApp?.processID {
            prime(pid: pid, aggressive: false)
        }

        let first = attempt(frontApp: frontApp, primaryScreenMaxY: primaryScreenMaxY)

        // Only an outright lack of support is worth retrying. An empty
        // selection or a withheld one is a final answer.
        guard case .unsupported = first, let pid = frontApp?.processID else {
            return first
        }

        prime(pid: pid, aggressive: true)
        try? await Task.sleep(for: Self.treeBuildDelay)

        let second = attempt(frontApp: frontApp, primaryScreenMaxY: primaryScreenMaxY, isRetry: true)
        return second
    }

    // MARK: - Single attempt

    private func attempt(frontApp: FrontmostApp?,
                         primaryScreenMaxY: CGFloat,
                         isRetry: Bool = false) -> SelectionOutcome {
        let stage = isRetry ? "retry" : "first"

        // Scope the query to the invoking application, NOT the system-wide
        // element. The panel is already key by the time this runs, so the
        // system-wide focused element is Peek's own input field, which has no
        // selection and makes every capture look empty.
        let root: AXUIElement
        if let pid = frontApp?.processID {
            root = AXUIElementCreateApplication(pid)
        } else {
            root = AXUIElementCreateSystemWide()
        }
        AXUIElementSetMessagingTimeout(root, Self.messagingTimeout)

        guard let focused = copyElement(root, kAXFocusedUIElementAttribute) else {
            Self.log(outcome: "unsupported-no-focused-element-\(stage)", app: frontApp)
            return .unsupported(appName: frontApp?.name)
        }
        AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)

        let role = copyString(focused, kAXRoleAttribute)

        // Never read a password field, even in an app that is not deny-listed.
        // A secure field reports role AXTextField with subrole
        // AXSecureTextField, so both are checked — some views set only one.
        if isSecureField(focused) {
            Self.log(outcome: "withheld-secure-field", app: frontApp, role: role)
            return .withheld(appName: frontApp?.name)
        }

        guard let raw = copyString(focused, kAXSelectedTextAttribute) else {
            // The attribute is absent. If the focused element is nonetheless a
            // text role, the app does support selections and simply has none —
            // reporting that as "unsupported" misleads the user.
            if let role, Self.textRoles.contains(role) {
                Self.log(outcome: "empty-no-attribute-\(stage)", app: frontApp, role: role)
                return .empty(appName: frontApp?.name)
            }
            Self.log(outcome: "unsupported-no-attribute-\(stage)", app: frontApp, role: role)
            Self.logAttributeNames(of: focused, app: frontApp)
            return .unsupported(appName: frontApp?.name)
        }

        guard let sanitized = policy.sanitize(raw) else {
            Self.log(outcome: "empty-selection-\(stage)", app: frontApp, role: role)
            return .empty(appName: frontApp?.name)
        }

        Self.log(outcome: "captured-\(stage)", app: frontApp, role: role,
                 characters: sanitized.text.count)

        return .captured(SelectionContext(
            text: sanitized.text,
            sourceAppName: frontApp?.name,
            sourceBundleID: frontApp?.bundleID,
            selectionBounds: selectionBounds(of: focused, primaryScreenMaxY: primaryScreenMaxY),
            wasTruncated: sanitized.wasTruncated
        ))
    }

    // MARK: - Priming non-native toolkits

    /// Asks a non-native app to switch its accessibility tree on.
    ///
    /// `AXManualAccessibility` is Chromium's opt-in and is set on every
    /// attempt: it is specific, cheap, and harmlessly unknown elsewhere.
    ///
    /// `AXEnhancedUserInterface` is only set on the retry, deliberately. It is
    /// the flag VoiceOver sets, Gecko keys off it, and some apps change layout
    /// behaviour when they believe a screen reader is attached. Limiting it to
    /// apps that have already failed keeps that blast radius small.
    private func prime(pid: pid_t, aggressive: Bool) {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if aggressive {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
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

    // MARK: - Diagnostics

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "capture")

    /// Redacted capture diagnostics.
    ///
    /// Records what happened and how much text was involved, never the text
    /// itself. Selected text is exactly the sensitive payload this app exists
    /// to handle and must not reach the unified log.
    private static func log(outcome: String,
                            app: FrontmostApp?,
                            role: String? = nil,
                            characters: Int? = nil) {
        let bundle = app?.bundleID ?? "unknown"
        let roleName = role ?? "n/a"
        let count = characters ?? 0
        logger.debug("capture outcome=\(outcome, privacy: .public) bundle=\(bundle, privacy: .public) role=\(roleName, privacy: .public) chars=\(count, privacy: .public)")
    }

    /// Logs which attributes an element actually exposes.
    ///
    /// Only reached when capture has already failed. Attribute *names* are
    /// structural metadata, not user content, so they are safe to record; no
    /// attribute value is ever read here.
    private static func logAttributeNames(of element: AXUIElement,
                                          app: FrontmostApp?,
                                          label: String = "focused") {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let list = names as? [String] else { return }
        let joined = list.joined(separator: ",")
        logger.debug("attrs \(label, privacy: .public) bundle=\(app?.bundleID ?? "unknown", privacy: .public) \(joined, privacy: .public)")
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
