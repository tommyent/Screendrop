import CoreGraphics
import Foundation
import Testing

struct PixelMathTests {
    @Test func resizedPixelsKeepProfileTransparencyAndAspect() throws {
        for name in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let space = try #require(CGColorSpace(name: name))
            for (width, height, expectedWidth, expectedHeight) in [(9, 6, 3, 2), (6, 9, 2, 3)] {
                let bytes = Data(Array(repeating: [UInt8(64), 32, 16, 128], count: width * height).flatMap { $0 })
                let source = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent))
                let buffer = try #require(PixelBuffer(image: source))
                #expect(buffer.resized(maxPixelSize: 100) === buffer.image)
                let resized = try #require(buffer.resized(maxPixelSize: 3))
                #expect(resized.width == expectedWidth && resized.height == expectedHeight)
                #expect(CFEqual(resized.colorSpace, space))
                let pixels = try #require(PixelBuffer(image: resized))
                for y in 0..<resized.height {
                    for x in 0..<resized.width {
                        #expect(pixels.color(x: x, y: y) == buffer.color(x: 0, y: 0))
                    }
                }
            }
        }
    }

    @Test func decodedPixelsKeepTheirProfileAlphaAndRowOrder() throws {
        for name in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let space = try #require(CGColorSpace(name: name))
            // Odd width and padding: vImage must write the tightly packed destination stride.
            let bytes = Data([64,32,16,128, 255,0,0,255, 0,255,0,255, 0,0,0,0,
                              0,0,255,255, 255,255,255,255, 0,0,0,0, 0,0,0,0])
            let source = try #require(CGImage(width: 3, height: 2, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: 16, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent))
            let buffer = try #require(PixelBuffer(image: source))
            #expect(CFEqual(buffer.image.colorSpace, space))
            #expect(buffer.image.bytesPerRow == 12)
            #expect(buffer.color(x: 0, y: 0)?.alpha == 128)
            #expect(buffer.color(x: 2, y: 1) == PixelColor(red: 0, green: 0, blue: 0, alpha: 0))
            let reference = try #require(CGContext(data: nil, width: 3, height: 2,
                bitsPerComponent: 8, bytesPerRow: 12, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            reference.draw(source, in: CGRect(x: 0, y: 0, width: 3, height: 2))
            let pixels = reference.data!.assumingMemoryBound(to: UInt8.self)
            for (x, y) in [(1, 0), (2, 0), (0, 1), (1, 1)] {
                let color = try #require(buffer.color(x: x, y: y))
                let i = (y * 3 + x) * 4
                #expect(abs(Int(color.red) - Int(pixels[i])) <= 1)
                #expect(abs(Int(color.green) - Int(pixels[i + 1])) <= 1)
                #expect(abs(Int(color.blue) - Int(pixels[i + 2])) <= 1)
            }
        }
    }

    @Test func decodedGrayscalePixelsRemainReadable() throws {
        let bytes = Data([20, 80, 140, 0, 200, 240, 255, 0])
        let source = try #require(CGImage(width: 3, height: 2, bitsPerComponent: 8,
            bitsPerPixel: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let buffer = try #require(PixelBuffer(image: source))
        #expect(buffer.width == 3 && buffer.height == 2)
        #expect(buffer.color(x: 2, y: 1) == PixelColor(red: 255, green: 255, blue: 255))
        let reference = try #require(CGContext(data: nil, width: 3, height: 2,
            bitsPerComponent: 8, bytesPerRow: 12, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        reference.draw(source, in: CGRect(x: 0, y: 0, width: 3, height: 2))
        let pixels = reference.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<2 {
            for x in 0..<3 {
                let color = try #require(buffer.color(x: x, y: y))
                #expect(abs(Int(color.red) - Int(pixels[(y * 3 + x) * 4])) <= 1)
                #expect(color.red == color.green && color.green == color.blue && color.alpha == 255)
            }
        }
    }

    @Test func syntheticFaintHeaderEdges() throws {
        // Flat surfaces differ by only 6–8 levels: the faint-edge path must find them.
        let source = SyntheticFixtures.faintHeaderEdges()
        let buffer = try #require(PixelBuffer(image: source))
        #expect(buffer.span(x: 0, y: 250)?.vertical == 223...290)
        #expect(buffer.span(x: 0, y: 210)?.vertical == 199...222)
        #expect(buffer.span(x: 0, y: 250, includingBorder: true)?.vertical == 222...291)
        #expect(buffer.span(x: 1, y: 250)?.vertical == 223...290)
    }

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
