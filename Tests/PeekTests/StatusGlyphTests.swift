import Testing
import AppKit
@testable import Peek

@Suite("StatusGlyph")
struct StatusGlyphTests {

    @Test("each star peaks a third of a cycle after the previous one")
    func starsPeakInTurn() {
        for (index, phase) in [0.0, 1.0 / 3.0, 2.0 / 3.0].enumerated() {
            let levels = StatusGlyph.starLevels(atPhase: phase)
            #expect(levels.firstIndex(of: levels.max()!) == index)
            #expect(abs(levels[index] - 1) < 1e-9)
        }
    }

    @Test("stars dim but never vanish, so the glyph keeps its silhouette")
    func levelsStayVisible() {
        for frame in 0..<StatusGlyph.frameCount {
            let phase = Double(frame) / Double(StatusGlyph.frameCount)
            for level in StatusGlyph.starLevels(atPhase: phase) {
                #expect(level >= 0.2 && level <= 1)
            }
        }
    }

    @Test("every frame is a menu-bar-sized template image")
    @MainActor
    func framesAreTemplates() {
        let images = [StatusGlyph.idle] + StatusGlyph.busyFrames
        #expect(StatusGlyph.busyFrames.count == StatusGlyph.frameCount)
        for image in images {
            #expect(image.isTemplate)
            #expect(image.size == StatusGlyph.size)
        }
    }
}
