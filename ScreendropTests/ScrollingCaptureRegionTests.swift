import CoreGraphics
import Testing

/// Snap-ahead around windows in front of the scrolled one: they cut the
/// frames' height short instead of turning snap-ahead off. Display-local
/// top-left points, a 1710x1112 display, the selection in the middle of a
/// browser window that runs to the bottom of the display.
@Suite struct ScrollingCaptureRegionTests {
    private let display = CGRect(x: 0, y: 0, width: 1710, height: 1112)
    private let selection = CGRect(x: 600, y: 400, width: 500, height: 300)
    private let target = (frame: CGRect(x: 300, y: 38, width: 1100, height: 1074), isTarget: true)

    private func matching(inFront: [CGRect]) -> ScrollingCaptureRegion.Matching {
        ScrollingCaptureRegion.matching(selection: selection, display: display,
            frontToBackWindows: inFront.map { (frame: $0, isTarget: false) } + [target])
    }

    @Test("A floating window above the selection's columns stops the frames just under it, on a whole point")
    func obstacleAbove() {
        // A dictation panel at the top centre, as on the user's Mac.
        #expect(matching(inFront: [CGRect(x: 735, y: 34, width: 240, height: 160)])
            == .init(rect: CGRect(x: 600, y: 194, width: 500, height: 918), reason: .clipped, obstacles: [0]))
        // A fractional edge rounds inward, so none of it is captured.
        #expect(matching(inFront: [CGRect(x: 735, y: 34, width: 240, height: 160.4)]).rect
            == CGRect(x: 600, y: 195, width: 500, height: 917))
    }

    @Test("A floating window below the selection's columns stops the frames just above it")
    func obstacleBelow() {
        #expect(matching(inFront: [CGRect(x: 700, y: 900, width: 200, height: 100)])
            == .init(rect: CGRect(x: 600, y: 38, width: 500, height: 862), reason: .clipped, obstacles: [0]))
    }

    @Test("A window beside the selection's columns doesn't count")
    func obstacleBeside() {
        // A utility panel at the right edge of the display.
        #expect(matching(inFront: [CGRect(x: 1638, y: 572, width: 72, height: 100)])
            == .init(rect: CGRect(x: 600, y: 38, width: 500, height: 1074), reason: .expanded, obstacles: []))
    }

    @Test("A window over the selection itself keeps frames to the selection")
    func obstacleOverSelection() {
        #expect(matching(inFront: [CGRect(x: 650, y: 450, width: 100, height: 100)])
            == .init(rect: selection, reason: .frontNotTarget, obstacles: [0]))
    }

    @Test("The Dock in front of a window that runs behind it stops the frames at its top; the nearest windows win")
    func dockAndNearest() {
        let dock = CGRect(x: 300, y: 1040, width: 1100, height: 72)
        #expect(matching(inFront: [dock])
            == .init(rect: CGRect(x: 600, y: 38, width: 500, height: 1002), reason: .clipped, obstacles: [0]))
        let near = matching(inFront: [CGRect(x: 735, y: 34, width: 240, height: 160), dock,
                                      CGRect(x: 900, y: 100, width: 300, height: 150), CGRect(x: 600, y: 800, width: 50, height: 50)])
        #expect(near.rect == CGRect(x: 600, y: 250, width: 500, height: 550))
        #expect(near.reason == .clipped && near.obstacles == [0, 1, 2, 3])
    }
}
