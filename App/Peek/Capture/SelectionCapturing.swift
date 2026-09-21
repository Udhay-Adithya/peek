import CoreGraphics
import PeekCore

/// Reads the user's selection.
///
/// A protocol so the panel's capture cascade — Accessibility first, clipboard
/// fallback only where genuinely unsupported — can be tested without a
/// trackpad, a second application, or a granted permission.
protocol SelectionCapturing: Sendable {
    func capture(frontApp: FrontmostApp?, primaryScreenMaxY: CGFloat) async -> SelectionOutcome
}

/// The fallback that synthesises a copy. Main-actor bound because it touches
/// the pasteboard.
@MainActor
protocol ClipboardCapturing {
    func capture(frontApp: FrontmostApp?) async -> SelectionOutcome
}

extension AccessibilitySelectionCapture: SelectionCapturing {}
extension ClipboardSelectionCapture: ClipboardCapturing {}
