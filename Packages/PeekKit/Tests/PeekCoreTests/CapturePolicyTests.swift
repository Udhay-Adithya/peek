import Testing
import Foundation
@testable import PeekCore

@Suite("CapturePolicy")
struct CapturePolicyTests {

    @Test("never reads from password managers")
    func deniesPasswordManagers() {
        let policy = CapturePolicy()
        #expect(policy.allowsCapture(fromBundleID: "com.1password.1password") == false)
        #expect(policy.allowsCapture(fromBundleID: "com.apple.keychainaccess") == false)
        #expect(policy.allowsCapture(fromBundleID: "com.apple.Passwords") == false)
    }

    @Test("allows ordinary apps")
    func allowsOrdinaryApps() {
        let policy = CapturePolicy()
        #expect(policy.allowsCapture(fromBundleID: "com.apple.Safari"))
        #expect(policy.allowsCapture(fromBundleID: "com.apple.Notes"))
    }

    @Test("allows capture when the source app is unknown")
    func allowsUnknownSource() {
        #expect(CapturePolicy().allowsCapture(fromBundleID: nil))
    }

    @Test("rejects whitespace-only selections")
    func rejectsWhitespace() {
        let policy = CapturePolicy()
        #expect(policy.sanitize("") == nil)
        #expect(policy.sanitize("   \n\t  ") == nil)
    }

    @Test("trims surrounding whitespace without touching the interior")
    func trimsEdgesOnly() throws {
        let result = try #require(CapturePolicy().sanitize("  force\n  touch  "))
        #expect(result.text == "force\n  touch")
        #expect(result.wasTruncated == false)
    }

    @Test("truncates oversized selections and reports it")
    func truncatesLongSelections() throws {
        let policy = CapturePolicy(maxCharacters: 10)
        let result = try #require(policy.sanitize(String(repeating: "a", count: 50)))
        #expect(result.text.count == 10)
        #expect(result.wasTruncated)
    }

    @Test("does not truncate a selection exactly at the limit")
    func boundaryIsInclusive() throws {
        let policy = CapturePolicy(maxCharacters: 10)
        let result = try #require(policy.sanitize(String(repeating: "a", count: 10)))
        #expect(result.wasTruncated == false)
    }

    @Test("counts characters, not bytes, so emoji are not split")
    func countsCharacters() throws {
        let policy = CapturePolicy(maxCharacters: 3)
        let result = try #require(policy.sanitize("👋🏽👋🏽👋🏽👋🏽👋🏽"))
        #expect(result.text.count == 3)
        #expect(result.wasTruncated)
    }
}

@Suite("ScreenGeometry")
struct ScreenGeometryTests {

    @Test("flips a top-left rect into AppKit space")
    func flipsRect() {
        // 982-tall primary display; rect 100pt down from the top, 20pt tall.
        let quartz = CGRect(x: 40, y: 100, width: 200, height: 20)
        let appKit = ScreenGeometry.flipToAppKit(quartz, primaryScreenMaxY: 982)
        #expect(appKit.origin.x == 40)
        #expect(appKit.origin.y == 862.0)   // 982 - top offset 100 - height 20
        #expect(appKit.size == quartz.size)
    }

    @Test("flipping twice returns the original rect")
    func flipIsAnInvolution() {
        let original = CGRect(x: 10, y: 250, width: 120, height: 18)
        let once = ScreenGeometry.flipToAppKit(original, primaryScreenMaxY: 982)
        let twice = ScreenGeometry.flipToAppKit(once, primaryScreenMaxY: 982)
        #expect(twice == original)
    }

    @Test("handles a rect on a display above the primary origin")
    func handlesNegativeSpace() {
        // Display stacked above the primary one reports negative Quartz y.
        let quartz = CGRect(x: 0, y: -400, width: 100, height: 20)
        let appKit = ScreenGeometry.flipToAppKit(quartz, primaryScreenMaxY: 982)
        #expect(appKit.origin.y == 1362.0)  // 982 + 400 - height 20
    }
}
