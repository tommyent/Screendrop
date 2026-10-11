import CoreGraphics
import Foundation

/// Procedural pixels only: no source screenshots, fonts, names or application content.
enum SyntheticFixtures {
    private static func image(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let (r, g, b) = pixel(x, y)
            let i = (y * width + x) * 4
            bytes[i] = b; bytes[i + 1] = g; bytes[i + 2] = r
        } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func faintHeaderEdges() -> CGImage {
        image(width: 2, height: 1568) { _, y in
            let value: UInt8 = y < 199 ? 21 : y < 223 ? 27 : y < 291 ? 34 : 42
            return (value, value, value)
        }
    }
}
