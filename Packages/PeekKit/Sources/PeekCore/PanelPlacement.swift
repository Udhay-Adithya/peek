import CoreGraphics

/// Where the floating panel should be placed, as pure geometry.
///
/// Deliberately free of AppKit: the caller converts `NSScreen` into
/// ``PanelPlacement/Screen`` values. Edge clamping and display selection are
/// the parts that fail silently and are near-impossible to verify by hand on a
/// single-monitor development machine, so they live here where they can be
/// tested against arbitrary display arrangements.
///
/// All coordinates are AppKit screen coordinates: origin bottom-left, +y up.
public enum PanelPlacement {

    public struct Screen: Sendable, Equatable {
        /// Full display bounds.
        public let frame: CGRect
        /// Bounds excluding the menu bar and Dock.
        public let visibleFrame: CGRect

        public init(frame: CGRect, visibleFrame: CGRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }
    }

    /// Vertical side of the anchor the panel ended up on.
    public enum Side: Sendable, Equatable {
        case below
        case above
    }

    public struct Result: Sendable, Equatable {
        public let origin: CGPoint
        public let side: Side
        /// The display the panel was placed on.
        public let screen: Screen
    }

    /// Computes the panel origin for an anchor rectangle.
    ///
    /// The anchor is the thing the panel is about — the on-screen bounds of the
    /// user's text selection where Accessibility can supply them, otherwise a
    /// zero-size rect at the mouse location.
    ///
    /// Preference order: directly below the anchor, flipping above when there
    /// is not enough room below. The result is always fully inside the chosen
    /// display's `visibleFrame` when the panel fits at all.
    public static func place(panelSize: CGSize,
                             anchor: CGRect,
                             screens: [Screen],
                             gap: CGFloat = 12) -> Result? {
        guard let screen = screen(containing: anchor, in: screens) else { return nil }
        let visible = screen.visibleFrame

        // Horizontal: left-align to the anchor, then clamp so the whole panel
        // stays on-screen. max() guards the case where the panel is wider than
        // the display, which would otherwise invert the clamp range.
        let maxX = max(visible.minX, visible.maxX - panelSize.width)
        let x = min(max(anchor.minX, visible.minX), maxX)

        // Vertical: below the anchor if it fits, otherwise above.
        let belowY = anchor.minY - gap - panelSize.height
        let aboveY = anchor.maxY + gap

        let side: Side
        let rawY: CGFloat
        if belowY >= visible.minY {
            side = .below
            rawY = belowY
        } else if aboveY + panelSize.height <= visible.maxY {
            side = .above
            rawY = aboveY
        } else {
            // Fits neither way — prefer below and let the clamp below pin it.
            side = .below
            rawY = belowY
        }

        let maxY = max(visible.minY, visible.maxY - panelSize.height)
        let y = min(max(rawY, visible.minY), maxY)

        return Result(origin: CGPoint(x: x, y: y), side: side, screen: screen)
    }

    /// The display an anchor belongs to.
    ///
    /// Uses the anchor's centre, so a selection straddling two displays lands on
    /// the one showing most of it. Falls back to the display whose frame is
    /// nearest, which matters because the mouse can sit in a dead zone between
    /// mismatched displays.
    static func screen(containing anchor: CGRect, in screens: [Screen]) -> Screen? {
        guard !screens.isEmpty else { return nil }
        let centre = CGPoint(x: anchor.midX, y: anchor.midY)

        if let hit = screens.first(where: { $0.frame.contains(centre) }) {
            return hit
        }
        return screens.min { a, b in
            squaredDistance(from: centre, to: a.frame) < squaredDistance(from: centre, to: b.frame)
        }
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
