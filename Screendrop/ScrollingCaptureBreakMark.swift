import CoreGraphics

/// Joins the parts of a Scrolling Capture that lost track part-way. Where the
/// pixels prove a part continues the one above it, the two join seamlessly;
/// anywhere else a band marks the break: added rows in the page's own tone
/// with a `//` glyph, so no captured pixel is lost or covered.
nonisolated enum ScrollingCaptureBreakMark {
    /// The band's height in points.
    static let bandPoints: CGFloat = 20

    /// The parts, top to bottom and of equal width, joined and cut at
    /// `maximumHeight`. `bands` are the rows each remaining band occupies.
    static func join(_ parts: [ScrollingCaptureRaster], scale: CGFloat, colorSpace: CGColorSpace,
                     maximumHeight: Int) -> (raster: ScrollingCaptureRaster, bands: [Range<Int>])? {
        guard var above = parts.first, parts.allSatisfy({ $0.width == above.width }) else { return nil }
        var pixels = above.pixels
        var bands: [Range<Int>] = []
        for below in parts.dropFirst() {
            if let start = continuation(of: above, by: below) {
                // The part above already holds rows start..<above.height of this one.
                let extra = below.height - (above.height - start)
                guard extra > 0 else { continue }
                pixels += below.pixels.suffix(extra * below.width)
            } else {
                let height = max(1, Int((bandPoints * scale).rounded()))
                let top = pixels.count / above.width
                pixels += band(width: above.width, height: height, above: above, below: below,
                               scale: scale, colorSpace: colorSpace)
                bands.append(top..<(top + height))
                pixels += below.pixels
            }
            above = below
        }
        let height = min(pixels.count / parts[0].width, maximumHeight)
        guard let raster = ScrollingCaptureRaster(width: parts[0].width, height: height,
                                                  pixels: Array(pixels.prefix(height * parts[0].width))) else { return nil }
        return (raster, bands.filter { $0.lowerBound < height }.map { $0.lowerBound..<min($0.upperBound, height) })
    }

    /// Where `below` starts in `above`: the one offset at which every row the
    /// two share is identical, over at least 8 distinct non-blank rows. Nil
    /// when no offset or more than one qualifies.
    static func continuation(of above: ScrollingCaptureRaster, by below: ScrollingCaptureRaster) -> Int? {
        let columns = [0..<above.width]
        guard let above = above.using(columns: columns), let below = below.using(columns: columns) else { return nil }
        var found: Int?
        for start in 0..<above.height where above.sameRow(start, as: below, at: 0) {
            let shared = min(above.height - start, below.height)
            guard (0..<shared).allSatisfy({ above.sameRow(start + $0, as: below, at: $0) }),
                  Set((0..<shared).filter { !below.isBlank($0) }.map(below.rowHash)).count >= 8 else { continue }
            guard found == nil else { return nil }
            found = start
        }
        return found
    }

    /// The page's colour beside the join, one step darker on a light page or
    /// lighter on a dark one, with the glyph in strong contrast.
    static func band(width: Int, height: Int, above: ScrollingCaptureRaster, below: ScrollingCaptureRaster,
                     scale: CGFloat, colorSpace: CGColorSpace) -> [UInt32] {
        let page = pageColor(above: above, below: below)
        let channels = [(page >> 16) & 0xff, (page >> 8) & 0xff, page & 0xff].map(Int.init)
        let isLight = channels.reduce(0, +) / 3 > 128
        func shifted(_ amount: Int) -> [CGFloat] {
            channels.map { CGFloat(min(255, max(0, $0 + (isLight ? -amount : amount)))) / 255 } + [1]
        }
        var pixels = [UInt32](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  let fill = CGColor(colorSpace: colorSpace, components: shifted(16)),
                  let ink = CGColor(colorSpace: colorSpace, components: shifted(110)) else { return }
            context.setFillColor(fill)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // The `//` of a broken chart axis: two strokes 12 pt tall, 8 pt apart.
            let midX = CGFloat(width) / 2, midY = CGFloat(height) / 2
            context.setStrokeColor(ink)
            context.setLineWidth(1.5 * scale)
            context.setLineCap(.round)
            for offset in [-4 * scale, 4 * scale] {
                context.move(to: CGPoint(x: midX + offset - 4 * scale, y: midY - 6 * scale))
                context.addLine(to: CGPoint(x: midX + offset + 4 * scale, y: midY + 6 * scale))
            }
            context.strokePath()
        }
        return pixels
    }

    /// The most common pixel in the outer 5% of columns, over 8 rows either
    /// side of the join. Media rarely reaches the margins; the join's own row
    /// can run through a photo.
    private static func pageColor(above: ScrollingCaptureRaster, below: ScrollingCaptureRaster) -> UInt32 {
        let margin = max(1, above.width / 20)
        var counts: [UInt32: Int] = [:]
        for (raster, rows) in [(above, max(0, above.height - 8)..<above.height), (below, 0..<min(8, below.height))] {
            for y in rows {
                let row = raster.row(y)
                for pixel in row.prefix(margin) { counts[pixel, default: 0] += 1 }
                for pixel in row.suffix(margin) { counts[pixel, default: 0] += 1 }
            }
        }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 0xffffffff
    }
}
