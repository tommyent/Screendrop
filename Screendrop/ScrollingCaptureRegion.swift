import CoreGraphics

/// All rectangles use the display filter's top-left point coordinates.
nonisolated enum ScrollingCaptureRegion {
    static func matching(selection: CGRect, display: CGRect, frontToBackWindows: [CGRect]) -> CGRect {
        guard let index = frontToBackWindows.firstIndex(where: { $0.intersects(selection) }),
              frontToBackWindows[index].contains(selection) else { return selection }
        let visible = frontToBackWindows[index].intersection(display)
        let expanded = CGRect(x: selection.minX, y: visible.minY, width: selection.width, height: visible.height)
            .integral.intersection(display)
        guard expanded.contains(selection),
              !frontToBackWindows.prefix(index).contains(where: { $0.intersects(expanded) })
        else { return selection }
        return expanded
    }

    static func output(selection: CGRect, matching: CGRect, scale: CGFloat) -> ScrollingCaptureOutputRect {
        let left = Int(((selection.minX - matching.minX) * scale).rounded())
        let top = Int(((selection.minY - matching.minY) * scale).rounded())
        return ScrollingCaptureOutputRect(columns: left..<(left + Int((selection.width * scale).rounded())),
            rows: top..<(top + Int((selection.height * scale).rounded())))
    }
}

extension ScrollingCaptureRegion {
    /// Where the recovery panel goes, in AppKit screen points: the first spot
    /// on screen whose glass stays 8 pt clear of the region and the bar. Tried
    /// in turn: either side of the bar, beside the region (right, then left),
    /// past the region's far edge. With no room anywhere, the bar's far side,
    /// or its near side when the far side is off screen. Both panels keep
    /// `margin` of transparent room around their glass.
    static func recoveryPanelOrigin(size: CGSize, bar: CGRect, region: CGRect, visible: CGRect, margin: CGFloat) -> CGPoint {
        let gap: CGFloat = 8
        let barIsAbove = bar.minY >= region.maxY
        let aboveBar = CGPoint(x: bar.midX - size.width / 2, y: bar.maxY - 2 * margin + gap)
        let belowBar = CGPoint(x: aboveBar.x, y: bar.minY + 2 * margin - gap - size.height)
        let (farBar, nearBar) = barIsAbove ? (aboveBar, belowBar) : (belowBar, aboveBar)
        // Beside the region, glass level with its edge next to the bar.
        let sideY = min(max(barIsAbove ? region.maxY + margin - size.height : region.minY - margin, visible.minY),
                        visible.maxY - size.height)
        let farX = min(max(region.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let barGlass = bar.insetBy(dx: margin, dy: margin)
        return [
            farBar, nearBar,
            CGPoint(x: region.maxX + gap - margin, y: sideY),
            CGPoint(x: region.minX - gap + margin - size.width, y: sideY),
            CGPoint(x: farX, y: barIsAbove ? region.minY - gap + margin - size.height : region.maxY + gap - margin),
        ].first { origin in
            let frame = CGRect(origin: origin, size: size)
            let glass = frame.insetBy(dx: margin, dy: margin)
            return visible.contains(frame) && !glass.intersects(region) && !glass.intersects(barGlass)
        } ?? (farBar.y >= visible.minY && farBar.y + size.height <= visible.maxY ? farBar : nearBar)
    }
}
