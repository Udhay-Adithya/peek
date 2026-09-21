import CoreGraphics

/// Conversions between the two screen coordinate spaces macOS uses.
///
/// Accessibility and Quartz report rectangles with the origin at the top-left
/// of the primary display and +y downward. AppKit windows and `NSEvent`
/// locations use bottom-left with +y upward. Getting this backwards puts the
/// panel a screen-height away from the selection, and only on multi-display or
/// non-primary setups, so it is isolated here and tested.
public enum ScreenGeometry {

    /// Converts a top-left-origin rect into AppKit's bottom-left-origin space.
    ///
    /// - Parameter primaryScreenMaxY: `NSScreen.screens.first?.frame.maxY` —
    ///   the height of the display whose origin is (0, 0). Not the display the
    ///   rect happens to be on: the flip is always about the primary.
    public static func flipToAppKit(_ rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x,
               y: primaryScreenMaxY - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }
}
