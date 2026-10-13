import Testing

@MainActor
@Suite
struct FreehandSmoothingTests {
    @Test static func smoothsSmallWobblesWithoutMovingCompletedEndpoints() {
        let raw = (0...60).map { index in
            Vec(Double(index) * 4, index == 0 || index == 60 ? 0 : (index.isMultiple(of: 2) ? 3 : -3), 0.6)
        }
        for width in [4.0, 10.0, 16.0] {
            for isPen in [false, true] {
                for isComplete in [false, true] {
                    for forceSolid in [false, true] {
                        let options = FreehandSettings.forDrawShape(
                            isPen: isPen, isComplete: isComplete, strokeWidth: width,
                            forceComplete: false, forceSolid: forceSolid
                        )
                        let pipeline = StrokePipeline()
                        pipeline.ingest(raw, options)
                        let points = pipeline.strokePoints()
                        let middle = points.filter { $0.input.x > 60 && $0.input.x < 200 }
                        #expect(!middle.isEmpty)
                        // A 3 px alternating input wobble stays below 0.85 px after settling.
                        #expect(middle.allSatisfy { abs($0.point.y) < 0.85 })
                        #expect(points.first?.point == raw.first)
                        if isComplete { #expect(points.last?.point == raw.last) }
                        if isPen { #expect(points.allSatisfy { abs($0.pressure - 0.6) < 0.0001 }) }
                        pipeline.computeRadii(options)
                        #expect(pipeline.strokePoints().allSatisfy { $0.radius.isFinite && $0.radius > 0 })
                    }
                }
            }
        }
    }
}
