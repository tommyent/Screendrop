// Ported from scripts/check-editor-snapping.swift; production model/cache code, no UI.
import CoreGraphics
import Testing

@MainActor
@Suite
struct EditorSnappingTests {
    @Test static func snapping() {
        let point = AnnoSnapping.anchors(Vec(40, 40))
        let image = AnnoSnapping.anchors(Box(0, 0, 100, 100))
        for scale in [0.25, 1.0, 2.0] {
            let tolerance = 6 / scale
            let near = AnnoSnapping.snap(moving: point, targets: image,
                                        delta: Vec(10 - 5 / scale, 0), tolerance: tolerance)
            #expect(abs(near.delta.x - 10) < 0.0001)
            #expect(near.guides.contains { $0.start.x == 50 && $0.end.x == 50 })
            // Only test the x axis so another edge cannot take over at small zoom levels.
            let x = point.filter { $0.axis == .x }
            let centre = image.filter { $0.axis == .x && $0.position == 50 }
            let far = AnnoSnapping.snap(moving: x, targets: centre,
                                       delta: Vec(10 - 7 / scale, 3), tolerance: tolerance)
            #expect(far.delta == Vec(10 - 7 / scale, 3) && far.guides.isEmpty)
            let bypass = AnnoSnapping.snap(moving: point, targets: image,
                                          delta: Vec(10 - 5 / scale, 0), tolerance: tolerance, bypass: true)
            #expect(bypass.delta == Vec(10 - 5 / scale, 0) && bypass.guides.isEmpty)
        }

        let moving = AnnoSnapping.anchors(Box(20, 25, 10, 20))
        let target = AnnoSnapping.anchors(Box(100, 90, 40, 30))
        let twoAxes = AnnoSnapping.snap(moving: moving, targets: target,
                                       delta: Vec(65, 40), tolerance: 6)
        #expect(twoAxes.delta == Vec(70, 45))
        #expect(twoAxes.guides.contains(AnnoSnapGuide(start: Vec(100, 70), end: Vec(100, 120))))
        #expect(twoAxes.guides.contains(AnnoSnapGuide(start: Vec(90, 90), end: Vec(140, 90))))

        let tip = AnnoSnapping.anchors(Vec(150, 160))
        let arrow = AnnoSnapping.snap(moving: point, targets: tip, delta: Vec(105, 125), tolerance: 6)
        #expect(arrow.delta == Vec(110, 120) && !arrow.guides.isEmpty)
        let boundary = AnnoSnapping.snap(moving: point, targets: tip, delta: Vec(104, 114), tolerance: 6)
        #expect(boundary.delta == Vec(110, 120))

        // The closest candidate wins; exact ties keep input order for stable guides.
        let targets = [AnnoSnapAnchor(axis: .x, position: 49, lower: 0, upper: 100),
                       AnnoSnapAnchor(axis: .x, position: 51, lower: 0, upper: 100)]
        let tie = AnnoSnapping.snap(moving: point, targets: targets, delta: Vec(10, 3), tolerance: 6)
        #expect(tie.delta == Vec(9, 3))
        let closest = AnnoSnapping.snap(moving: point, targets: targets, delta: Vec(10.5, 3), tolerance: 6)
        #expect(closest.delta == Vec(11, 3))
        let empty = AnnoSnapping.snap(moving: moving, targets: [], delta: Vec(5, 7), tolerance: 6)
        #expect(empty.delta == Vec(5, 7) && empty.guides.isEmpty)
        let locked = AnnoSnapping.snap(moving: point, targets: tip, delta: Vec(105, 125),
                                       tolerance: 6, direction: Vec(1, 0))
        #expect(locked.delta == Vec(110, 125))
        #expect(locked.guides.allSatisfy { $0.start.x == $0.end.x })
        // A rotated side handle follows its own axis; a Shift corner keeps its aspect ratio.
        let diagonal = AnnoSnapping.snap(moving: point,
                                         targets: [AnnoSnapAnchor(axis: .x, position: 50, lower: 0, upper: 100)],
                                         delta: Vec(6, 6), tolerance: 6, direction: Vec(1, 1))
        #expect(Vec.dist(diagonal.delta, Vec(10, 10)) < 0.0001)
        let outsideAlongAxis = AnnoSnapping.snap(moving: point,
                                                targets: [AnnoSnapAnchor(axis: .x, position: 50, lower: 0, upper: 100)],
                                                delta: Vec(5, 5), tolerance: 6, direction: Vec(1, 1))
        #expect(outsideAlongAxis.delta == Vec(5, 5) && outsideAlongAxis.guides.isEmpty)
        print("PASS: edges, centres, tips, both axes, 5/7-screen-point tolerance at three zooms, Command bypass, guide extents and deterministic ties")
    }
}
