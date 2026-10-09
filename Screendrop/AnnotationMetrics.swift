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
