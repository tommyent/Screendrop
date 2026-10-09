import CoreGraphics
import Foundation

/// One pixel's colour in sRGB, 0–255 per channel, alpha straight (not
/// premultiplied). The pixel inspector reads, formats and compares these.
nonisolated struct PixelColor: Hashable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8 = 255

    /// `#1E90FF`, alpha left out.
    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// CSS Color 4: `rgb(30 144 255)`, or `rgb(30 144 255 / 0.5)` when not opaque.
    var css: String {
        let rgb = "\(red) \(green) \(blue)"
        guard alpha < 255 else { return "rgb(\(rgb))" }
        return "rgb(\(rgb) / \(Self.decimal(Double(alpha) / 255, places: 2)))"
    }

    /// `Color(red: 0.118, green: 0.565, blue: 1.000)`, with `opacity:` when not opaque.
    var swiftUI: String {
        let parts = [("red", red), ("green", green), ("blue", blue)]
            .map { "\($0.0): \(Self.decimal(Double($0.1) / 255, places: 3))" }
            .joined(separator: ", ")
        guard alpha < 255 else { return "Color(\(parts))" }
        return "Color(\(parts), opacity: \(Self.decimal(Double(alpha) / 255, places: 3)))"
    }

    /// WCAG 2 relative luminance of the sRGB colour.
    var relativeLuminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private static func decimal(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", value)
    }
}

/// How a colour is copied from the inspector.
nonisolated enum PixelColorFormat: String, CaseIterable, Identifiable, Sendable {
    case hex = "Hex"
    case css = "CSS"
    case swiftUI = "SwiftUI"

    var id: String { rawValue }

    func string(for color: PixelColor) -> String {
        switch self {
        case .hex: color.hex
        case .css: color.css
        case .swiftUI: color.swiftUI
        }
    }
}

/// The WCAG 2 contrast between two colours, with the pass marks for text.
nonisolated struct PixelContrast: Equatable, Sendable {
    let ratio: Double

    init(_ first: PixelColor, _ second: PixelColor) {
        let (a, b) = (first.relativeLuminance, second.relativeLuminance)
        ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Two decimals, cut rather than rounded, so a failing 4.499 never
    /// shows as a passing-looking 4.50 (WCAG doesn't round).
    var display: String { String(format: "%.2f:1", (ratio * 100).rounded(.down) / 100) }

    var passesAANormal: Bool { ratio >= 4.5 }
    var passesAALarge: Bool { ratio >= 3 }
    var passesAAANormal: Bool { ratio >= 7 }
    var passesAAALarge: Bool { ratio >= 4.5 }
}

/// A screenshot's pixels at full resolution, read once when inspection
/// starts: the editor's preview may be downscaled, so it can't give exact
/// colours. Stored as straight-alpha sRGB, row 0 at the top.
nonisolated struct PixelBuffer: Sendable {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

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

    /// How much two neighbouring pixels may differ, per channel, and still
    /// count as one surface. Like Shottr's ruler: steps of 8 out of 255 are
    /// ignored, steps of 16 stop it.
    static let edgeTolerance = 12

    /// The run of pixels around `x`, `y` with no edge between them, along
    /// each axis. With `includingBorder`, each end also takes the pixel that
    /// stopped it, so a 200 px box with a 1 px border measures 202.
    func span(x: Int, y: Int, includingBorder: Bool = false) -> (horizontal: ClosedRange<Int>, vertical: ClosedRange<Int>)? {
        guard color(x: x, y: y) != nil else { return nil }
        func run(_ step: (Int) -> (x: Int, y: Int), limit: Int, from start: Int) -> ClosedRange<Int> {
            func end(_ direction: Int) -> Int {
                var position = start
                while true {
                    let next = position + direction
                    guard (0..<limit).contains(next) else { return position }
                    let a = step(position), b = step(next)
                    if isEdge(color(x: a.x, y: a.y)!, color(x: b.x, y: b.y)!) {
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

    private func isEdge(_ a: PixelColor, _ b: PixelColor) -> Bool {
        func delta(_ p: UInt8, _ q: UInt8) -> Int { abs(Int(p) - Int(q)) }
        return max(delta(a.red, b.red), delta(a.green, b.green), delta(a.blue, b.blue), delta(a.alpha, b.alpha))
            > Self.edgeTolerance
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
