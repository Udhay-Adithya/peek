import Testing
import CoreGraphics
@testable import PeekCore

@Suite("PanelPlacement")
struct PanelPlacementTests {

    // Built-in display: 1512x982, menu bar at top, Dock at bottom.
    static let builtIn = PanelPlacement.Screen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 864)
    )

    // External display sitting to the right of the built-in one.
    static let external = PanelPlacement.Screen(
        frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    )

    let panel = CGSize(width: 420, height: 260)

    @Test("sits below the anchor and left-aligns to it when there is room")
    func placesBelowByDefault() throws {
        let anchor = CGRect(x: 400, y: 600, width: 120, height: 18)
        let r = try #require(PanelPlacement.place(panelSize: panel, anchor: anchor,
                                                  screens: [Self.builtIn]))
        #expect(r.side == .below)
        #expect(r.origin.x == 400)
        #expect(r.origin.y == 328.0)   // 600 - gap 12 - height 260
    }

    @Test("flips above the anchor when the selection is near the Dock")
    func flipsAboveNearBottom() throws {
        // Anchor low enough that a panel below would run under the Dock.
        let anchor = CGRect(x: 300, y: 140, width: 120, height: 18)
        let r = try #require(PanelPlacement.place(panelSize: panel, anchor: anchor,
                                                  screens: [Self.builtIn]))
        #expect(r.side == .above)
        #expect(r.origin.y == anchor.maxY + 12)
    }

    @Test("never overhangs the right edge")
    func clampsToRightEdge() throws {
        let anchor = CGRect(x: 1480, y: 600, width: 10, height: 18)
        let r = try #require(PanelPlacement.place(panelSize: panel, anchor: anchor,
                                                  screens: [Self.builtIn]))
        #expect(r.origin.x + panel.width <= Self.builtIn.visibleFrame.maxX)
        #expect(r.origin.x == 1092.0)  // visible maxX 1512 - width 420
    }

    @Test("never overhangs the left edge")
    func clampsToLeftEdge() throws {
        let anchor = CGRect(x: -40, y: 600, width: 10, height: 18)
        let r = try #require(PanelPlacement.place(panelSize: panel, anchor: anchor,
                                                  screens: [Self.builtIn]))
        #expect(r.origin.x == Self.builtIn.visibleFrame.minX)
    }

    @Test("stays clear of the menu bar when flipped above near the top")
    func respectsMenuBar() throws {
        let anchor = CGRect(x: 300, y: 930, width: 120, height: 18)
        let r = try #require(PanelPlacement.place(panelSize: panel, anchor: anchor,
                                                  screens: [Self.builtIn]))
        #expect(r.origin.y + panel.height <= Self.builtIn.visibleFrame.maxY)
    }

    @Test("places on the display holding the selection, not the primary one")
    func choosesCorrectDisplay() throws {
        let anchor = CGRect(x: 2400, y: 700, width: 120, height: 18)
        let r = try #require(PanelPlacement.place(panelSize: panel, anchor: anchor,
                                                  screens: [Self.builtIn, Self.external]))
        #expect(r.screen == Self.external)
        #expect(r.origin.x == 2400)
    }

    @Test("falls back to the nearest display for an anchor in a dead zone")
    func fallsBackToNearestDisplay() throws {
        // Displays of different heights leave gaps no display contains.
        let anchor = CGRect(x: 1600, y: 1050, width: 10, height: 10)
        let r = try #require(PanelPlacement.place(panelSize: panel, anchor: anchor,
                                                  screens: [Self.builtIn, Self.external]))
        #expect(r.screen == Self.external)
    }

    @Test("keeps the origin on-screen when the panel is wider than the display")
    func handlesOversizedPanel() throws {
        let oversized = CGSize(width: 2000, height: 260)
        let anchor = CGRect(x: 700, y: 600, width: 10, height: 18)
        let r = try #require(PanelPlacement.place(panelSize: oversized, anchor: anchor,
                                                  screens: [Self.builtIn]))
        #expect(r.origin.x == Self.builtIn.visibleFrame.minX)
    }

    @Test("returns nil when there are no displays")
    func noScreens() {
        #expect(PanelPlacement.place(panelSize: panel,
                                     anchor: .zero,
                                     screens: []) == nil)
    }

    @Test("result is always inside the visible frame for anchors across the display")
    func alwaysOnScreen() throws {
        for x in stride(from: -200.0, through: 1700.0, by: 100) {
            for y in stride(from: -100.0, through: 1100.0, by: 100) {
                let anchor = CGRect(x: x, y: y, width: 80, height: 18)
                let r = try #require(PanelPlacement.place(panelSize: panel, anchor: anchor,
                                                          screens: [Self.builtIn]))
                let v = r.screen.visibleFrame
                #expect(r.origin.x >= v.minX)
                #expect(r.origin.x + panel.width <= v.maxX)
                #expect(r.origin.y >= v.minY)
                #expect(r.origin.y + panel.height <= v.maxY)
            }
        }
    }
}
