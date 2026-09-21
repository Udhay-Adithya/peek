import Testing
import CoreGraphics
import Foundation
@testable import PeekCore

@Suite("ForceClickDetector")
struct ForceClickDetectorTests {

    private let origin = CGPoint(x: 400, y: 300)

    /// Pressure values observed on real hardware.
    private enum Measured {
        /// Peaks recorded for ordinary clicks: 141…226.
        static let normalPeak: Float = 226
        /// Lowest peak recorded for a Force Click.
        static let forceFloor: Float = 522
    }

    private func detector(_ configuration: ForceClickDetector.Configuration = .init())
        -> ForceClickDetector {
        ForceClickDetector(configuration: configuration)
    }

    @Test("fires on a click whose pressure crosses the threshold")
    func firesOnForceClick() {
        var detector = self.detector()
        #expect(detector.handle(.clickBegan(at: origin, time: 0, clickCount: 1)) == .ignored)
        #expect(detector.handle(.pressure(120, time: 0.02)) == .ignored)
        #expect(detector.handle(.pressure(Measured.forceFloor, time: 0.12)) == .forceClick(at: origin))
    }

    @Test("the hardest ordinary click measured still does not fire")
    func doesNotFireOnNormalClick() {
        // 226 was the firmest normal click recorded; the threshold sits well
        // above it. Accidental invocation is the failure that would make this
        // product unusable.
        var detector = self.detector()
        _ = detector.handle(.clickBegan(at: origin, time: 0, clickCount: 1))
        for (index, value) in [108, 180, Int(Measured.normalPeak), 150].enumerated() {
            #expect(detector.handle(.pressure(Float(value), time: 0.02 * Double(index + 1))) == .ignored)
        }
    }

    @Test("ignores pressure with no click in progress")
    func ignoresRestingPressure() {
        // A palm or a heavy rest produces high pressure and no click.
        var detector = self.detector()
        #expect(detector.handle(.pressure(2000, time: 0.1)) == .ignored)
    }

    @Test("ignores pressure after the click has ended")
    func ignoresPressureAfterRelease() {
        var detector = self.detector()
        _ = detector.handle(.clickBegan(at: origin, time: 0, clickCount: 1))
        _ = detector.handle(.clickEnded(time: 0.08))
        #expect(detector.handle(.pressure(900, time: 0.1)) == .ignored)
    }

    @Test("does not fire once the window has expired")
    func respectsWindow() {
        var detector = self.detector()
        _ = detector.handle(.clickBegan(at: origin, time: 0, clickCount: 1))
        // A press-and-hold that gets heavy a second later is not a Force Click.
        #expect(detector.handle(.pressure(900, time: 0.9)) == .ignored)
    }

    @Test("cancels when the pointer moves, because that is a drag")
    func cancelsOnDrag() {
        var detector = self.detector()
        _ = detector.handle(.clickBegan(at: origin, time: 0, clickCount: 1))
        _ = detector.handle(.moved(to: CGPoint(x: 460, y: 300), time: 0.05))
        // Force-click-and-drag is a system gesture; hijacking it would break it.
        #expect(detector.handle(.pressure(900, time: 0.1)) == .ignored)
        #expect(detector.isArmed == false)
    }

    @Test("tolerates the small movement inherent in pressing hard")
    func toleratesMinorJitter() {
        var detector = self.detector()
        _ = detector.handle(.clickBegan(at: origin, time: 0, clickCount: 1))
        _ = detector.handle(.moved(to: CGPoint(x: 403, y: 302), time: 0.04))
        #expect(detector.handle(.pressure(900, time: 0.1)) == .forceClick(at: origin))
    }

    @Test("ignores a double-click however hard it is pressed")
    func ignoresDoubleClick() {
        var detector = self.detector()
        _ = detector.handle(.clickBegan(at: origin, time: 0, clickCount: 2))
        #expect(detector.handle(.pressure(900, time: 0.1)) == .ignored)
    }

    @Test("fires once per press despite many frames above the threshold")
    func firesOncePerPress() {
        // The trackpad reports ~90 frames a second; a single press produces a
        // long run of over-threshold samples. This is the bug that would
        // otherwise open a panel dozens of times per click.
        var detector = self.detector()
        _ = detector.handle(.clickBegan(at: origin, time: 0, clickCount: 1))

        var firings = 0
        for step in 0..<40 {
            let time = 0.1 + Double(step) * 0.011
            if case .forceClick = detector.handle(.pressure(900, time: time)) { firings += 1 }
        }
        #expect(firings == 1)
    }

    @Test("a second genuine press after the cooldown fires again")
    func firesAgainAfterCooldown() {
        var detector = self.detector()
        _ = detector.handle(.clickBegan(at: origin, time: 0, clickCount: 1))
        #expect(detector.handle(.pressure(900, time: 0.1)) == .forceClick(at: origin))

        let second = CGPoint(x: 100, y: 100)
        _ = detector.handle(.clickBegan(at: second, time: 2.0, clickCount: 1))
        #expect(detector.handle(.pressure(900, time: 2.1)) == .forceClick(at: second))
    }

    @Test("a rapid second press inside the cooldown does not fire")
    func suppressesWithinCooldown() {
        var detector = self.detector()
        _ = detector.handle(.clickBegan(at: origin, time: 0, clickCount: 1))
        _ = detector.handle(.pressure(900, time: 0.1))

        _ = detector.handle(.clickBegan(at: origin, time: 0.3, clickCount: 1))
        #expect(detector.handle(.pressure(900, time: 0.4)) == .ignored)
    }

    @Test("reports the click origin, not where pressure peaked")
    func reportsClickOrigin() {
        var detector = self.detector()
        let point = CGPoint(x: 1200, y: 800)
        _ = detector.handle(.clickBegan(at: point, time: 0, clickCount: 1))
        _ = detector.handle(.moved(to: CGPoint(x: 1203, y: 801), time: 0.03))
        #expect(detector.handle(.pressure(700, time: 0.1)) == .forceClick(at: point))
    }

    @Test("a raised threshold suppresses a borderline press")
    func configurableThreshold() {
        var strict = detector(.init(threshold: 800))
        _ = strict.handle(.clickBegan(at: origin, time: 0, clickCount: 1))
        #expect(strict.handle(.pressure(Measured.forceFloor, time: 0.1)) == .ignored)
        #expect(strict.handle(.pressure(1086, time: 0.15)) == .forceClick(at: origin))
    }
}
