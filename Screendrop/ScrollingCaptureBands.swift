import Foundation

/// The exported rectangle inside a larger matching frame, in integer device pixels.
nonisolated struct ScrollingCaptureOutputRect: Sendable {
    let columns: Range<Int>
    let rows: Range<Int>
}

/// Composites registered page rows without mixing moments inside a moving band.
/// Offsets are an input from exact registration, never inferred by the compositor.
nonisolated struct ScrollingCaptureBandCompositor {
    enum Failure: Equatable { case invalidPlacement, pinnedOverlay, noCompleteOwner, outputLimit, missingCoverage }
    struct Event {
        let state: ScrollingCaptureRegistrationBuffer.State
        var failure: Failure?
    }
    struct Owner {
        let index: Int
        let rows: Range<Int>
        let sourcePageRows: Range<Int>
        let pixels: [UInt32]
    }
    struct Band {
        var rows: Range<Int>
        var owner: Owner?
        var locked = false
    }
    /// A fixed rectangle at the selection's edge, such as a floating button,
    /// in frame coordinates. It only marks pixels as unknown: it never helps
    /// place a frame, and its cells come from clean views of the page.
    struct Occlusion: Equatable {
        let rows: Range<Int>
        let columns: Range<Int>
        /// The cells that proved it, with their fixed values; nil elsewhere.
        let fixed: [UInt32?]
    }

    let selection: ScrollingCaptureOutputRect
    let maximumBufferedBytes: Int
    let maximumOutputRows: Int
    private(set) var bands: [Band] = []
    private(set) var confirmedHeight = 0
    private(set) var lastVerifiedOffset = 0
    private(set) var isLost = false
    private(set) var occlusion: Occlusion?
    private var rows: [Int: [UInt32]] = [:]
    /// Stored page rows first seen under the occlusion, waiting for two
    /// agreeing clean views of those cells; and rows seen clean at least once.
    private var occluded: Set<Int> = []
    private var seenClean: Set<Int> = []
    /// The offset of the view each stored page row came from.
    private var sources: [Int: Int] = [:]
    /// A cover that moved, grew or lay over real motion is never trusted again.
    private var occlusionRevoked = false
    /// Distinct verified displacements this session. Until the second, a cover
    /// can't be proved, so a pinned mismatch inside one compact edge rectangle
    /// waits in an unlocked band instead of failing at once; it never re-arms.
    private var displacements = 0
    private var deferred: Set<Int> = []
    private var cache: [ScrollingCapturePlacement] = []
    private let width: Int
    private let height: Int
    private let contentRows: Range<Int>
    private var ownerContentRows: Range<Int>
    private let matchingColumns: [Range<Int>]
    private let padding = 2

    init?(initial: ScrollingCapturePlacement, selection: ScrollingCaptureOutputRect,
          maximumBufferedBytes: Int = 64 * 1024 * 1024, maximumOutputRows: Int = 16_384) {
        guard initial.offset == 0, initial.contentRows.lowerBound >= 0,
              initial.contentRows.upperBound <= initial.frame.height,
              !selection.columns.isEmpty, !selection.rows.isEmpty,
              selection.columns.lowerBound >= 0, selection.columns.upperBound <= initial.frame.width,
              selection.rows.lowerBound >= 0,
              selection.rows.upperBound <= initial.frame.height,
              maximumOutputRows >= selection.rows.count,
              maximumBufferedBytes >= initial.frame.byteCount * 2 else { return nil }
        self.selection = selection
        self.maximumBufferedBytes = maximumBufferedBytes
        self.maximumOutputRows = maximumOutputRows
        width = initial.frame.width
        height = initial.frame.height
        contentRows = initial.contentRows
        ownerContentRows = initial.contentRows
        matchingColumns = initial.frame.matchingColumns
        guard ingest(initial) == nil else { return nil }
    }

    var bufferedBytes: Int {
        cache.reduce(0) { $0 + $1.frame.byteCount }
            + bands.filter { !$0.locked }.reduce(0) { $0 + ($1.owner?.pixels.count ?? 0) * 4 }
    }

    mutating func add(_ placement: ScrollingCapturePlacement) -> Event {
        add([placement])
    }

    mutating func resume() { isLost = false }

    mutating func narrowOwnerSourcingToSelection() {
        let lower = max(contentRows.lowerBound, selection.rows.lowerBound)
        ownerContentRows = lower..<max(lower, min(contentRows.upperBound, selection.rows.upperBound))
    }

    var outputHeight: Int { max(0, lastVerifiedOffset + selection.rows.count) }

    /// Buffered samples resolve together; an earlier sample must not commit past
    /// the selected bottom of the batch's final (possibly scrolled-back) frame.
    mutating func add(_ placements: [ScrollingCapturePlacement]) -> Event {
        guard !isLost else { return Event(state: .lost) }
        guard let final = placements.last else { return Event(state: .pending) }
        let ceiling = final.offset + selection.rows.upperBound
        // A failed placement must leave Done's confirmed prefix and tail intact.
        var proposed = self
        for placement in placements {
            if let failure = proposed.ingest(placement, confirmingThrough: ceiling, validateFinish: false) {
                isLost = true
                return Event(state: .lost, failure: failure)
            }
        }
        guard proposed.finish() != nil else {
            isLost = true
            return Event(state: .lost, failure: .missingCoverage)
        }
        let advanced = proposed.confirmedHeight > confirmedHeight
        self = proposed
        return Event(state: advanced ? .appended : .pending)
    }

    /// Done is available even while pending/lost. The tail is one verified frame.
    func finish() -> ScrollingCaptureRaster? {
        let start = selection.rows.lowerBound
        let end = lastVerifiedOffset + selection.rows.upperBound
        guard end > start, end - start <= maximumOutputRows else { return nil }
        let confirmedEnd = start + confirmedHeight
        let tail = cache.last { $0.offset <= min(confirmedEnd, end) && $0.offset + height >= end }
        guard confirmedEnd >= end || tail != nil else { return nil }
        var output: [UInt32] = []
        output.reserveCapacity((end - start) * selection.columns.count)
        for y in start..<end {
            if y >= lastVerifiedOffset + contentRows.upperBound, let last = cache.last {
                output.append(contentsOf: cropRow(last.frame, at: y - last.offset))
            } else if let band = bands.first(where: { $0.rows.contains(y) }), let owner = band.owner {
                let index = (y - owner.rows.lowerBound) * selection.columns.count
                output.append(contentsOf: owner.pixels[index..<(index + selection.columns.count)])
            } else if y >= confirmedEnd, let tail {
                output.append(contentsOf: cropRow(tail.frame, at: y - tail.offset))
            } else if let row = rows[y] {
                output.append(contentsOf: row)
            } else { return nil }
        }
        return ScrollingCaptureRaster(width: selection.columns.count, height: end - start, pixels: output)
    }

    /// Only confirmed selection pixels are suitable for a recovery target.
    func recoveryRows(_ count: Int) -> ScrollingCaptureRaster? {
        guard count > 0, confirmedHeight > 0, let image = finish() else { return nil }
        let end = min(confirmedHeight, image.height)
        let start = max(0, end - count)
        return ScrollingCaptureRaster(width: image.width, height: end - start,
            pixels: Array(image.pixels[(start * image.width)..<(end * image.width)]))
    }

    private mutating func ingest(_ placement: ScrollingCapturePlacement,
                                 confirmingThrough ceiling: Int? = nil, validateFinish: Bool = true) -> Failure? {
        guard placement.frame.width == width, placement.frame.height == height,
              placement.frame.matchingColumns == matchingColumns,
              placement.contentRows == contentRows,
              placement.motionRows.isSubset(of: Set(contentRows)),
              placement.stableRows.isSubset(of: Set(contentRows)),
              placement.offset.magnitude <= 16_384,
              cache.last.map({ placement.index > $0.index }) ?? true else { return .invalidPlacement }
        let start = selection.rows.lowerBound
        let end = placement.offset + selection.rows.upperBound
        guard end > start,
              end - start <= maximumOutputRows else { return .outputLimit }
        if cache.isEmpty {
            for y in selection.rows where y < contentRows.lowerBound {
                rows[y] = cropRow(placement.frame, at: y)
            }
        }
        if let previous = cache.last, previous.offset != placement.offset { displacements += 1 }
        if let occlusion, !keeps(occlusion, in: placement.frame) || occlusion.rows.contains(where: { y in
            // Change beside the cover in its own rows: it grew, or covers real motion.
            let pageY = placement.offset + y
            guard let old = rows[pageY], let source = sources[pageY] else { return false }
            return !sameStoredOutsideOcclusion(old, pageY - source, placement.frame, y)
        }) {
            // Not a fixed cover over a still page after all. Rows still waiting
            // for clean cells fall back to whole-row comparison.
            self.occlusion = nil
            occluded = []
            occlusionRevoked = true
        }
        if occlusion == nil, !occlusionRevoked, let found = proposeOcclusion(placement) {
            occlusion = found
            occluded = Set(rows.keys.filter { pageY in sources[pageY].map { found.rows.contains(pageY - $0) } ?? false })
            // Bands the cover alone caused go before they lock; real motion stays.
            bands = bands.filter { band in
                band.locked || !band.rows.allSatisfy { pageY in
                    let reference = contentRows.contains(pageY - placement.offset) ? placement
                        : cache.last { contentRows.contains(pageY - $0.offset) }
                    return reference.map { onlyOccluded(pageY, reference: $0) } ?? false
                }
            }
        }
        if occlusion != nil {
            deferred = []
        } else if displacements >= 2, !deferred.isEmpty {
            return .pinnedOverlay
        }
        if let previous = cache.last, previous.offset != placement.offset {
            var held: [(y: Int, columns: Range<Int>)] = []
            for y in contentRows where !placement.frame.isBlank(y)
                && previous.frame.sameRow(y, as: placement.frame, at: y) {
                if let old = rows[placement.offset + y], !sameSelectedRow(old, as: placement.frame, at: y),
                   !onlyOccluded(placement.offset + y, reference: placement) {
                    guard occlusion == nil, !occlusionRevoked, displacements < 2,
                          let columns = edgeMismatch(old, placement.frame, y) else { return .pinnedOverlay }
                    held.append((y, columns))
                }
            }
            // Held rows ascend; together they must still be one compact edge rectangle.
            if !held.isEmpty, let edges {
                let columns = held.map(\.columns.lowerBound).min()!..<held.map(\.columns.upperBound).max()!
                guard columns.lowerBound == edges.lower || columns.upperBound == edges.upper, columns.count <= edges.reach,
                      held.last!.y - held[0].y < contentRows.count / 4 else { return .pinnedOverlay }
                deferred.formUnion(held.map { placement.offset + $0.y })
            }
        }

        var changed = Set(placement.motionRows.map { $0 + placement.offset }
            .filter { !onlyOccluded($0, reference: placement) })
        for y in contentRows {
            let pageY = placement.offset + y
            guard pageY >= start else { continue }
            let row = cropRow(placement.frame, at: y)
            if let old = rows[pageY], !sameSelectedRow(old, as: placement.frame, at: y) {
                if !onlyOccluded(pageY, reference: placement) { changed.insert(pageY) }
            } else if rows[pageY] == nil {
                rows[pageY] = row
                sources[pageY] = placement.offset
                if occlusion?.rows.contains(y) == true { occluded.insert(pageY) }
            }
        }
        cache.append(placement)
        if let failure = resolveOccluded(above: placement.pageRows.lowerBound) { return failure }
        let locked = bands.filter(\.locked)
        changed = changed.filter { pageY in pageY >= start && !locked.contains { $0.rows.contains(pageY) } }
        // Late controls may belong to an already locked video. Observed motion
        // bounds cannot prove they are a separate object with a separate owner.
        if changed.contains(where: { y in locked.contains { $0.owner?.sourcePageRows.contains(y) == true } }) {
            return .noCompleteOwner
        }
        var active = bands.filter { !$0.locked }.map(\.rows)
        for run in runs(changed) {
            let lower = max(start, run.lowerBound - padding)
            let upper = run.upperBound + padding
            guard lower < upper else { continue }
            let range = lower..<upper
            if locked.contains(where: { $0.rows.overlaps(range) }) { return .noCompleteOwner }
            active.append(range)
        }
        active.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in active {
            if let previous = merged.last {
                let union = previous.lowerBound..<max(previous.upperBound, range.upperBound)
                // A complete owner, not a guessed semantic object boundary, permits merging.
                if cache.contains(where: { contains(ownerRows($0), union) }) || previous.overlaps(range) {
                    merged[merged.count - 1] = union
                    continue
                }
                // Concurrent changes cannot be split into different video moments safely.
                return .noCompleteOwner
            }
            merged.append(range)
        }
        var nextBands = locked
        for range in merged {
            // Before any advance, Done can always save the selected initial frame,
            // even when moving content reaches both edges and has no whole owner.
            guard range.count <= ownerContentRows.count || cache.count == 1 else { return .noCompleteOwner }
            let previousOwner = bands.first { contains($0.rows, range) }?.owner
            var owner = previousOwner
            if let source = cache.last(where: { contains(ownerRows($0), range) }) {
                owner = Owner(index: source.index, rows: range, sourcePageRows: ownerRows(source),
                    pixels: range.flatMap { cropRow(source.frame, at: $0 - source.offset) })
            }
            let leaving = range.lowerBound < ownerRows(placement).lowerBound
            guard !leaving || owner != nil else { return .noCompleteOwner }
            // A band holding a deferred mismatch must stay open until the cover is proved.
            if deferred.contains(where: range.contains), leaving || locked.contains(where: { band in
                touches(band.rows, range) || band.owner.map { touches($0.sourcePageRows, range) } == true
            }) { return .pinnedOverlay }
            nextBands.append(Band(rows: range, owner: owner, locked: leaving))
        }
        bands = nextBands.sorted { $0.rows.lowerBound < $1.rows.lowerBound }
        while cache.count > 1, bufferedBytes > maximumBufferedBytes { cache.removeFirst() }
        guard bufferedBytes <= maximumBufferedBytes else { return .noCompleteOwner }
        var boundary = min(end, placement.pageRows.lowerBound)
        if let ceiling { boundary = min(boundary, ceiling) }
        for band in bands where !band.locked { boundary = min(boundary, band.rows.lowerBound) }
        confirmedHeight = max(confirmedHeight, boundary - start)
        lastVerifiedOffset = placement.offset
        guard !validateFinish || finish() != nil else { return .missingCoverage }
        return nil
    }

    /// Three views at two distinct verified displacements: edge cells that
    /// keep their screen position and value while the page registered at
    /// their position disagrees in at least four of the six ordered pairs of
    /// views (a cell's page position can itself be covered in another view).
    /// A plain background cell beside the cover disagrees only in the pairs
    /// that look toward it, at most three. One compact region touching an
    /// edge of the matched columns; anything else stays unsupported.
    private func proposeOcclusion(_ placement: ScrollingCapturePlacement) -> Occlusion? {
        guard let middle = cache.last, middle.offset != placement.offset,
              let oldest = cache.last(where: { $0.offset != middle.offset && $0.offset != placement.offset }),
              let (lower, upper, reach) = self.edges else { return nil }
        let edges = Set(lower..<min(upper, lower + reach)).union(max(lower, upper - reach)..<upper)
            .filter { x in matchingColumns.contains { $0.contains(x) } }
        let views = [oldest, middle, placement]
        var cells: [Int: UInt32] = [:]
        for y in contentRows {
            for x in edges {
                let value = placement.frame.pixels[y * width + x]
                guard oldest.frame.pixels[y * width + x] == value, middle.frame.pixels[y * width + x] == value else { continue }
                // This runs on every buffered frame without a cover: no allocation, stop at four.
                var disagreements = 0
                pairs: for view in views {
                    for other in views where other.index != view.index {
                        let otherY = view.offset + y - other.offset
                        if contentRows.contains(otherY), other.frame.pixels[otherY * width + x] != value {
                            disagreements += 1
                            if disagreements == 4 { break pairs }
                        }
                    }
                }
                if disagreements == 4 { cells[y * width + x] = value }
            }
        }
        guard cells.count >= 16 else { return nil }
        let ys = cells.keys.map { $0 / width }, xs = cells.keys.map { $0 % width }
        let rows = ys.min()!..<(ys.max()! + 1), columns = xs.min()!..<(xs.max()! + 1)
        guard columns.lowerBound == lower || columns.upperBound == upper, columns.count <= reach,
              rows.count <= contentRows.count / 4, cells.count * 2 >= rows.count * columns.count else { return nil }
        return Occlusion(rows: rows, columns: columns,
            fixed: rows.flatMap { y in columns.map { cells[y * width + $0] } })
    }
    /// The matched columns' outer bounds, and how far in from either a cover may reach.
    private var edges: (lower: Int, upper: Int, reach: Int)? {
        guard let lower = matchingColumns.first.map({ max($0.lowerBound, selection.columns.lowerBound) }),
              let upper = matchingColumns.last.map({ min($0.upperBound, selection.columns.upperBound) }),
              lower < upper else { return nil }
        return (lower, upper, max(1, (upper - lower) / 8))
    }
    /// The columns where a stored row differs from this view, when they all
    /// lie within a cover's reach of one edge.
    private func edgeMismatch(_ old: [UInt32], _ frame: ScrollingCaptureRaster, _ y: Int) -> Range<Int>? {
        guard let edges else { return nil }
        var first = Int.max, last = Int.min
        for columns in matchingColumns {
            for x in max(columns.lowerBound, selection.columns.lowerBound)..<min(columns.upperBound, selection.columns.upperBound)
                where old[x - selection.columns.lowerBound] != frame.pixels[y * width + x] {
                first = min(first, x); last = max(last, x)
            }
        }
        guard first <= last, last < edges.lower + edges.reach || first >= edges.upper - edges.reach else { return nil }
        return first..<(last + 1)
    }
    private func touches(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        a.lowerBound <= b.upperBound && b.lowerBound <= a.upperBound
    }
    private func keeps(_ occlusion: Occlusion, in frame: ScrollingCaptureRaster) -> Bool {
        var index = 0
        for y in occlusion.rows { for x in occlusion.columns {
            if let value = occlusion.fixed[index], frame.pixels[y * width + x] != value { return false }
            index += 1
        } }
        return true
    }
    /// Two views of one page row agree, leaving out the occlusion's columns
    /// wherever either view has them covered.
    private func sameOutsideOcclusion(_ a: ScrollingCaptureRaster, _ ya: Int, _ b: ScrollingCaptureRaster, _ yb: Int) -> Bool {
        let skip = occlusion.flatMap { $0.rows.contains(ya) || $0.rows.contains(yb) ? $0.columns : nil }
        return matchingColumns.allSatisfy { columns in
            let lower = max(columns.lowerBound, selection.columns.lowerBound)
            let upper = min(columns.upperBound, selection.columns.upperBound)
            return lower >= upper || (lower..<upper).allSatisfy { x in
                skip?.contains(x) == true || a.pixels[ya * width + x] == b.pixels[yb * width + x]
            }
        }
    }
    private func sameStoredOutsideOcclusion(_ old: [UInt32], _ oldY: Int, _ frame: ScrollingCaptureRaster, _ y: Int) -> Bool {
        let skip = occlusion.flatMap { $0.rows.contains(oldY) || $0.rows.contains(y) ? $0.columns : nil }
        return matchingColumns.allSatisfy { columns in
            let lower = max(columns.lowerBound, selection.columns.lowerBound)
            let upper = min(columns.upperBound, selection.columns.upperBound)
            return lower >= upper || (lower..<upper).allSatisfy { x in
                skip?.contains(x) == true || old[x - selection.columns.lowerBound] == frame.pixels[y * width + x]
            }
        }
    }
    /// The occlusion alone explains any difference in this page row: the
    /// stored row and every cached view agree with this one outside the cover,
    /// which is only left out where a view has the row covered.
    private func onlyOccluded(_ pageY: Int, reference: ScrollingCapturePlacement) -> Bool {
        let y = pageY - reference.offset
        guard occlusion != nil, contentRows.contains(y) else { return false }
        let views = cache.filter { $0.index != reference.index && contentRows.contains(pageY - $0.offset) }
        let stored = rows[pageY].map { old in
            sources[pageY].map { sameStoredOutsideOcclusion(old, pageY - $0, reference.frame, y) } ?? false
        } ?? true
        return !views.isEmpty && stored
            && views.allSatisfy { sameOutsideOcclusion($0.frame, pageY - $0.offset, reference.frame, y) }
    }
    /// Stored rows first seen covered take the occlusion's cells from two clean
    /// views at different offsets that agree byte for byte. Real bands keep
    /// their owner. A row that leaves the view unresolved after being seen
    /// clean is a hole; one only ever seen covered keeps its single view.
    private mutating func resolveOccluded(above top: Int) -> Failure? {
        guard let occlusion else { return nil }
        let lower = max(occlusion.columns.lowerBound, selection.columns.lowerBound)
        let upper = min(occlusion.columns.upperBound, selection.columns.upperBound)
        for pageY in occluded.sorted() where !bands.contains(where: { $0.rows.contains(pageY) }) {
            let clean = cache.filter { contentRows.contains(pageY - $0.offset) && !occlusion.rows.contains(pageY - $0.offset) }
            if !clean.isEmpty { seenClean.insert(pageY) }
            let slices = clean.map { view in (lower..<upper).map { view.frame.pixels[(pageY - view.offset) * width + $0] } }
            if Set(clean.map(\.offset)).count >= 2, slices.allSatisfy({ $0 == slices[0] }), lower < upper,
               var row = rows[pageY] {
                row.replaceSubrange((lower - selection.columns.lowerBound)..<(upper - selection.columns.lowerBound),
                                    with: slices[0])
                rows[pageY] = row
                occluded.remove(pageY)
            } else if pageY < top {
                guard !seenClean.contains(pageY) else { return .missingCoverage }
                occluded.remove(pageY)
            }
        }
        return nil
    }

    private func contains(_ outer: Range<Int>, _ inner: Range<Int>) -> Bool {
        outer.lowerBound <= inner.lowerBound && outer.upperBound >= inner.upperBound
    }
    private func ownerRows(_ placement: ScrollingCapturePlacement) -> Range<Int> {
        (placement.offset + ownerContentRows.lowerBound)..<(placement.offset + ownerContentRows.upperBound)
    }
    private func cropRow(_ frame: ScrollingCaptureRaster, at y: Int) -> [UInt32] {
        let start = y * width
        return Array(frame.pixels[(start + selection.columns.lowerBound)..<(start + selection.columns.upperBound)])
    }
    private func sameSelectedRow(_ old: [UInt32], as frame: ScrollingCaptureRaster, at y: Int) -> Bool {
        matchingColumns.allSatisfy { columns in
            let lower = max(columns.lowerBound, selection.columns.lowerBound)
            let upper = min(columns.upperBound, selection.columns.upperBound)
            guard lower < upper else { return true }
            return old[(lower - selection.columns.lowerBound)..<(upper - selection.columns.lowerBound)]
                .elementsEqual(frame.pixels[(y * width + lower)..<(y * width + upper)])
        }
    }
    private func runs(_ values: Set<Int>) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for value in values.sorted() {
            if let last = result.last, last.upperBound == value {
                result[result.count - 1] = last.lowerBound..<(value + 1)
            } else { result.append(value..<(value + 1)) }
        }
        return result
    }
}
