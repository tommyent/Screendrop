import CoreGraphics
import Foundation

/// Frames as the estimator, verifier and stitcher take them: tightly packed
/// BGRA rows (premultipliedFirst, little endian). CGImage only at these edges.
nonisolated enum ScrollingCapturePixels {
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// The image's own color space when it can be drawn into, else sRGB, so
    /// a capture's pixels are copied, not converted.
    static func colorSpace(of image: CGImage) -> CGColorSpace {
        image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    static func bytes(of image: CGImage, in colorSpace: CGColorSpace) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace, bitmapInfo: bitmapInfo)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? pixels : nil
    }

    static func image(_ pixels: [UInt8], width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
