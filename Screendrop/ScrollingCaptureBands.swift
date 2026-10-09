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

    let selection: ScrollingCaptureOutputRect
    let maximumBufferedBytes: Int
    let maximumOutputRows: Int
    private(set) var bands: [Band] = []
    private(set) var confirmedHeight = 0
    private(set) var lastVerifiedOffset = 0
    private(set) var isLost = false
    private var rows: [Int: [UInt32]] = [:]
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
        if let previous = cache.last, previous.offset != placement.offset {
            for y in contentRows where !placement.frame.isBlank(y)
                && previous.frame.sameRow(y, as: placement.frame, at: y) {
                if let old = rows[placement.offset + y], !sameSelectedRow(old, as: placement.frame, at: y) {
                    return .pinnedOverlay
                }
            }
        }

        var changed = Set(placement.motionRows.map { $0 + placement.offset })
        for y in contentRows {
            let pageY = placement.offset + y
            guard pageY >= start else { continue }
            let row = cropRow(placement.frame, at: y)
            if let old = rows[pageY], !sameSelectedRow(old, as: placement.frame, at: y) { changed.insert(pageY) }
            else if rows[pageY] == nil { rows[pageY] = row }
        }
        cache.append(placement)
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
