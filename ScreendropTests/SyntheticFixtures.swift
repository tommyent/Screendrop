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

    /// A list with pinned chrome, distinct text rows and icons that redraw by 1–2 levels.
    static func list(offset: Int, redraw: Int) -> CGImage {
        image(width: 2460, height: 1658) { x, y in
            if y < 30 || y >= 1638 { return (224, 224, 224) }
            let py = offset + y - 30
            if x < 160 {
                let icon = py % 36 < 28 && (16..<144).contains(x)
                let value = UInt8(icon ? 100 + redraw : 240)
                return (value, value, value)
            }
            if py % 32 >= 16 { return (250, 250, 250) }
            let value = UInt8(32 + (py * 17 + x * 11) % 192)
            return (value, UInt8(32 + (py / 256) % 192), UInt8(32 + (x / 7 + py * 3) % 192))
        }
    }

    /// A pinned sidebar beside a broad playing video; scrolling loses all still-text overlap.
    static func video(offset: Int, phase: UInt32) -> CGImage {
        image(width: 3000, height: 1180) { x, y in
            if x < 740 {
                return (UInt8(32 + y / 256 * 17), UInt8(truncatingIfNeeded: y), UInt8(40 + x % 31))
            }
            guard (1026..<2801).contains(x) else { return (250, 250, 250) }
            let py = offset + y
            if (300..<1180).contains(py) {
                var n = UInt32(py) &* 0x9E3779B9 ^ UInt32(x) &* 0x85EBCA6B ^ phase &* 0xC2B2AE35
                n ^= n >> 13; n &*= 0x85EBCA6B; n ^= n >> 16
                return (UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n >> 16))
            }
            if py % 24 >= 16 { return (250, 250, 250) }
            return (UInt8(32 + py / 256 * 17), UInt8(truncatingIfNeeded: py), UInt8(40 + x % 31))
        }
    }
}
