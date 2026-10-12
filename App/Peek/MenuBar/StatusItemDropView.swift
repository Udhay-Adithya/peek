import AppKit
import UniformTypeIdentifiers

/// Accepts drags onto the menu bar icon.
///
/// A transparent view laid over the status item's button, because
/// `NSStatusBarButton` is created by the system and cannot be subclassed to
/// override `NSDraggingDestination`. It passes mouse events through, so
/// clicking the icon still works exactly as before.
final class StatusItemDropView: NSView {

    /// Called with whatever was dropped. Files and text arrive separately
    /// because they are read quite differently.
    var onDropFiles: (([URL]) -> Void)?
    var onDropText: ((String) -> Void)?

    private var isReceiving = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks belong to the button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard isReceiving else { return }
        // A faint highlight, since the icon itself cannot change during a drag.
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        bounds.insetBy(dx: 1, dy: 3).fill()
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard canAccept(sender) else { return [] }
        isReceiving = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isReceiving = false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        isReceiving = false
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        canAccept(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isReceiving = false
        let pasteboard = sender.draggingPasteboard

        // Files first: dragging a file also puts its path on the pasteboard as
        // a string, and the path is almost never what the user meant.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onDropFiles?(urls)
            return true
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            onDropText?(text)
            return true
        }

        return false
    }

    private func canAccept(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if pasteboard.canReadObject(forClasses: [NSURL.self],
                                    options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        return pasteboard.canReadObject(forClasses: [NSString.self], options: nil)
    }
}
