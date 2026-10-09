import CoreGraphics
import Foundation

/// One pixel's colour in sRGB, 0–255 per channel, alpha straight (not
/// premultiplied). The editor shows and copies the one under the pointer.
nonisolated struct PixelColor: Hashable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8 = 255

    /// `#1E90FF`, alpha left out.
    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
}

/// A screenshot's pixels at full resolution, read once per base image: the
/// editor's preview may be downscaled, so it can't give exact colours.
/// Stored as straight-alpha sRGB, row 0 at the top.
nonisolated struct PixelBuffer: Sendable {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    /// Force ImageIO's lazy source through one bitmap before a loupe draws it repeatedly.
    static func decodedImage(_ image: CGImage) -> CGImage? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Draws `image` into an sRGB buffer of its own pixel size. Colours from
    /// a Display P3 capture come out as their sRGB values, as CSS hex expects.
    init?(image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// The pixel at `x`, `y` (0,0 top left), nil outside the image.
    func color(x: Int, y: Int) -> PixelColor? {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        let i = (y * width + x) * 4
        let alpha = bytes[i + 3]
        func straight(_ value: UInt8) -> UInt8 {
            guard alpha > 0, alpha < 255 else { return alpha == 0 ? 0 : value }
            return UInt8(min(255, (Double(value) * 255 / Double(alpha)).rounded()))
        }
        return PixelColor(red: straight(bytes[i]), green: straight(bytes[i + 1]), blue: straight(bytes[i + 2]), alpha: alpha)
    }

    /// A step between neighbouring pixels larger than this, in any channel,
    /// is always an edge.
    static let edgeTolerance = 12
    /// A smaller step of at least this is an edge too, when it's between
    /// flat surfaces: dark UIs draw cards and headers 6–8 levels off their
    /// background (sd-p31 feedback, the Inbox's "Quiet" header).
    static let faintEdgeStep = 3

    /// The run of pixels around `x`, `y` with no edge between them, along
    /// each axis. With `includingBorder`, each end also takes the pixel that
    /// stopped it, so a 200 px box with a 1 px border measures 202.
    func span(x: Int, y: Int, includingBorder: Bool = false) -> (horizontal: ClosedRange<Int>, vertical: ClosedRange<Int>)? {
        guard color(x: x, y: y) != nil else { return nil }
        func run(_ step: (Int) -> (x: Int, y: Int), limit: Int, from start: Int) -> ClosedRange<Int> {
            func pixel(_ i: Int) -> PixelColor? {
                guard (0..<limit).contains(i) else { return nil }
                let p = step(i)
                return color(x: p.x, y: p.y)
            }
            func end(_ direction: Int) -> Int {
                var position = start
                while true {
                    let next = position + direction
                    guard (0..<limit).contains(next) else { return position }
                    if Self.isEdge({ pixel(position + $0 * direction) }) {
                        return includingBorder ? next : position
                    }
                    position = next
                }
            }
            return end(-1)...end(1)
        }
        return (
            run({ ($0, y) }, limit: width, from: x),
            run({ (x, $0) }, limit: height, from: y)
        )
    }

    /// Whether an edge follows `pixel(0)`, the last pixel walked; `pixel(n)`
    /// is n further on, or back for negative n, and nil past the image. A
    /// faint step counts only between flat surfaces: flat up to `pixel(0)`,
    /// then a change within 1 or 2 px (an antialiased edge), then flat
    /// again, or back as before for a 1 px line. Flat means identical
    /// neighbours, as UI surfaces are in a screenshot; gradients and soft
    /// shadows steep enough to step 3 levels never repeat a value, so the
    /// ruler runs through them.
    static func isEdge(_ pixel: (Int) -> PixelColor?) -> Bool {
        guard let a = pixel(0), let b = pixel(1) else { return false }
        if difference(a, b) > edgeTolerance { return true }
        func flat(_ i: Int, _ j: Int) -> Bool {
            guard let p = pixel(i), let q = pixel(j) else { return true }
            return p == q
        }
        func faint(_ i: Int) -> Bool { pixel(i).map { difference(a, $0) >= faintEdgeStep } ?? false }
        guard flat(-1, 0) else { return false }
        return faint(1) && (flat(1, 2) || flat(0, 2))
            || !flat(0, 1) && faint(2) && flat(2, 3)
    }

    /// The largest per-channel difference, alpha included.
    private static func difference(_ a: PixelColor, _ b: PixelColor) -> Int {
        func delta(_ p: UInt8, _ q: UInt8) -> Int { abs(Int(p) - Int(q)) }
        return max(delta(a.red, b.red), delta(a.green, b.green), delta(a.blue, b.blue), delta(a.alpha, b.alpha))
    }
}

/// A ruler length in the units people know from design tools: points from
/// the image's DPI, with the pixels beside them. A 72 DPI image shows pixels
/// only, since they're the same number.
nonisolated enum PixelMeasurement {
    static func label(pixels: Int, pixelsPerPoint: CGFloat) -> String {
        guard pixelsPerPoint > 1.001 else { return "\(pixels) px" }
        let points = Double(pixels) / Double(pixelsPerPoint)
        let shown = points.rounded() == points ? String(Int(points)) : String(format: "%.1f", points)
        return "\(shown) pt · \(pixels) px"
    }
}

nonisolated struct PixelPoint: Hashable, Sendable {
    var x: Int
    var y: Int
}

extension PixelBuffer {
    /// The pixel drawn under a canvas point when the image fills
    /// `imageFrame`: the engine's screenToPage, done here without moving
    /// the engine's own viewport. Nil off the image.
    nonisolated func pixel(at point: CGPoint, imageFrame: CGRect) -> PixelPoint? {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return nil }
        let x = Int(((point.x - imageFrame.minX) / imageFrame.width * CGFloat(width)).rounded(.down))
        let y = Int(((point.y - imageFrame.minY) / imageFrame.height * CGFloat(height)).rounded(.down))
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        return PixelPoint(x: x, y: y)
    }
}

/// Which way the arrow-key ruler measures (sd-p31).
nonisolated enum PixelMeasureAxis: Sendable {
    /// ← or →: the width of the run through the pointer.
    case horizontal
    /// ↑ or ↓: its height.
    case vertical
}

/// The arrow-key ruler at one pointer position: the run of pixels through
/// it along one axis, from edge to edge.
nonisolated struct PixelRuler: Equatable, Sendable {
    let axis: PixelMeasureAxis
    /// The run's ends in page space, the image's own pixel space: the outer
    /// edges of its first and last pixels, through the middle of the
    /// pointer's row or column.
    let pageStart: CGPoint
    let pageEnd: CGPoint
    /// The same ends in canvas points.
    let start: CGPoint
    let end: CGPoint
    let pixels: Int
    let label: String

    init?(buffer: PixelBuffer, imageFrame: CGRect, pointer: CGPoint, axis: PixelMeasureAxis,
          includingBorder: Bool, pixelsPerPoint: CGFloat) {
        guard let pixel = buffer.pixel(at: pointer, imageFrame: imageFrame),
              let span = buffer.span(x: pixel.x, y: pixel.y, includingBorder: includingBorder) else { return nil }
        let run = axis == .horizontal ? span.horizontal : span.vertical
        let across = CGFloat(axis == .horizontal ? pixel.y : pixel.x) + 0.5
        let from = CGFloat(run.lowerBound), to = CGFloat(run.upperBound + 1)
        let pageStart = axis == .horizontal ? CGPoint(x: from, y: across) : CGPoint(x: across, y: from)
        let pageEnd = axis == .horizontal ? CGPoint(x: to, y: across) : CGPoint(x: across, y: to)
        func canvas(_ page: CGPoint) -> CGPoint {
            CGPoint(x: imageFrame.minX + page.x / CGFloat(buffer.width) * imageFrame.width,
                    y: imageFrame.minY + page.y / CGFloat(buffer.height) * imageFrame.height)
        }
        self.axis = axis
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        start = canvas(pageStart)
        end = canvas(pageEnd)
        pixels = run.count
        label = PixelMeasurement.label(pixels: run.count, pixelsPerPoint: pixelsPerPoint)
    }
}
