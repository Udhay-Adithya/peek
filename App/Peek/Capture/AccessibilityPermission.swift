import AppKit
import ApplicationServices

/// Accessibility permission, requested only at the point of use.
///
/// Peek is deliberately useful without it: the hotkey, the panel and the
/// assistant all work, and only the automatic reading of your selection is
/// unavailable. So this is never requested at launch — the user is asked the
/// first time they invoke Peek expecting context, when the reason is obvious.
enum AccessibilityPermission {

    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt. Only call in response to a user action.
    static func prompt() {
        // The `kAXTrustedCheckOptionPrompt` global is a mutable var and so is
        // not concurrency-safe to reference under Swift 6. Its value is a
        // documented, stable constant string.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Opens System Settings directly at the Accessibility pane.
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The app that was frontmost at the moment of invocation.
///
/// Read on the main actor before the panel is shown, then handed to the
/// capture code as a plain value so nothing has to touch `NSWorkspace` off the
/// main actor.
struct FrontmostApp: Sendable, Equatable {
    let name: String?
    let bundleID: String?
    let processID: pid_t

    @MainActor
    static func current() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApp(name: app.localizedName,
                            bundleID: app.bundleIdentifier,
                            processID: app.processIdentifier)
    }
}
