import Foundation

/// In-memory, top-to-bottom BGRA pixels. No capture, image decoding or UI side effects.
nonisolated struct ScrollingCaptureRaster: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt32]
    private let rowHashes: [Int]
    private let blankRows: [Bool]

    init?(width: Int, height: Int, pixels: [UInt32]) {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= Int.max / height, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
        var hashes: [Int] = []
        var blanks: [Bool] = []
        for y in 0..<height {
            let row = pixels[(y * width)..<((y + 1) * width)]
            var hasher = Hasher()
            for pixel in row { hasher.combine(pixel) }
            hashes.append(hasher.finalize())
            blanks.append(row.allSatisfy { $0 == pixels[y * width] })
        }
        rowHashes = hashes
        blankRows = blanks
    }

    var byteCount: Int { pixels.count * 4 + rowHashes.count * MemoryLayout<Int>.stride + blankRows.count }
    func row(_ y: Int) -> ArraySlice<UInt32> { pixels[(y * width)..<((y + 1) * width)] }
    func sameRow(_ y: Int, as other: Self, at otherY: Int) -> Bool {
        rowHashes[y] == other.rowHashes[otherY] && row(y).elementsEqual(other.row(otherY))
    }
    func rowHash(_ y: Int) -> Int {
        rowHashes[y]
    }
    func isBlank(_ y: Int) -> Bool { blankRows[y] }
}

/// A sample's page placement, established only by exact overlap with registered samples.
nonisolated struct ScrollingCapturePlacement: Sendable {
    let index: Int
    let offset: Int
    let frame: ScrollingCaptureRaster
    let stableRows: Set<Int>
    let motionRows: Set<Int>
    let contentRows: Range<Int>
    var pageRows: Range<Int> { (offset + contentRows.lowerBound)..<(offset + contentRows.upperBound) }
}

/// Phase-one registration proof. Whole rows are deliberately stricter than R7's strips.
/// The caller supplies the scroll viewport inside the larger sample; window bounds alone
/// do not establish it. Fixed chrome outside that viewport must remain byte-identical.
nonisolated struct ScrollingCaptureRegistrationBuffer {
    enum State: Equatable { case pending, appended, lost }
    enum Failure: Equatable { case invalidSample, changedChrome, bufferExhausted }
    struct Event {
        let state: State
        var placements: [ScrollingCapturePlacement] = []
        var failure: Failure?
    }
    private struct Sample {
        let index: Int
        let frame: ScrollingCaptureRaster
        let stable: Set<Int>
        let motion: Set<Int>
    }
    private enum Match { case absent, ambiguous, offset(Int) }

    let initial: ScrollingCapturePlacement
    let maximumBufferedBytes: Int
    private(set) var frontier = 0
    private(set) var lastVerifiedOffset = 0
    private(set) var isLost = false
    private var keys: [ScrollingCapturePlacement]
    private var unresolved: [Sample] = []
    private var previous: ScrollingCaptureRaster
    private var lastIndex = 0
    private var lastWitness: ScrollingCapturePlacement?
    private var movingPageRows: Set<Int>
    private let contentRows: Range<Int>
    private let minimumRows = 8

    init?(first: ScrollingCaptureRaster, confirmation: ScrollingCaptureRaster,
          contentRows: Range<Int>, maximumBufferedBytes: Int = 128 * 1024 * 1024) {
        guard first.width == confirmation.width, first.height == confirmation.height,
              contentRows.lowerBound >= 0, contentRows.upperBound <= first.height,
              contentRows.count >= 16, maximumBufferedBytes / first.byteCount >= 4 else { return nil }
        let stable = Set(contentRows.filter { first.sameRow($0, as: confirmation, at: $0) })
        let motion = Set(contentRows).subtracting(stable)
        initial = ScrollingCapturePlacement(index: 0, offset: 0, frame: confirmation,
            stableRows: stable, motionRows: motion, contentRows: contentRows)
        keys = [initial]
        previous = confirmation
        self.contentRows = contentRows
        self.maximumBufferedBytes = maximumBufferedBytes
        movingPageRows = motion
        guard chromeMatches(first, confirmation) else { return nil }
    }

    // Count conservatively: two working frames plus every queued/registered frame.
    var bufferedBytes: Int {
        var retained = Set(keys.map(\.index) + unresolved.map(\.index) + [initial.index])
        if let lastWitness { retained.insert(lastWitness.index) }
        return (retained.count + 2) * initial.frame.byteCount
    }
    var pendingCount: Int { unresolved.count }

    mutating func add(_ frame: ScrollingCaptureRaster, at index: Int) -> Event {
        guard !isLost else { return Event(state: .lost) }
        guard index > lastIndex, frame.width == initial.frame.width,
              frame.height == initial.frame.height else { return lose(.invalidSample) }
        lastIndex = index
        guard chromeMatches(initial.frame, frame) else { return lose(.changedChrome) }
        let stable = Set(contentRows.filter { previous.sameRow($0, as: frame, at: $0) })
        let sample = Sample(index: index, frame: frame, stable: stable,
                            motion: Set(contentRows).subtracting(stable))
        previous = frame
        switch locate(sample) {
        case .offset(let offset):
            guard offset.magnitude <= 16_384 else { return lose(.invalidSample) }
            // A fresh zero subset is never page-position authority. Keep the baseline.
            if offset == lastVerifiedOffset {
                guard let witness = lastWitness,
                      witness.stableRows.allSatisfy({ witness.frame.sameRow($0, as: frame, at: $0) }),
                      !hasMovingChanges(from: witness.frame, to: frame) else {
                    return Event(state: .pending)
                }
            }
            let placement = placed(sample, at: offset)
            var resolved = [placement]
            movingPageRows.formUnion(sample.motion.map { $0 + offset })
            keys.append(placement)
            for waiting in unresolved {
                if case .offset(let position) = locate(waiting, requiringDisplacement: true) {
                    resolved.append(placed(waiting, at: position))
                }
            }
            // Unplaceable earlier frames cannot be replayed behind a committed cut.
            unresolved.removeAll()
            let highest = resolved.map(\.offset).max() ?? offset
            let advanced = highest > frontier
            if offset != lastVerifiedOffset { lastWitness = placement }
            frontier = max(frontier, highest)
            lastVerifiedOffset = offset
            trimKeys()
            return Event(state: advanced ? .appended : .pending,
                         placements: resolved.sorted { $0.index < $1.index })
        case .absent, .ambiguous:
            // Without an at-rest witness there is nothing useful to retain. Hover/
            // selection transitions do not accumulate frames or trigger lost-track.
            guard stable.count >= minimumRows,
                  hasNonzeroEvidence(sample) else { return Event(state: .pending) }
            unresolved.append(sample)
            trimKeys()
            if bufferedBytes > maximumBufferedBytes { return lose(.bufferExhausted) }
            return Event(state: .pending)
        }
    }

    /// Recovery drops unresolved samples; they must not reappear after Continue.
    mutating func discardUnresolved() { unresolved.removeAll(); isLost = false }

    private mutating func trimKeys() {
        while keys.count > 1, bufferedBytes > maximumBufferedBytes { keys.removeFirst() }
    }
    private mutating func lose(_ failure: Failure) -> Event {
        unresolved.removeAll()
        isLost = true
        return Event(state: .lost, failure: failure)
    }
    private func placed(_ sample: Sample, at offset: Int) -> ScrollingCapturePlacement {
        ScrollingCapturePlacement(index: sample.index, offset: offset, frame: sample.frame,
            stableRows: sample.stable, motionRows: sample.motion, contentRows: contentRows)
    }
    private func chromeMatches(_ a: ScrollingCaptureRaster, _ b: ScrollingCaptureRaster) -> Bool {
        (0..<a.height).filter { !contentRows.contains($0) }.allSatisfy { a.sameRow($0, as: b, at: $0) }
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
        if offset != lastVerifiedOffset, let witness = lastWitness,
           witness.stableRows.allSatisfy({ witness.frame.sameRow($0, as: sample.frame, at: $0) }) {
            return .ambiguous
        }
        return .offset(offset)
    }
    private func votes(_ key: ScrollingCapturePlacement, _ sample: Sample) -> [Int: Set<Int>] {
        var oldRows: [Int: [Int]] = [:]
        for y in key.stableRows where !key.frame.isBlank(y) && !movingPageRows.contains(key.offset + y) {
            oldRows[key.frame.rowHash(y), default: []].append(y)
        }
        var shifts: [Int: Set<Int>] = [:]
        for y in sample.stable where !sample.frame.isBlank(y) {
            let hash = sample.frame.rowHash(y)
            for oldY in oldRows[hash, default: []] where key.frame.sameRow(oldY, as: sample.frame, at: y) {
                guard !movingPageRows.contains(key.offset + oldY) else { continue }
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
