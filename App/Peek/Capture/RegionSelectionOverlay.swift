import AppKit

/// Full-screen overlay for dragging out a capture region.
///
/// Built rather than shelling out to `screencapture -i`: spawning a process
/// from a signed app to draw a selection is both slower and gives no control
/// over cancellation, multi-display behaviour, or keeping Peek's own panel out
/// of the shot.
@MainActor
final class RegionSelectionOverlay {

    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?

    /// Presents the overlay and resolves with the chosen rect in AppKit global
    /// coordinates, or `nil` if the user cancelled.
    func presentAndWaitForSelection() async -> CGRect? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            present()
        }
    }

    private func present() {
        // One window per display, so selection works on any screen.
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame,
                                  styleMask: [.borderless],
                                  backing: .buffered,
                                  defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.setFrame(screen.frame, display: true)

            let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onComplete = { [weak self] localRect in
                guard let localRect else {
                    self?.finish(with: nil)
                    return
                }
                // Convert the view-local rect to global AppKit coordinates.
                let global = CGRect(x: screen.frame.minX + localRect.minX,
                                    y: screen.frame.minY + localRect.minY,
                                    width: localRect.width,
                                    height: localRect.height)
                self?.finish(with: global)
            }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSCursor.crosshair.push()
    }

    private func finish(with rect: CGRect?) {
        NSCursor.pop()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()

        // Guard against a second callback from another display's view.
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: rect)
    }
}

/// Draws the dimmed backdrop and the live selection rectangle.
private final class RegionSelectionView: NSView {

    var onComplete: ((CGRect?) -> Void)?

    private var origin: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        guard let selection = selectionRect else { return }

        // Punch the selection out of the dim so the content is readable.
        NSColor.clear.setFill()
        selection.fill(using: .copy)

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1.5
        border.stroke()
    }

    private var selectionRect: NSRect? {
        guard let origin, let current else { return nil }
        return NSRect(x: min(origin.x, current.x),
                      y: min(origin.y, current.y),
                      width: abs(current.x - origin.x),
                      height: abs(current.y - origin.y))
    }

    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
        current = origin
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { origin = nil; current = nil }
        guard let selection = selectionRect, selection.width >= 4, selection.height >= 4 else {
            // A click without a drag is a cancel, not a 1px capture.
            onComplete?(nil)
            return
        }
        onComplete?(selection)
    }

    /// Escape cancels, matching the system's own region capture.
    override func cancelOperation(_ sender: Any?) {
        onComplete?(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Escape
            onComplete?(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
