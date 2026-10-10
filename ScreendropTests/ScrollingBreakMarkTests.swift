import CoreGraphics
import Testing

@Suite struct ScrollingBreakMarkTests {
    private typealias F = ScrollingReworkFixture
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private func page(_ rows: Range<Int>) -> [UInt32] {
        rows.flatMap { y in (0..<F.width).map { F.pixel(x: $0, pageY: y) } }
    }

    @Test("A part the pixels prove continues the one above joins with no band")
    func seamless() throws {
        let joined = try #require(ScrollingCaptureBreakMark.join([F.frame(0), F.frame(150)], scale: 2,
            colorSpace: space, maximumHeight: 16_384))
        #expect(joined.bands.isEmpty)
        #expect(joined.raster.pixels == page(0..<350))
        // Wholly inside the part above: nothing to add, and the next part
        // still joins against the longer one.
        let inside = try #require(ScrollingCaptureRaster(width: F.width, height: 50, pixels: page(100..<150)))
        let nested = try #require(ScrollingCaptureBreakMark.join([F.frame(0), inside, F.frame(180)],
            scale: 2, colorSpace: space, maximumHeight: 16_384))
        #expect(nested.bands.isEmpty && nested.raster.pixels == page(0..<380))
    }

    @Test("No proof of continuation leaves a band and every captured pixel", arguments: [
        ("no overlap", 1000, nil), ("a row changed in the overlap", 150, 160..<170)] as [(String, Int, Range<Int>?)])
    func band(_ name: String, offset: Int, video: Range<Int>?) throws {
        let above = F.frame(0, phase: 0, video: video), below = F.frame(offset, phase: 1, video: video)
        let joined = try #require(ScrollingCaptureBreakMark.join([above, below], scale: 2, colorSpace: space,
            maximumHeight: 16_384))
        #expect(joined.bands == [200..<240], "\(name)")
        #expect(Array(joined.raster.pixels.prefix(200 * F.width)) == above.pixels)
        #expect(Array(joined.raster.pixels.suffix(200 * F.width)) == below.pixels)
    }

    @Test("A later part already inside the capture, as after a scroll-back, is dropped")
    func repeatDropped() throws {
        let inside = try #require(ScrollingCaptureRaster(width: F.width, height: 50, pixels: page(100..<150)))
        let joined = try #require(ScrollingCaptureBreakMark.join([F.frame(0), F.frame(1000), inside], scale: 2,
            colorSpace: space, maximumHeight: 16_384))
        #expect(joined.bands == [200..<240] && joined.raster.height == 440)
        #expect(Array(joined.raster.pixels.suffix(200 * F.width)) == F.frame(1000).pixels)
    }

    @Test("Repeats that fit two places, or too few distinct rows, prove nothing")
    func ambiguous() throws {
        let rows = page(0..<20)
        let twice = try #require(ScrollingCaptureRaster(width: F.width, height: 40, pixels: rows + rows))
        let once = try #require(ScrollingCaptureRaster(width: F.width, height: 20, pixels: rows))
        #expect(ScrollingCaptureBreakMark.continuation(of: twice, by: once) == nil)
        // Only five shared rows.
        #expect(ScrollingCaptureBreakMark.continuation(of: F.frame(0), by: F.frame(195)) == nil)
        #expect(ScrollingCaptureBreakMark.continuation(of: F.frame(0), by: F.frame(180)) == 180)
    }

    @Test("The band takes the page's margin colour, not media beside the join", arguments: [
        (UInt32(0xffffffff), UInt32(0xffefefef)), (UInt32(0xff000000), UInt32(0xff101010))])
    func tone(page: UInt32, expected: UInt32) throws {
        // A green photo fills the middle 80% of the columns at the join, as on X.
        let width = 100
        let pixels = (0..<(width * 20)).map { $0 % width < 10 || $0 % width >= 90 ? page : 0xff239447 }
        let part = try #require(ScrollingCaptureRaster(width: width, height: 20, pixels: pixels))
        let band = ScrollingCaptureBreakMark.band(width: width, height: 40, above: part, below: part, scale: 2,
            colorSpace: space)
        #expect(band.first == expected && band.last == expected)
        // The glyph's left stroke crosses the middle row 8 px left of centre.
        #expect((19...20).contains { y in (41...43).contains { band[y * width + $0] != expected } })
    }

    @Test("Joined output stops at the height limit, and so does its band")
    func limit() throws {
        let joined = try #require(ScrollingCaptureBreakMark.join([F.frame(0), F.frame(1000)], scale: 2,
            colorSpace: space, maximumHeight: 220))
        #expect(joined.raster.height == 220 && joined.bands == [200..<220])
    }
}
