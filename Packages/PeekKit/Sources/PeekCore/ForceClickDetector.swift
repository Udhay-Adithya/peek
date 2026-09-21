import CoreGraphics
import Foundation

/// Decides whether a click plus a pressure curve constitutes a Force Click.
///
/// Pure logic, deliberately: the thresholds and guards here are what stop an
/// ordinary click from summoning the assistant, and that must be verifiable
/// without a trackpad. The raw pressure feed comes from the private
/// MultitouchSupport framework (see the app's `MultitouchPressureMonitor`);
/// nothing about that belongs in this decision.
///
/// Thresholds were measured, not guessed. On a 2026 Force Touch trackpad,
/// normal clicks peaked at 141–226 and Force Clicks at 522–1086, so the default
/// sits in the empty band between them.
public struct ForceClickDetector: Sendable {

    public struct Configuration: Sendable, Equatable {
        /// Peak pressure that separates a Force Click from a firm normal click.
        public var threshold: Float
        /// How long after mouse-down a Force Click may still register.
        ///
        /// The second detent follows the first closely; a longer window would
        /// let a slow press-and-hold or a drag register as a Force Click.
        public var window: TimeInterval
        /// Movement past this cancels — the gesture is a drag, not a click.
        public var movementTolerance: CGFloat
        /// Minimum gap between firings, so one press cannot invoke twice.
        public var cooldown: TimeInterval

        public init(threshold: Float = 350,
                    window: TimeInterval = 0.5,
                    movementTolerance: CGFloat = 8,
                    cooldown: TimeInterval = 0.8) {
            self.threshold = threshold
            self.window = window
            self.movementTolerance = movementTolerance
            self.cooldown = cooldown
        }
    }

    public enum Input: Sendable {
        /// A left mouse-down. `clickCount` distinguishes a double-click.
        case clickBegan(at: CGPoint, time: TimeInterval, clickCount: Int)
        case clickEnded(time: TimeInterval)
        /// A pressure sample from the trackpad, in the framework's own units.
        case pressure(Float, time: TimeInterval)
        case moved(to: CGPoint, time: TimeInterval)
    }

    public enum Output: Sendable, Equatable {
        case ignored
        case forceClick(at: CGPoint)
    }

    private struct Armed {
        let origin: CGPoint
        let startedAt: TimeInterval
    }

    public let configuration: Configuration
    private var armed: Armed?
    private var lastFiredAt: TimeInterval?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// True while a click is a live Force Click candidate.
    public var isArmed: Bool { armed != nil }

    public mutating func handle(_ input: Input) -> Output {
        switch input {
        case .clickBegan(let point, let time, let clickCount):
            // A double- or triple-click is a selection gesture, not a
            // Force Click, however hard it happens to be pressed.
            guard clickCount <= 1 else {
                armed = nil
                return .ignored
            }
            armed = Armed(origin: point, startedAt: time)
            return .ignored

        case .clickEnded:
            armed = nil
            return .ignored

        case .moved(let point, _):
            guard let armed else { return .ignored }
            if Self.distance(armed.origin, point) > configuration.movementTolerance {
                // Dragging — force-click-and-drag is a system gesture.
                self.armed = nil
            }
            return .ignored

        case .pressure(let value, let time):
            guard let armed else { return .ignored }

            // Expired: a press this slow is a hold, not a Force Click.
            guard time - armed.startedAt <= configuration.window else {
                self.armed = nil
                return .ignored
            }

            guard value >= configuration.threshold else { return .ignored }

            if let lastFiredAt, time - lastFiredAt < configuration.cooldown {
                // Still settling from the previous firing; a single physical
                // press produces many frames above the threshold.
                self.armed = nil
                return .ignored
            }

            // Disarm on firing so one press cannot invoke twice.
            self.armed = nil
            lastFiredAt = time
            return .forceClick(at: armed.origin)
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
