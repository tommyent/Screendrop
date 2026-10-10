import Foundation

/// In-memory, top-to-bottom BGRA pixels. No capture, image decoding or UI side effects.
nonisolated struct ScrollingCaptureRaster: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt32]
    let matchingColumns: [Range<Int>]
    private let rowHashes: [Int]
    private let blankRows: [Bool]

    init?(width: Int, height: Int, pixels: [UInt32], matchingColumns: [Range<Int>]? = nil) {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= Int.max / height, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
        let columns = matchingColumns ?? [0..<width]
        guard !columns.isEmpty, columns.allSatisfy({ !$0.isEmpty && $0.lowerBound >= 0 && $0.upperBound <= width }),
              zip(columns, columns.dropFirst()).allSatisfy({ $0.upperBound <= $1.lowerBound }) else { return nil }
        self.matchingColumns = columns
        var hashes: [Int] = []
        var blanks: [Bool] = []
        for y in 0..<height {
            let row = columns.flatMap { pixels[(y * width + $0.lowerBound)..<(y * width + $0.upperBound)] }
            var hasher = Hasher()
            for pixel in row { hasher.combine(pixel) }
            hashes.append(hasher.finalize())
            blanks.append(row.allSatisfy { $0 == row.first })
        }
        rowHashes = hashes
        blankRows = blanks
    }

    var byteCount: Int {
        pixels.count * 4 + rowHashes.count * MemoryLayout<Int>.stride + blankRows.count
            + matchingColumns.count * MemoryLayout<Range<Int>>.stride
    }
    func row(_ y: Int) -> ArraySlice<UInt32> { pixels[(y * width)..<((y + 1) * width)] }
    func sameRow(_ y: Int, as other: Self, at otherY: Int) -> Bool {
        matchingColumns == other.matchingColumns && rowHashes[y] == other.rowHashes[otherY]
            && matchingColumns.allSatisfy { columns in
                pixels[(y * width + columns.lowerBound)..<(y * width + columns.upperBound)]
                    .elementsEqual(other.pixels[(otherY * width + columns.lowerBound)..<(otherY * width + columns.upperBound)])
            }
    }
    func rowHash(_ y: Int) -> Int {
        rowHashes[y]
    }
    func isBlank(_ y: Int) -> Bool { blankRows[y] }
    func using(columns: [Range<Int>]) -> Self? {
        Self(width: width, height: height, pixels: pixels, matchingColumns: columns)
    }
}

/// A sample's page placement, established only by exact overlap with registered samples.
nonisolated struct ScrollingCapturePlacement: Sendable {
    let index: Int
    let offset: Int
    let frame: ScrollingCaptureRaster
    let stableRows: Set<Int>
    let motionRows: Set<Int>
    let contentRows: Range<Int>
    var corroboratingRows: Set<Int> = []
    var pageRows: Range<Int> { (offset + contentRows.lowerBound)..<(offset + contentRows.upperBound) }
}

/// Phase-one registration proof. Whole rows are deliberately stricter than R7's strips.
/// The caller supplies the scroll viewport inside the larger sample; window bounds alone
/// do not establish it. Chrome outside that viewport never supplies evidence.
nonisolated struct ScrollingCaptureRegistrationBuffer {
    enum State: Equatable { case pending, appended, lost }
    enum Failure: Equatable { case invalidSample, bufferExhausted, motionTimeout, noOverlap }
    enum PendingReason: Equatable { case motion, noOverlap }
    struct Event {
        let state: State
        var placements: [ScrollingCapturePlacement] = []
        var failure: Failure?
        var pendingReason: PendingReason?
    }
    private struct Sample {
        let index: Int
        let frame: ScrollingCaptureRaster
        let stable: Set<Int>
        let motion: Set<Int>
        let time: TimeInterval
    }
    private enum Match { case absent, ambiguous, offset(Int) }

    let initial: ScrollingCapturePlacement
    let maximumBufferedBytes: Int
    let maximumPendingTime: TimeInterval
    private(set) var frontier = 0
    private(set) var lastVerifiedOffset = 0
    private(set) var isLost = false
    private var keys: [ScrollingCapturePlacement]
    private var unresolved: [Sample] = []
    private var previous: ScrollingCaptureRaster
    private var lastIndex = 0
    private var lastWitness: ScrollingCapturePlacement?
    private var movingPageRows: Set<Int>
    private var everMovingPageRows: Set<Int>
    private var settledObservations: [Int: Int] = [:]
    private var pageWitnessRows: Set<Int>?
    private var noOverlapSince: Int?
    private let contentRows: Range<Int>
    private let minimumRows = 8
    private var lastTime: TimeInterval = -.infinity
    private(set) var direction: Int

    init?(first: ScrollingCaptureRaster, confirmation: ScrollingCaptureRaster,
          contentRows: Range<Int>, maximumBufferedBytes: Int = 128 * 1024 * 1024,
          observedMotionRows: Set<Int> = [], pageWitnessRows: Set<Int>? = nil,
          maximumPendingTime: TimeInterval = 2, direction: Int = 0) {
        guard first.width == confirmation.width, first.height == confirmation.height,
              first.matchingColumns == confirmation.matchingColumns,
              contentRows.lowerBound >= 0, contentRows.upperBound <= first.height,
              contentRows.count >= 16, maximumBufferedBytes / first.byteCount >= 4,
              maximumPendingTime.isFinite, maximumPendingTime > 0 else { return nil }
        let stable = Set(contentRows.filter { first.sameRow($0, as: confirmation, at: $0) }).subtracting(observedMotionRows)
        let motion = Set(contentRows).subtracting(stable)
        initial = ScrollingCapturePlacement(index: 0, offset: 0, frame: confirmation,
            stableRows: stable, motionRows: motion, contentRows: contentRows)
        keys = [initial]
        previous = confirmation
        self.contentRows = contentRows
        self.maximumBufferedBytes = maximumBufferedBytes
        movingPageRows = motion
        everMovingPageRows = motion
        self.pageWitnessRows = pageWitnessRows
        self.maximumPendingTime = maximumPendingTime
        self.direction = direction.signum()
    }

    // Count conservatively: two working frames plus every queued/registered frame.
    var bufferedBytes: Int {
        var retained = Set(keys.map(\.index) + unresolved.map(\.index) + [initial.index])
        if let lastWitness { retained.insert(lastWitness.index) }
        return (retained.count + 2) * initial.frame.byteCount
    }
    var pendingCount: Int { unresolved.count }
    var settledPageRows: Set<Int> { everMovingPageRows.subtracting(movingPageRows) }

    mutating func add(_ frame: ScrollingCaptureRaster, at index: Int, time: TimeInterval? = nil) -> Event {
        let time = time ?? Double(index) * 0.05
        guard !isLost else { return Event(state: .lost) }
        guard index > lastIndex, time.isFinite, time >= lastTime, frame.width == initial.frame.width,
              frame.height == initial.frame.height,
              frame.matchingColumns == initial.frame.matchingColumns else { return lose(.invalidSample) }
        lastIndex = index
        lastTime = time
        let stable = Set(contentRows.filter { previous.sameRow($0, as: frame, at: $0) })
        let sample = Sample(index: index, frame: frame, stable: stable,
                            motion: Set(contentRows).subtracting(stable), time: time)
        previous = frame
        var match = locate(sample)
        var movingPlacement = false
        if case .absent = match, let displaced = movingOffset(sample) {
            match = .offset(displaced)
            movingPlacement = true
        }
        switch match {
        case .offset(let offset):
            noOverlapSince = nil
            guard offset.magnitude <= 16_384 else { return lose(.invalidSample) }
            // A fresh zero subset is never page-position authority. Keep the baseline.
            if offset == lastVerifiedOffset {
                guard let witness = lastWitness,
                      hasPageWitness(witness),
                      witness.stableRows.allSatisfy({ witness.frame.sameRow($0, as: frame, at: $0) }),
                      !hasMovingChanges(from: witness.frame, to: frame) else {
                    return Event(state: .pending)
                }
            }
            let placement = placed(sample, at: offset)
            var resolved = [placement]
            movingPageRows.formUnion(placement.motionRows.map { $0 + offset })
            everMovingPageRows.formUnion(placement.motionRows.map { $0 + offset })
            observeSettledRows(placement)
            if pageWitnessRows != nil {
                pageWitnessRows!.formUnion(placement.stableRows.map { $0 + offset })
            }
            keys.append(placement)
            for waiting in unresolved where time - waiting.time < maximumPendingTime {
                var match = locate(waiting, requiringDisplacement: true)
                if case .absent = match, let position = movingOffset(waiting), position != lastVerifiedOffset {
                    match = .offset(position)
                }
                if case .offset(let position) = match {
                    resolved.append(placed(waiting, at: position))
                }
            }
            // Unplaceable earlier frames cannot be replayed behind a committed cut.
            unresolved.removeAll()
            let highest = resolved.map(\.offset).max() ?? offset
            let advanced = highest > frontier
            if offset != lastVerifiedOffset, hasPageWitness(placement) {
                lastWitness = ScrollingCapturePlacement(index: placement.index, offset: offset, frame: frame,
                    stableRows: placement.stableRows.filter { !everMovingPageRows.contains(offset + $0) },
                    motionRows: placement.motionRows, contentRows: contentRows)
            }
            frontier = max(frontier, highest)
            if offset != lastVerifiedOffset {
                let next = (offset - lastVerifiedOffset).signum()
                direction = !movingPlacement && direction != 0 && next != direction ? 0 : next
            }
            lastVerifiedOffset = offset
            trimKeys()
            return Event(state: advanced ? .appended : .pending,
                         placements: resolved.sorted { $0.index < $1.index })
        case .absent, .ambiguous:
            if let first = unresolved.first, time - first.time >= maximumPendingTime { return lose(.motionTimeout) }
            let votes = keys.flatMap { votes($0, sample).values }
            if stable.filter({ !frame.isBlank($0) }).count >= minimumRows, votes.isEmpty {
                noOverlapSince = noOverlapSince ?? index
                if index - noOverlapSince! >= 20 { return lose(.noOverlap) }
                return Event(state: .pending, pendingReason: .noOverlap)
            }
            noOverlapSince = nil
            // A stationary page with hover/video changes is not a scrolling gap.
            let stationary = lastWitness.map { witness in
                hasPageWitness(witness) && witness.stableRows.allSatisfy { witness.frame.sameRow($0, as: frame, at: $0) }
                    && !hasMovingChanges(from: witness.frame, to: frame)
            } ?? false
            guard !stationary, hasNonzeroEvidence(sample) || frontier > 0 else {
                return Event(state: .pending, pendingReason: .motion)
            }
            unresolved.append(sample)
            trimKeys()
            if bufferedBytes > maximumBufferedBytes { return lose(.bufferExhausted) }
            if time - unresolved[0].time >= maximumPendingTime { return lose(.motionTimeout) }
            return Event(state: .pending, pendingReason: .motion)
        }
    }

    /// Recovery drops unresolved samples; they must not reappear after Continue.
    mutating func discardUnresolved() { unresolved.removeAll(); isLost = false; noOverlapSince = nil; direction = 0 }
    mutating func clearDirection() { direction = 0 }

    private mutating func trimKeys() {
        while keys.count > 1, bufferedBytes > maximumBufferedBytes { keys.removeFirst() }
    }
    private mutating func lose(_ failure: Failure) -> Event {
        unresolved.removeAll()
        isLost = true
        direction = 0
        return Event(state: .lost, failure: failure)
    }
    private func placed(_ sample: Sample, at offset: Int) -> ScrollingCapturePlacement {
        if pageWitnessRows != nil {
            var stable = Set<Int>(), motion = Set<Int>(), corroborating = Set<Int>()
            for y in contentRows {
                let pageY = offset + y
                if everMovingPageRows.contains(pageY) {
                    if !movingPageRows.contains(pageY), let last = keys.last,
                       contentRows.contains(pageY - last.offset),
                       last.frame.sameRow(pageY - last.offset, as: sample.frame, at: y) {
                        corroborating.insert(y)
                    } else { motion.insert(y) }
                    continue
                }
                for key in keys {
                    let oldY = pageY - key.offset
                    guard contentRows.contains(oldY) else { continue }
                    if !key.frame.sameRow(oldY, as: sample.frame, at: y) { motion.insert(y) }
                    else if pageWitnessRows!.contains(pageY)
                        || (offset != key.offset && !key.frame.sameRow(y, as: sample.frame, at: y)) {
                        stable.insert(y)
                    }
                }
            }
            // Unseen incoming rows stay provisional; scrolling itself is not animation.
            return ScrollingCapturePlacement(index: sample.index, offset: offset, frame: sample.frame,
                stableRows: stable.subtracting(motion), motionRows: motion, contentRows: contentRows,
                corroboratingRows: corroborating)
        }
        return ScrollingCapturePlacement(index: sample.index, offset: offset, frame: sample.frame,
            stableRows: sample.stable.filter { !everMovingPageRows.contains(offset + $0) },
            motionRows: sample.motion, contentRows: contentRows)
    }

    private mutating func observeSettledRows(_ placement: ScrollingCapturePlacement) {
        guard let last = keys.last else { return }
        var observations: [Int: Int] = [:]
        for y in contentRows where everMovingPageRows.contains(placement.offset + y) {
            let pageY = placement.offset + y, oldY = pageY - last.offset
            let same = contentRows.contains(oldY) && last.frame.sameRow(oldY, as: placement.frame, at: y)
            let count = same ? (settledObservations[pageY] ?? 1) + 1 : 1
            observations[pageY] = count
            if count >= 3 { movingPageRows.remove(pageY) } else { movingPageRows.insert(pageY) }
        }
        settledObservations = observations
    }
    /// Positive registration uses previously proven page rows even while the view moves.
    private func movingOffset(_ sample: Sample) -> Int? {
        guard let pageWitnessRows else { return nil }
        var offsets: [Int: Set<Int>] = [:]
        for key in keys {
            var oldRows: [Int: [Int]] = [:]
            for y in key.stableRows where pageWitnessRows.contains(key.offset + y)
                && !everMovingPageRows.contains(key.offset + y) && !key.frame.isBlank(y) {
                oldRows[key.frame.rowHash(y), default: []].append(y)
            }
            for y in contentRows where !sample.frame.isBlank(y) {
                for oldY in oldRows[sample.frame.rowHash(y), default: []]
                    where key.frame.sameRow(oldY, as: sample.frame, at: y) {
                    offsets[key.offset + oldY - y, default: []].insert(sample.frame.rowHash(y))
                }
            }
        }
        let candidates = offsets.filter { $0.value.count >= minimumRows }
        let forward = candidates.filter {
            direction == 0 || ($0.key - lastVerifiedOffset).signum() == direction || $0.key == lastVerifiedOffset
        }
        guard forward.count == 1, let candidate = forward.first else { return nil }
        let offset = candidate.key
        // Prior travel is only a hint: repeated rows need a clear margin over reverse evidence.
        guard !candidates.contains(where: { $0.key != offset && $0.value.count * 2 > candidate.value.count }),
              corroborates(offset, sample) else { return nil }
        if offset == lastVerifiedOffset {
            guard let witness = lastWitness, hasPageWitness(witness),
                  witness.stableRows.allSatisfy({ witness.frame.sameRow($0, as: sample.frame, at: $0) }),
                  !hasMovingChanges(from: witness.frame, to: sample.frame) else { return nil }
            return offset
        }
        if let witness = lastWitness, hasPageWitness(witness),
           witness.stableRows.allSatisfy({ witness.frame.sameRow($0, as: sample.frame, at: $0) }) { return nil }
        return offset
    }
    private func locate(_ sample: Sample, requiringDisplacement: Bool = false) -> Match {
        var offsets = Set<Int>()
        var hasDisplacement = false
        for key in keys {
            switch match(key, sample) {
            case .absent: continue
            case .ambiguous: return .ambiguous
            case .offset(let offset):
                offsets.insert(offset)
                hasDisplacement = hasDisplacement || offset != key.offset
            }
        }
        guard offsets.count == 1, let offset = offsets.first else {
            return offsets.isEmpty ? .absent : .ambiguous
        }
        guard !requiringDisplacement || hasDisplacement else { return .absent }
        // A stationary whole historical witness vetoes displacement from a new subset.
        if offset != lastVerifiedOffset, let witness = lastWitness, hasPageWitness(witness),
           witness.stableRows.allSatisfy({ witness.frame.sameRow($0, as: sample.frame, at: $0) }) {
            return .ambiguous
        }
        return corroborates(offset, sample) ? .offset(offset) : .ambiguous
    }
    private func votes(_ key: ScrollingCapturePlacement, _ sample: Sample) -> [Int: Set<Int>] {
        var oldRows: [Int: [Int]] = [:]
        for y in key.stableRows where !key.frame.isBlank(y) && !everMovingPageRows.contains(key.offset + y) {
            oldRows[key.frame.rowHash(y), default: []].append(y)
        }
        var shifts: [Int: Set<Int>] = [:]
        for y in sample.stable where !sample.frame.isBlank(y) {
            let hash = sample.frame.rowHash(y)
            for oldY in oldRows[hash, default: []] where key.frame.sameRow(oldY, as: sample.frame, at: y) {
                guard !everMovingPageRows.contains(key.offset + oldY) else { continue }
                shifts[oldY - y, default: []].insert(hash)
            }
        }
        return shifts
    }
    private func match(_ key: ScrollingCapturePlacement, _ sample: Sample) -> Match {
        let candidates = votes(key, sample).filter { $0.value.count >= minimumRows }.keys
        // Any second plausible displacement (including pinned zero) vetoes the pair.
        guard candidates.count == 1, let shift = candidates.first else {
            return candidates.isEmpty ? .absent : .ambiguous
        }
        for y in sample.stable where contentRows.contains(y + shift) && key.stableRows.contains(y + shift) {
            guard key.frame.sameRow(y + shift, as: sample.frame, at: y) else { return .absent }
        }
        return .offset(key.offset + shift)
    }
    private func hasNonzeroEvidence(_ sample: Sample) -> Bool {
        keys.contains { key in votes(key, sample).contains { $0.key != 0 && !$0.value.isEmpty } }
    }
    private func hasPageWitness(_ placement: ScrollingCapturePlacement) -> Bool {
        Set(placement.stableRows.filter { !everMovingPageRows.contains(placement.offset + $0) && !placement.frame.isBlank($0) }
            .map { placement.frame.rowHash($0) }).count >= minimumRows
    }

    /// Settled media can veto conflicting evidence, never create a position or an idle witness.
    private func corroborates(_ offset: Int, _ sample: Sample) -> Bool {
        let settled = settledPageRows
        guard !settled.isEmpty else { return true }
        var currentRows: [Int: [Int]] = [:]
        for y in contentRows where !sample.frame.isBlank(y) {
            currentRows[sample.frame.rowHash(y), default: []].append(y)
        }
        for key in keys {
            var votes: [Int: Set<Int>] = [:]
            for oldY in key.corroboratingRows where settled.contains(key.offset + oldY) && !key.frame.isBlank(oldY) {
                for y in currentRows[key.frame.rowHash(oldY), default: []] where key.frame.sameRow(oldY, as: sample.frame, at: y) {
                    votes[key.offset + oldY - y, default: []].insert(sample.frame.rowHash(y))
                }
            }
            if votes.contains(where: { $0.key != offset && $0.value.count >= minimumRows }) { return false }
        }
        return true
    }
    /// Even sub-threshold translated content must veto an idle classification.
    private func hasMovingChanges(from old: ScrollingCaptureRaster, to new: ScrollingCaptureRaster) -> Bool {
        var changed: [Int: [Int]] = [:]
        for y in contentRows where !old.sameRow(y, as: new, at: y) && !old.isBlank(y) {
            changed[old.rowHash(y), default: []].append(y)
        }
        for y in contentRows where !old.sameRow(y, as: new, at: y) && !new.isBlank(y) {
            if changed[new.rowHash(y), default: []].contains(where: { $0 != y && old.sameRow($0, as: new, at: y) }) {
                return true
            }
        }
        return false
    }
}
