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

/// In-memory, top-to-bottom BGRA pixels. No capture, image decoding or UI side effects.
nonisolated struct ScrollingCaptureRaster: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt32]
    let matchingColumns: [Range<Int>]
    private let rowHashes: [Int]
    private let blankRows: [Bool]

    init?(width: Int, height: Int, pixels: [UInt32], matchingColumns: [Range<Int>]? = nil) {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= Int.max / height, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
        let columns = matchingColumns ?? [0..<width]
        guard !columns.isEmpty, columns.allSatisfy({ !$0.isEmpty && $0.lowerBound >= 0 && $0.upperBound <= width }),
              zip(columns, columns.dropFirst()).allSatisfy({ $0.upperBound <= $1.lowerBound }) else { return nil }
        self.matchingColumns = columns
        var hashes: [Int] = []
        var blanks: [Bool] = []
        for y in 0..<height {
            var hasher = Hasher()
            let first = pixels[y * width + columns[0].lowerBound]
            var blank = true
            for range in columns { for pixel in pixels[(y * width + range.lowerBound)..<(y * width + range.upperBound)] {
                hasher.combine(pixel)
                if pixel != first { blank = false }
            } }
            hashes.append(hasher.finalize())
            blanks.append(blank)
        }
        rowHashes = hashes
        blankRows = blanks
    }

    func row(_ y: Int) -> ArraySlice<UInt32> { pixels[(y * width)..<((y + 1) * width)] }
    func sameRow(_ y: Int, as other: Self, at otherY: Int) -> Bool {
        matchingColumns == other.matchingColumns && rowHashes[y] == other.rowHashes[otherY]
            && matchingColumns.allSatisfy { columns in
                pixels[(y * width + columns.lowerBound)..<(y * width + columns.upperBound)]
                    .elementsEqual(other.pixels[(otherY * width + columns.lowerBound)..<(otherY * width + columns.upperBound)])
            }
    }
    func rowHash(_ y: Int) -> Int {
        rowHashes[y]
    }
    func isBlank(_ y: Int) -> Bool { blankRows[y] }
    func using(columns: [Range<Int>]) -> Self? {
        if columns == matchingColumns { return self }
        return Self(width: width, height: height, pixels: pixels, matchingColumns: columns)
    }
}
