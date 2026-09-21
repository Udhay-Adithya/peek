import Carbon.HIToolbox

/// A system-wide keyboard shortcut.
///
/// Carbon's `RegisterEventHotKey` is used deliberately. It remains the only
/// public API for a global shortcut that needs **no permission grant at all** —
/// an `NSEvent` global monitor for `.keyDown` requires Accessibility, and a
/// `CGEventTap` requires Input Monitoring. For a utility whose entire value is
/// being instantly available, a trigger that works before the user has granted
/// anything is worth the dated API surface.
struct HotKey: Equatable, Sendable {

    /// Virtual key code, e.g. `kVK_Space`.
    let keyCode: UInt32
    /// Carbon modifier mask, e.g. `controlKey | optionKey`.
    let modifiers: UInt32

    /// Default invocation shortcut: ⌃⌥Space.
    ///
    /// Chosen against the macOS defaults rather than for convenience:
    /// `⌘Space` is Spotlight, `⌥⌘Space` opens a Finder search window,
    /// `⌃⌘Space` opens the Character Viewer, `⌃Space` switches input source,
    /// and plain `⌥Space` types a non-breaking space in most text views.
    /// `⌃⌥Space` is unassigned by default.
    static let defaultInvoke = HotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey)
    )

    /// Human-readable form for display in settings and menus.
    var displayString: String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        parts += Self.keyName(for: keyCode)
        return parts
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Escape: return "Escape"
        case kVK_ANSI_P: return "P"
        default: return "Key \(keyCode)"
        }
    }
}
