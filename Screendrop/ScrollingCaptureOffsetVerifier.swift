import Foundation

/// Confirms a candidate offset with exact pixels, cut down from R7: rows of the
/// new frame are compared byte for byte with the last frame's rows `offset`
/// lower (`new[y] == last[y + offset]`), strip by strip. Frames are tightly
/// packed BGRA, both the same size.
nonisolated enum ScrollingCaptureOffsetVerifier {
    /// Side-by-side strips per row, so a narrow column that changes (a hover,
    /// a gutter line) costs one strip of a row rather than the whole row.
    static let strips = 8
    /// Share of compared strips that must be identical at the offset. Low, so
    /// a hover, overlay or video over part of the frame doesn't refuse it: the
    /// distinct exact rows and the refusal of ties keep it from guessing
    /// (corpus sweep 0.7 to 0.3: correct 355 to 390, wrong 0 throughout).
    // ponytail: video, a hover over most of the frame and inner scrollers still
    // refuse; step 5's "scroll back a little" hint covers them, not more rules.
    static let agreement = 0.3
    /// Fewer distinct fully matching rows than this is a coincidence.
    static let minimumMatchedRows = 8
    /// The candidate can be this far off; every offset within it is tried.
    static let search = 2
    /// The bottom quarter of the band is held back rather than appended, so a
    /// floating button or chat bubble that sits there - covering the content
    /// scrolling under it - isn't copied into every slice. That content is
    /// taken from higher up the frame once it has scrolled clear, and the held
    /// rows are added once, from the last frame, at the end. Verifying leaves
    /// it out for the same reason.
    static let heldBackFraction = 4

    struct Verified: Equatable, Sendable {
        let offset: Int
        /// Strips identical at offset zero across the band, a non-blank row
        /// among them: a pinned sidebar while the page moves.
        let stillColumns: [Range<Int>]
    }

    /// The passing offset within `search` of `candidate` with the most
    /// distinct matching rows; nil when none passes, or when two tie: content
    /// that lines up equally well at two offsets doesn't say which it is.
    static func verifiedOffset(candidate: Int, from last: [UInt8], to new: [UInt8], width: Int, height: Int,
                               ignoredTrailingColumns: Int) -> Verified? {
        guard last.count == width * height * 4, new.count == last.count else { return nil }
        let usable = hashedWidth(width: width, ignoredTrailingColumns: ignoredTrailingColumns)
        let columns = (0..<strips).map { ($0 * usable / strips)..<(($0 + 1) * usable / strips) }.filter { !$0.isEmpty }
        return last.withUnsafeBytes { old in new.withUnsafeBytes { now in
            func same(_ y: Int, _ oldY: Int, _ x: Range<Int>) -> Bool {
                memcmp(now.baseAddress! + (y * width + x.lowerBound) * 4,
                       old.baseAddress! + (oldY * width + x.lowerBound) * 4, x.count * 4) == 0
            }
            func blank(_ y: Int, _ x: Range<Int>) -> Bool {
                let start = now.baseAddress! + (y * width + x.lowerBound) * 4
                return memcmp(start, start + 4, (x.count - 1) * 4) == 0
            }
            let edges = unmovedEdges(height: height) { same($0, $0, 0..<usable) }
            let band = edges.top..<(height - edges.bottom)
            let committed = band.lowerBound..<cut(in: band)
            func score(_ k: Int) -> Int? {
                var compared = 0, agreed = 0
                var matched = Set<Int>()
                for y in committed where committed.contains(y + k) {
                    var whole = true, isBlank = true
                    for x in columns where !blank(y, x) {
                        isBlank = false
                        compared += 1
                        if same(y, y + k, x) { agreed += 1 } else { whole = false }
                    }
                    if whole && !isBlank {
                        var hasher = Hasher()
                        hasher.combine(bytes: UnsafeRawBufferPointer(start: now.baseAddress! + y * width * 4, count: usable * 4))
                        matched.insert(hasher.finalize())
                    }
                }
                guard compared > 0, matched.count >= minimumMatchedRows else { return nil }
                return Double(agreed) / Double(compared) >= agreement ? matched.count : nil
            }
            let passed = ((candidate - search)...(candidate + search)).compactMap { k in score(k).map { (k, $0) } }
                .sorted { $0.1 > $1.1 }
            guard let best = passed.first, passed.dropFirst().first?.1 != best.1 else { return nil }
            let still = columns.filter { x in
                band.allSatisfy { same($0, $0, x) } && band.contains { !blank($0, x) }
            }
            return Verified(offset: best.0, stillColumns: still)
        } }
    }

    // MARK: - Shared with R7

    /// Leading columns that are compared. The trailing ones are left out so
    /// the overlay scroll bar that appears while scrolling doesn't break
    /// otherwise identical rows.
    static func hashedWidth(width: Int, ignoredTrailingColumns: Int) -> Int {
        max(1, width - min(max(ignoredTrailingColumns, 0), width / 4))
    }

    /// Runs of rows at the top and bottom that are identical in both frames: a
    /// sticky header and footer. Capped at a third of the frame each, so a
    /// mostly blank page can't shrink the band that scrolling is matched in.
    /// Overcounting is harmless: the content passing through those rows is
    /// still kept, just later.
    static func unmovedEdges(height: Int, isUnmoved: (Int) -> Bool) -> (top: Int, bottom: Int) {
        let limit = height / 3
        var top = 0
        while top < limit, isUnmoved(top) { top += 1 }
        var bottom = 0
        while bottom < limit, isUnmoved(height - 1 - bottom) { bottom += 1 }
        return (top, bottom)
    }

    /// The row the band is appended up to; the rows below it are held back.
    static func cut(in band: Range<Int>) -> Int {
        band.upperBound - band.count / heldBackFraction
    }
}
