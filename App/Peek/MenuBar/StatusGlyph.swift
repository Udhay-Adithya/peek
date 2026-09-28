import AppKit

/// The menu-bar glyph: the app icon's lens-tip wand and three stars, reduced
/// to a monochrome template image so the system tints it for the menu bar.
///
/// Drawn in code rather than shipped as an asset because the busy state is an
/// animation of the individual stars, which a single bitmap cannot express.
enum StatusGlyph {

    static let size = NSSize(width: 18, height: 18)

    /// Frames in one twinkle cycle. At `frameInterval` this is a 1.2 s loop:
    /// slow enough to read as twinkling rather than flicker.
    static let frameCount = 12
    static let frameInterval: TimeInterval = 0.1

    /// Stars at full brightness; also the busy image when Reduce Motion is on.
    @MainActor static let idle = image(starLevels: [1, 1, 1])

    /// Pre-rendered once: a status item redraw is cheap, but there is no reason
    /// to rebuild identical paths ten times a second for as long as a response
    /// streams.
    @MainActor static let busyFrames: [NSImage] = (0..<frameCount).map { frame in
        image(starLevels: starLevels(atPhase: Double(frame) / Double(frameCount)))
    }

    /// Brightness of each star, 0...1, at a point in the cycle (`phase` in 0..<1).
    /// Each star peaks a third of a cycle after the previous one, so the light
    /// appears to travel around the wand. Levels bottom out above zero so a
    /// star never disappears entirely and the glyph keeps its silhouette.
    static func starLevels(atPhase phase: Double) -> [Double] {
        (0..<stars.count).map { index in
            let offset = Double(index) / Double(stars.count)
            let wave = 0.5 + 0.5 * cos(2 * .pi * (phase - offset))
            return 0.2 + 0.8 * wave
        }
    }

    // MARK: - Drawing

    /// Star centres and radii in points, top-left origin, matching the app
    /// icon's layout. Ordered clockwise (top-right, right, bottom-left) so the
    /// twinkle travels around the wand instead of jumping across it.
    private static let stars: [(center: CGPoint, radius: CGFloat)] = [
        (CGPoint(x: 14.2, y: 3.8), 2.8),
        (CGPoint(x: 16.0, y: 9.6), 1.6),
        (CGPoint(x: 3.6, y: 14.4), 2.2),
    ]

    /// Deliberately nonisolated: AppKit may invoke the drawing handler off the
    /// main thread, and a closure formed in a main-actor context would trap
    /// there on Swift 6's isolation check.
    static func image(starLevels levels: [Double]) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Wand shaft, handle bottom-right, meeting the lens at top-left.
            let shaft = NSBezierPath()
            shaft.move(to: CGPoint(x: 11.0, y: 11.0))
            shaft.line(to: CGPoint(x: 14.8, y: 14.8))
            shaft.lineWidth = 2.0
            shaft.lineCapStyle = .round
            shaft.stroke()

            // The collar is what separates a wand from a plain magnifier; it
            // mirrors the gold band on the app icon.
            let collar = NSBezierPath()
            collar.move(to: CGPoint(x: 9.2, y: 9.2))
            collar.line(to: CGPoint(x: 10.6, y: 10.6))
            collar.lineWidth = 3.4
            collar.stroke()

            let lens = NSBezierPath(ovalIn: CGRect(x: 2.6, y: 2.6, width: 7.4, height: 7.4))
            lens.lineWidth = 1.6
            lens.stroke()

            for (star, level) in zip(stars, levels) {
                // Dimmer stars also shrink, which reads better than opacity
                // alone at menu-bar size.
                NSColor.black.withAlphaComponent(level).setFill()
                sparkle(at: star.center, radius: star.radius * (0.6 + 0.4 * level)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Peek"
        return image
    }

    /// Four-point sparkle with concave sides, the same shape as the app icon's.
    private static func sparkle(at c: CGPoint, radius r: CGFloat) -> NSBezierPath {
        let k = r * 0.15
        let path = NSBezierPath()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.curve(to: CGPoint(x: c.x + r, y: c.y), controlPoint: CGPoint(x: c.x + k, y: c.y - k))
        path.curve(to: CGPoint(x: c.x, y: c.y + r), controlPoint: CGPoint(x: c.x + k, y: c.y + k))
        path.curve(to: CGPoint(x: c.x - r, y: c.y), controlPoint: CGPoint(x: c.x - k, y: c.y + k))
        path.curve(to: CGPoint(x: c.x, y: c.y - r), controlPoint: CGPoint(x: c.x - k, y: c.y - k))
        path.close()
        return path
    }
}
