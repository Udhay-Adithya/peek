import AppKit

/// The floating assistant surface.
///
/// `NSPanel`, not `NSWindow`, for two behaviours a plain window cannot provide:
///
/// * `.nonactivatingPanel` lets the panel take keyboard focus without
///   activating Peek, so the app the user was working in keeps its active
///   state and its windows keep their focused chrome.
/// * Panels never become main, which is what stops the front app's title bar
///   from dimming the moment the panel appears.
///
/// `canBecomeKey` is overridden because a borderless-style panel refuses key
/// status by default, and the input field would silently never receive text.
final class PeekPanel: NSPanel {

    /// Invoked for Escape and ⌘W. The controller hides rather than closes,
    /// because the panel is pre-warmed and must survive dismissal.
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape, via the standard responder-chain cancel action.
    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    /// ⌘W hides instead of closing, so the pre-warmed panel is not destroyed.
    override func performClose(_ sender: Any?) {
        onDismiss?()
    }
}
