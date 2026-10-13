import AppKit
import Testing

@MainActor
struct TaperedSliderStepsTests {
    @Test func dragStopsHaveEqualSpaceAndClampAtEnds() {
        let widths = AnnotationSizeStops.lineWidths
        #expect(AnnotationSizeStops.value(at: 0.5, in: widths) == 6)
        #expect(AnnotationSizeStops.value(at: -1, in: widths) == 1)
        #expect(AnnotationSizeStops.value(at: 2, in: widths) == 16)
        for stops in [widths, AnnotationSizeStops.textSizes] {
            for (index, stop) in stops.enumerated() {
                let fraction = CGFloat(index) / CGFloat(stops.count - 1)
                #expect(AnnotationSizeStops.value(at: fraction, in: stops) == stop)
                #expect(abs(AnnotationSizeStops.fraction(for: stop, in: stops) - fraction) < 0.0001)
            }
        }
    }

    @Test func offStopThumbPositionInterpolatesBetweenNeighbours() {
        #expect(AnnotationSizeStops.fraction(for: 5, in: AnnotationSizeStops.lineWidths) == 0.5)
        let textFraction = AnnotationSizeStops.fraction(for: 84, in: AnnotationSizeStops.textSizes)
        #expect(abs(textFraction - 12.5 / 13) < 0.0001)
    }

    @Test func keysMoveToAnAdjacentStopFromAnExistingOffStopValue() {
        let widths = AnnotationSizeStops.lineWidths
        #expect(AnnotationSizeStops.step(from: 5, by: -1, in: widths) == 4)
        #expect(AnnotationSizeStops.step(from: 5, by: 1, in: widths) == 6)
        let text = AnnotationSizeStops.textSizes
        #expect(AnnotationSizeStops.step(from: 74, by: -1, in: text) == 72)
        #expect(AnnotationSizeStops.step(from: 74, by: 1, in: text) == 96)
    }

    @Test func includesTheRealTextMinimumAndStopsAtBoundaries() {
        let sizes = AnnotationSizeStops.textSizes
        #expect(sizes.first == AnnotationTextMetrics.minimumFontSize)
        #expect(AnnotationSizeStops.step(from: AnnotationTextMetrics.minimumFontSize, by: -1, in: sizes)
                == AnnotationTextMetrics.minimumFontSize)
        #expect(AnnotationSizeStops.step(from: 96, by: 1, in: sizes) == 96)
        // A saved size beyond the pill's range isn't rewritten without a valid step.
        #expect(AnnotationSizeStops.step(from: 120, by: 1, in: sizes) == 120)
    }
}
