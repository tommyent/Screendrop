import CoreGraphics
import Foundation
import ImageIO
import Testing

private final class OffsetFixtureBundle: NSObject {}

/// 600x400 crops of Wikipedia's "Scroll" article (CC BY-SA 4.0), corpus page
/// fresh-wikipedia: frame 4 is frame 3 scrolled 180 px, frame 25 is 3,000 px on.
@Suite struct ScrollingOffsetTests {
    private func frame(_ index: Int) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let url = try #require(Bundle(for: OffsetFixtureBundle.self).url(forResource: "wikipedia-scroll-\(index)", withExtension: "png"))
        let image = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let pixels = try #require(ScrollingCaptureStitcher.pixels(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        return (pixels, image.width, image.height)
    }

    @Test("The verifier accepts the true offset and rejects it one or two pixels off")
    func verifierIsExact() throws {
        let last = try frame(3), new = try frame(4)
        func verified(_ candidate: Int) -> Int? {
            ScrollingCaptureOffsetVerifier.verifiedOffset(candidate: candidate, from: last.pixels, to: new.pixels,
                width: last.width, height: last.height, ignoredTrailingColumns: 0)?.offset
        }
        #expect(verified(180) == 180)
        // Each tries its candidate ±2: 181...185 and 175...179.
        #expect(verified(183) == nil)
        #expect(verified(177) == nil)
    }

    @Test("The bands of two frames with no overlap reach no consensus")
    func estimatorBandsDisagree() throws {
        let last = try frame(3), far = try frame(25)
        let shifts = ScrollingCaptureOffsetEstimator.bandShifts(from: last.pixels, to: far.pixels,
            width: last.width, height: last.height, ignoredTrailingColumns: 0)
        #expect(shifts.count == ScrollingCaptureOffsetEstimator.bands)
        #expect(ScrollingCaptureOffsetEstimator.consensus(shifts) == nil)
    }
}
