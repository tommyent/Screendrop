import SwiftUI

/// The app's one spacing, corner and type scale (design pass, 2026-10-09).
/// Screens use these instead of literals so they match each other;
/// component metrics such as `InspectorMetrics` are built from them.
/// Not for export or canvas geometry, saved layouts, hit targets or
/// AppKit-matched sizes, which keep their own numbers.
enum DS {
    /// Gaps and insets, in points.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let ml: CGFloat = 10
        static let l: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
    }

    /// Corner radii. A shape inset inside another takes the outer radius
    /// minus the inset, so the curves stay concentric.
    enum Radius {
        static let xs: CGFloat = 3
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 10
        static let card: CGFloat = 14
        static let panel: CGFloat = 20
    }

    /// Text roles, smallest first, on macOS's own text sizes.
    enum TypeScale {
        static let caption = Font.system(size: 10)
        static let label = Font.system(size: 11)
        static let labelMedium = Font.system(size: 11, weight: .medium)
        static let labelSemibold = Font.system(size: 11, weight: .semibold)
        static let secondary = Font.system(size: 12)
        static let body = Font.system(size: 13)
        static let title = Font.system(size: 15, weight: .semibold)
    }
}
