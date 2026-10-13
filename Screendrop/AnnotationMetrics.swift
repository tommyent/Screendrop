//
//  AnnotationMetrics.swift
//  Screendrop
//

import AppKit

enum AnnotationTextMetrics {
    static let minimumFontSize: CGFloat = 9
    /// The largest text size the inspector sets: three digits in the font-size field.
    static let maximumFontSize: CGFloat = 999

    /// Keeps a text style's font size in range. An unbounded size can't be shown as a whole
    /// number, so it would crash every editor that displays it once saved to the style preset.
    static func clampedFontSize(_ size: CGFloat) -> CGFloat {
        size.isNaN ? minimumFontSize : min(max(size, minimumFontSize), maximumFontSize)
    }
    static let defaultFontName: String = "SF Pro"
}

enum AnnotationSizeStops {
    static let lineWidths: [CGFloat] = [1, 2, 3, 4, 6, 8, 12, 16]
    static let textSizes: [CGFloat] = [AnnotationTextMetrics.minimumFontSize]
        + [12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64, 72, 96]
            .filter { $0 > AnnotationTextMetrics.minimumFontSize }

    static func nearest(to value: CGFloat, in stops: [CGFloat]) -> CGFloat {
        stops.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    /// An off-stop value moves in the requested direction, without rounding first.
    static func step(from value: CGFloat, by direction: Int, in stops: [CGFloat]) -> CGFloat {
        if direction < 0 { return stops.last(where: { $0 < value }) ?? value }
        return stops.first(where: { $0 > value }) ?? value
    }
}
