import Foundation

/// Vision proposes, exact pixels confirm, no frame is lost: each frame is
/// placed against the last reference frame, or skipped until one fits.
/// Frames are tightly packed BGRA, all the size of the first.
///
/// The output is the first frame down to the cut, every row appended since,
/// then the last reference frame from the cut down: the rows below the cut are
/// held back (see `ScrollingCaptureOffsetVerifier.heldBackFraction`).
actor ScrollingCaptureFrameStitcher {
    enum Placement: Equatable, Sendable {
        /// Moved up by this many rows; they were appended.
        case appended(Int)
        /// Didn't move: the page redrew in place, nothing appended.
        case redrawn
        /// Moved back down this far (negative), the first frame in a row to
        /// do so: nothing changes yet, so one stray frame can't trim.
        case upward(Int)
        /// Moved back down again: the output was cut back to end with it.
        case trimmed(Int)
        /// Moved back down again, above where the output began: it starts
        /// over from this frame.
        case restarted(Int)
        /// Not verified: the reference stays, and the next frame is compared
        /// with it.
        case skipped

        var offset: Int? {
            switch self {
            case .appended(let k), .upward(let k), .trimmed(let k), .restarted(let k): k
            case .redrawn: 0
            case .skipped: nil
            }
        }

        /// The frame became the reference the next one is compared with.
        var isReference: Bool {
            switch self {
            case .appended, .redrawn, .trimmed, .restarted: true
            case .upward, .skipped: false
            }
        }
    }

    private let width: Int
    private let height: Int
    private let ignoredTrailingColumns: Int
    /// Rows above it are appended; rows below it are held back.
    private let cut: Int
    private var first: [UInt8]
    private var appended: [UInt8] = []
    private var last: [UInt8]
    private var lastWasUpward = false

    init?(firstFrame: [UInt8], width: Int, height: Int, ignoredTrailingColumns: Int) {
        guard width > 0, height > 0, firstFrame.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.ignoredTrailingColumns = ignoredTrailingColumns
        cut = ScrollingCaptureOffsetVerifier.cut(in: 0..<height)
        first = firstFrame
        last = firstFrame
    }

    var stitchedHeight: Int { height + appended.count / (width * 4) }

    func add(_ frame: [UInt8]) -> Placement {
        guard frame.count == last.count,
              let candidate = ScrollingCaptureOffsetEstimator.candidateOffset(from: last, to: frame,
                  width: width, height: height, ignoredTrailingColumns: ignoredTrailingColumns),
              let k = ScrollingCaptureOffsetVerifier.verifiedOffset(candidate: candidate, from: last, to: frame,
                  width: width, height: height, ignoredTrailingColumns: ignoredTrailingColumns)?.offset
        else { return .skipped }
        let rowBytes = width * 4
        if k < 0 {
            defer { lastWasUpward = true }
            guard lastWasUpward else { return .upward(k) }
            last = frame
            guard -k * rowBytes <= appended.count else {
                first = frame
                appended = []
                return .restarted(k)
            }
            appended.removeLast(-k * rowBytes)
            return .trimmed(k)
        }
        // Never true: the verifier only confirms overlap above the cut.
        guard k < cut else { return .skipped }
        lastWasUpward = false
        last = frame
        guard k > 0 else { return .redrawn }
        appended.append(contentsOf: frame[((cut - k) * rowBytes)..<(cut * rowBytes)])
        return .appended(k)
    }

    /// Packed BGRA, `stitchedHeight` rows.
    func makeImage() -> [UInt8] {
        let split = cut * width * 4
        return Array(first[..<split]) + appended + Array(last[split...])
    }
}
