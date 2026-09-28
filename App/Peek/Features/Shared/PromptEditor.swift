import AppKit
import SwiftUI

/// The message composer.
///
/// An `NSTextView` rather than SwiftUI's `TextField`, because SwiftUI's
/// `onSubmit` carries no modifier information — so Return and Shift-Return are
/// indistinguishable there and both send.
///
/// Wrapping AppKit also restores standard editing behaviour for free — undo,
/// spell checking, and the system's own text navigation bindings.
struct PromptEditor: NSViewRepresentable {

    @Binding var text: String
    /// Grows with content between these bounds, then scrolls.
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let placeholder: String
    let font: NSFont
    let onSubmit: () -> Void

    /// Reported back so the enclosing layout can size to the content.
    @Binding var measuredHeight: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmittingTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.font = font
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.placeholderString = placeholder
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none

        context.coordinator.textView = textView
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            context.coordinator.recalculateHeight()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmittingTextView else { return }
        context.coordinator.parent = self
        textView.onSubmit = onSubmit
        textView.placeholderString = placeholder

        // Only write back when the model genuinely diverged, or every
        // keystroke would reset the insertion point to the end.
        if textView.string != text {
            textView.string = text
            context.coordinator.recalculateHeight()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        weak var textView: SubmittingTextView?

        init(parent: PromptEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            recalculateHeight()
        }

        func recalculateHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }

            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let inset = textView.textContainerInset.height * 2
            let height = min(max(used + inset, parent.minHeight), parent.maxHeight)

            if abs(parent.measuredHeight - height) > 0.5 {
                parent.measuredHeight = height
            }
        }
    }
}

/// `NSTextView` that sends on Return and inserts a newline on Shift-Return.
///
/// The modifier is inspected in `keyDown` rather than relying on the responder
/// action, because macOS does **not** bind Shift-Return to anything distinct:
/// `StandardKeyBinding.dict` maps `insertNewlineIgnoringFieldEditor:` to
/// Option-Return and Control-O only, and Shift is ignored for Return. Both
/// therefore arrive as plain `insertNewline:`, and a composer that wants them
/// to differ has to read the event itself.
final class SubmittingTextView: NSTextView {

    var onSubmit: (() -> Void)?

    private enum Key {
        static let `return`: UInt16 = 36
        static let keypadEnter: UInt16 = 76
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == Key.return || event.keyCode == Key.keypadEnter else {
            super.keyDown(with: event)
            return
        }

        // Shift or Option inserts a line break; plain Return sends. Option is
        // included because that is the system's own newline modifier, so users
        // who know it will reach for it.
        let wantsNewline = event.modifierFlags.contains(.shift)
            || event.modifierFlags.contains(.option)

        if wantsNewline {
            insertNewlineIgnoringFieldEditor(self)
        } else {
            onSubmit?()
        }
    }

    var placeholderString: String? {
        didSet { needsDisplay = true }
    }

    /// Backstop for any path that reaches the action without going through
    /// `keyDown`, such as a menu or scripted invocation.
    override func insertNewline(_ sender: Any?) {
        onSubmit?()
    }

    /// The actual line break. Calls `super.insertNewline` deliberately —
    /// this type's own `insertNewline` submits.
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        super.insertNewline(sender)
    }

    /// Escape must reach the panel so it can dismiss, rather than being
    /// swallowed by the text view.
    override func cancelOperation(_ sender: Any?) {
        window?.cancelOperation(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholderString, !placeholderString.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        placeholderString.draw(at: origin, withAttributes: attributes)
    }
}
