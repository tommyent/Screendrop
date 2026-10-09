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
