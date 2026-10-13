import AppKit
import Testing

@MainActor
struct TaperedSliderStepsTests {
    @Test func dragSnapsAcrossUnevenGapsAndClampsAtEnds() {
        let widths = AnnotationSizeStops.lineWidths
        #expect(AnnotationSizeStops.nearest(to: 5, in: widths) == 4)
        #expect(AnnotationSizeStops.nearest(to: 5.1, in: widths) == 6)
        #expect(AnnotationSizeStops.nearest(to: -20, in: widths) == 1)
        #expect(AnnotationSizeStops.nearest(to: 100, in: widths) == 16)
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
