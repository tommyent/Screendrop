import CoreGraphics
import Foundation
import Testing

struct PixelMathTests {
    private func image(_ width: Int, _ height: Int = 1, paint: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        paint(context)
        return context.makeImage()!
    }

    private func row(_ values: [(Int, Int, Int)]) -> PixelBuffer {
        PixelBuffer(image: image(values.count) { context in
            for (x, v) in values.enumerated() {
                context.setFillColor(CGColor(srgbRed: CGFloat(v.0) / 255, green: CGFloat(v.1) / 255,
                                            blue: CGFloat(v.2) / 255, alpha: 1))
                context.fill(CGRect(x: x, y: 0, width: 1, height: 1))
            }
        })!
    }
    private func grey(_ values: [Int]) -> PixelBuffer { row(values.map { ($0, $0, $0) }) }
    private func flat(_ v: Int, _ n: Int) -> [Int] { Array(repeating: v, count: n) }
    private func run(_ b: PixelBuffer, _ x: Int, border: Bool = false) -> ClosedRange<Int>? {
        b.span(x: x, y: 0, includingBorder: border)?.horizontal
    }

    @Test func flatSurfaceEdges() {
        #expect(run(grey(flat(200, 50) + flat(224, 50)), 10) == 0...49)
        #expect(run(grey(flat(200, 50) + flat(202, 50)), 10) == 0...99)
        #expect(run(grey(flat(200, 50) + flat(203, 50)), 10) == 0...49)
        #expect(run(grey(flat(200, 50) + flat(208, 50)), 70) == 50...99)
        #expect(run(row(Array(repeating: (21, 27, 36), count: 50)
                        + Array(repeating: (27, 34, 44), count: 50)), 10) == 0...49)
    }

    @Test func antialiasedEdgesAndHairlines() {
        #expect(run(grey(flat(21, 50) + [24] + flat(27, 50)), 10) == 0...49)
        #expect(run(grey(flat(21, 50) + [23] + flat(27, 50)), 10) == 0...49)
        #expect(run(grey(flat(21, 50) + [23] + flat(27, 50)), 80) == 51...100)
        #expect(run(grey(flat(21, 50) + [27] + flat(21, 50)), 10) == 0...49)
        #expect(run(grey(flat(21, 50) + [27] + flat(21, 50)), 10, border: true) == 0...50)
        let box = grey(flat(255, 10) + [0] + flat(237, 20) + [0] + flat(255, 10))
        #expect(run(box, 20) == 11...30)
        #expect(run(box, 20, border: true) == 10...31)
    }

    @Test(arguments: [0.3, 0.5, 0.8, 1, 1.2, 1.3, 1.5, 1.7, 2, 2.5, 3, 4, 6, 10])
    func gradientsHaveNoFalseEdge(slope: Double) {
        let n = Int(240 / slope)
        let ramp = (0..<n).map { 10 + Int((Double($0) * slope).rounded()) }
        #expect(run(grey(ramp), n / 2) == 0...(n - 1))
        let framed = flat(10, 30) + ramp + flat(ramp.last!, 30)
        #expect(run(grey(framed), 30 + n / 2) == 0...(framed.count - 1))
    }

    @Test(arguments: [2.0, 3, 4, 5, 6, 8, 10, 15, 20, 30])
    func softShadowsRunToTheCard(sigma: Double) {
        let shadow = (0..<200).map { x in
            240 - Int((60 * (1 + erf((Double(x) - 160) / (sigma * 2.squareRoot()))) / 2).rounded())
        }
        #expect(run(grey(shadow + flat(255, 40)), 20) == 0...199)
    }

    @Test func rulerGeometryAndLabels() throws {
        let picture = image(400, 300) { c in
            func fill(_ r: CGRect, _ red: Int, _ green: Int, _ blue: Int) {
                c.setFillColor(CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                                      blue: CGFloat(blue) / 255, alpha: 1)); c.fill(r)
            }
            fill(CGRect(x: 0, y: 0, width: 400, height: 300), 248, 248, 250)
            fill(CGRect(x: 100, y: 100, width: 202, height: 102), 40, 40, 48)
            fill(CGRect(x: 101, y: 101, width: 200, height: 100), 255, 255, 255)
            fill(CGRect(x: 130, y: 130, width: 60, height: 20), 30, 144, 255)
        }
        let buffer = try #require(PixelBuffer(image: picture))
        let frame = CGRect(x: 40, y: 40, width: 800, height: 600)
        let pointer = CGPoint(x: 541, y: 381)
        let v = try #require(PixelRuler(buffer: buffer, imageFrame: frame, pointer: pointer,
                                      axis: .vertical, includingBorder: false, pixelsPerPoint: 2))
        #expect(v.pixels == 100 && v.label == "50 pt · 100 px")
        #expect(v.pageStart == CGPoint(x: 250.5, y: 101) && v.pageEnd == CGPoint(x: 250.5, y: 201))
        #expect(v.start == CGPoint(x: 541, y: 242) && v.end == CGPoint(x: 541, y: 442))
        let h = try #require(PixelRuler(buffer: buffer, imageFrame: frame, pointer: pointer,
                                      axis: .horizontal, includingBorder: false, pixelsPerPoint: 2))
        #expect(h.pixels == 200 && h.label == "100 pt · 200 px")
        #expect(h.pageStart == CGPoint(x: 101, y: 170.5) && h.pageEnd == CGPoint(x: 301, y: 170.5))
        #expect(PixelRuler(buffer: buffer, imageFrame: frame, pointer: pointer, axis: .horizontal,
                           includingBorder: true, pixelsPerPoint: 2)?.pixels == 202)
        #expect(PixelRuler(buffer: buffer, imageFrame: frame, pointer: CGPoint(x: 10, y: 10),
                           axis: .vertical, includingBorder: false, pixelsPerPoint: 2) == nil)
        #expect(PixelMeasurement.label(pixels: 101, pixelsPerPoint: 2) == "50.5 pt · 101 px")
        #expect(PixelMeasurement.label(pixels: 101, pixelsPerPoint: 1) == "101 px")
    }
}
