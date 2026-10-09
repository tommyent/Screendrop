import CoreGraphics
import Foundation
import Testing

private final class StitcherFixtureBundle: NSObject {}

enum StitcherFixtures {
    /// Width/height as little-endian UInt32s, then sRGB BGRA8 rows, losslessly compressed by Foundation.
    static func load(_ name: String) throws -> CGImage {
        let url = try #require(Bundle(for: StitcherFixtureBundle.self).url(forResource: name, withExtension: "bgra.lzma"))
        let compressed = try Data(contentsOf: url)
        let data = try (compressed as NSData).decompressed(using: .lzma) as Data
        try #require(data.count >= 8)
        func dimension(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
        }
        let width = dimension(0), height = dimension(4)
        try #require((1...4096).contains(width) && (1...4096).contains(height))
        try #require(data.count == 8 + width * height * 4)
        let pixels = Data(data.dropFirst(8))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: CGDataProvider(data: pixels as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    }
}
