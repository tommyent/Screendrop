import CoreGraphics
import Foundation

/// Scrolling Capture's frames on their way to the stitcher: each stream frame
/// is cropped to the selection, placed (Vision proposes, exact pixels confirm,
/// the stitcher skips what doesn't fit) and written to the frame dump when it's
/// on. The presenter drives it, and so does the corpus replay
/// (scripts/scroll-corpus-replay.swift), so both take this one path.
actor ScrollingCaptureFeed {
    struct Update: Sendable {
        let placement: ScrollingCaptureFrameStitcher.Placement
        /// The stitched height so far, in pixels.
        let height: Int
        /// The frame was skipped, though Vision's bands agree on an offset the
        /// verifier could confirm: the view still overlaps the reference, so
        /// something on the page changed (a video, an animation, a hover)
        /// rather than the view scrolling past what fits. Over the corpus's
        /// 277 refused frames this says 78 changing and 117 not at 1 s
        /// (no-overlap jumps say not); Vision's candidate alone said
        /// changing for all but 6, jumps included (scroll-corpus-run).
        let keepsChanging: Bool
    }

    private let stitcher: ScrollingCaptureFrameStitcher
    private let dump: ScrollingCaptureFrameDump?
    private let selection: CGRect
    private let frameSize: CGSize
    private let colorSpace: CGColorSpace
    private var index = 0
    private var reference = 0

    init?(firstFrame: CGImage, at time: TimeInterval = ScrollingCaptureSampleTiming.now(),
          selection rect: ScrollingCaptureOutputRect, ignoredTrailingColumns: Int) {
        let selection = CGRect(x: rect.columns.lowerBound, y: rect.rows.lowerBound,
                               width: rect.columns.count, height: rect.rows.count)
        let space = ScrollingCapturePixels.colorSpace(of: firstFrame)
        guard let cropped = Self.crop(firstFrame, to: selection),
              let pixels = ScrollingCapturePixels.bytes(of: cropped, in: space),
              let stitcher = ScrollingCaptureFrameStitcher(firstFrame: pixels, width: cropped.width,
                  height: cropped.height, ignoredTrailingColumns: ignoredTrailingColumns) else { return nil }
        self.stitcher = stitcher
        self.selection = selection
        frameSize = CGSize(width: firstFrame.width, height: firstFrame.height)
        colorSpace = space
        dump = ScrollingCaptureFrameDump(width: cropped.width, height: cropped.height,
                                         ignoredTrailingColumns: ignoredTrailingColumns)
        dump?.write(index: 0, time: time, frame: cropped, verifiedOffset: 0, action: "first")
    }

    func add(_ frame: CGImage, at time: TimeInterval) async -> Update {
        index += 1
        let cropped = CGSize(width: frame.width, height: frame.height) == frameSize ? Self.crop(frame, to: selection) : nil
        let pixels = cropped.flatMap { ScrollingCapturePixels.bytes(of: $0, in: colorSpace) }
        // A frame that can't be read goes to the stitcher as one that doesn't
        // fit, so it also breaks a run of upward frames.
        let (placement, candidate) = await stitcher.add(pixels ?? [])
        let keepsChanging = placement == .skipped && candidate.map {
            $0.bandsAgree && ScrollingCaptureOffsetVerifier.canConfirm($0.offset, height: Int(selection.height))
        } ?? false
        dump?.write(index: index, time: time, frame: cropped, reference: reference, candidateOffset: candidate?.offset,
                    verifiedOffset: placement.offset, action: String(String(describing: placement).prefix { $0 != "(" }))
        if placement.isReference { reference = index }
        return Update(placement: placement, height: await stitcher.stitchedHeight, keepsChanging: keepsChanging)
    }

    func makeImage() async -> CGImage? {
        ScrollingCapturePixels.image(await stitcher.makeImage(), width: Int(selection.width),
                                     height: await stitcher.stitchedHeight, colorSpace: colorSpace)
    }

    private static func crop(_ frame: CGImage, to selection: CGRect) -> CGImage? {
        guard CGRect(x: 0, y: 0, width: frame.width, height: frame.height).contains(selection) else { return nil }
        return frame.cropping(to: selection)
    }
}
