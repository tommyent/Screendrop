import CoreGraphics
import Foundation

/// All rectangles use the display filter's top-left point coordinates.
nonisolated enum ScrollingCaptureRegion {
    /// The frame area frames are captured from, and why.
    struct Matching: Equatable, Sendable {
        enum Reason: String, Sendable {
            /// The selection's columns over the target window's whole visible height.
            case expanded
            /// As expanded, stopped short of windows in front of the target.
            case clipped
            /// The front-most window over the selection isn't one to scroll
            /// (a floating window covering it, say), so frames stay the selection.
            case frontNotTarget
            /// No single window holds the selection.
            case selectionNotInWindow
        }
        let rect: CGRect
        let reason: Reason
        /// Indexes into the windows passed in: those that clipped the
        /// expansion, or the front window that stopped it.
        let obstacles: [Int]
        /// The window frames were expanded over, when there was one.
        var target: Int? = nil
        /// Windows in front that cover the whole display, left out (see `matching`).
        var ignored: [Int] = []
    }

    /// Frames reach above and below the selection, over the target window's
    /// visible height, so a tall video fits whole in one frame. Windows in
    /// front of the target (floating utilities, the Dock) cut that height
    /// short instead of switching it off: the frames stay display captures
    /// with exact pixels, and never include another app's window.
    static func matching(selection: CGRect, display: CGRect,
                         frontToBackWindows windows: [(frame: CGRect, isTarget: Bool)]) -> Matching {
        // A window covering the whole display (the Dock's, Notification
        // Center's) draws mostly nothing, and whatever it draws lands on the
        // selection too, so it's neither the window over the selection nor an
        // obstacle. Each such window is in front of every app, alpha 1.
        let ignored = windows.indices.filter { windows[$0].frame.contains(display) }
        let considered = windows.indices.filter { !ignored.contains($0) }
        guard let index = considered.first(where: { windows[$0].frame.intersects(selection) }) else {
            return Matching(rect: selection, reason: .selectionNotInWindow, obstacles: [], ignored: ignored)
        }
        guard windows[index].isTarget else {
            return Matching(rect: selection, reason: .frontNotTarget, obstacles: [index], ignored: ignored)
        }
        guard windows[index].frame.contains(selection) else {
            return Matching(rect: selection, reason: .selectionNotInWindow, obstacles: [], ignored: ignored)
        }
        let visible = windows[index].frame.intersection(display)
        var top = visible.minY, bottom = visible.maxY
        var obstacles: [Int] = []
        // Nothing in front touches the selection itself, so each window over
        // its columns is wholly above or below it.
        for i in considered where i < index {
            let window = windows[i]
            guard window.frame.minX < selection.maxX && window.frame.maxX > selection.minX
                && window.frame.minY < visible.maxY && window.frame.maxY > visible.minY else { continue }
            if window.frame.maxY <= selection.minY {
                top = max(top, window.frame.maxY)
            } else {
                bottom = min(bottom, window.frame.minY)
            }
            obstacles.append(i)
        }
        // Whole points, rounded inward, so no edge of a window in front is captured.
        let rect = CGRect(x: selection.minX, y: top.rounded(.up), width: selection.width,
                          height: bottom.rounded(.down) - top.rounded(.up)).intersection(display)
        guard rect.contains(selection) else {
            return Matching(rect: selection, reason: .clipped, obstacles: obstacles, target: index, ignored: ignored)
        }
        return Matching(rect: rect, reason: obstacles.isEmpty ? .expanded : .clipped, obstacles: obstacles,
                        target: index, ignored: ignored)
    }

    static func output(selection: CGRect, matching: CGRect, scale: CGFloat) -> ScrollingCaptureOutputRect {
        let left = Int(((selection.minX - matching.minX) * scale).rounded())
        let top = Int(((selection.minY - matching.minY) * scale).rounded())
        return ScrollingCaptureOutputRect(columns: left..<(left + Int((selection.width * scale).rounded())),
            rows: top..<(top + Int((selection.height * scale).rounded())))
    }
}

extension ScrollingCaptureRegion {
    /// The windows on screen other than this app's, front to back, in the
    /// display's top-left points; `targets` are the ones a region may snap to.
    static func frontToBackWindows(on displayID: CGDirectDisplayID, targets: Set<CGWindowID>)
        -> [(frame: CGRect, isTarget: Bool)] {
        let displayBounds = CGDisplayBounds(displayID)
        let pid = ProcessInfo.processInfo.processIdentifier
        return (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []).compactMap { info in
                guard let id = info[kCGWindowNumber as String] as? UInt32,
                      info[kCGWindowOwnerPID as String] as? Int32 != pid,
                      (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                      let bounds = info[kCGWindowBounds as String] as? [String: Any],
                      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
                return (frame.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY), targets.contains(id))
            }
    }
}

/// The exported rectangle inside a larger frame, in integer device pixels.
nonisolated struct ScrollingCaptureOutputRect: Sendable {
    let columns: Range<Int>
    let rows: Range<Int>
}
