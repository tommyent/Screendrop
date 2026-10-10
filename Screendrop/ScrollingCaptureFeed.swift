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
        guard CGSize(width: frame.width, height: frame.height) == frameSize,
              let cropped = Self.crop(frame, to: selection),
              let pixels = ScrollingCapturePixels.bytes(of: cropped, in: colorSpace) else {
            dump?.write(index: index, time: time, frame: nil, reference: reference, verifiedOffset: nil, action: "skipped")
            return Update(placement: .skipped, height: await stitcher.stitchedHeight)
        }
        let (placement, candidate) = await stitcher.add(pixels)
        dump?.write(index: index, time: time, frame: cropped, reference: reference, candidateOffset: candidate,
                    verifiedOffset: placement.offset, action: String(String(describing: placement).prefix { $0 != "(" }))
        if placement.isReference { reference = index }
        return Update(placement: placement, height: await stitcher.stitchedHeight)
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
