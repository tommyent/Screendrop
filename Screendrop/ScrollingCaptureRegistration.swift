import Foundation

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
