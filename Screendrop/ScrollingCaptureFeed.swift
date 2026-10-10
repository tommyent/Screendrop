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
        /// At rest, pixels changed over most of the selection: a video is
        /// playing, and no pixel method can place frames past it.
        let isVideoPlaying: Bool
    }

    /// Changed pixels at rest whose bounding box covers more than this share
    /// of the selection are a video, not a hover or a caret (the plan's hint).
    static let videoCoverage = 0.5

    private let stitcher: ScrollingCaptureFrameStitcher
    private let dump: ScrollingCaptureFrameDump?
    private let selection: CGRect
    private let frameSize: CGSize
    private let colorSpace: CGColorSpace
    private let ignoredTrailingColumns: Int
    private var index = 0
    private var reference = 0
    /// The reference frame's pixels, which a frame at rest is compared with.
    private var referencePixels: [UInt8]

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
        self.ignoredTrailingColumns = ignoredTrailingColumns
        referencePixels = pixels
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
            return Update(placement: .skipped, height: await stitcher.stitchedHeight, isVideoPlaying: false)
        }
        let (placement, candidate) = await stitcher.add(pixels)
        let atRest = placement == .redrawn || placement == .skipped && candidate == 0
        let isVideoPlaying = atRest && Self.changedShare(referencePixels, pixels, width: cropped.width,
            usableWidth: ScrollingCaptureOffsetVerifier.hashedWidth(width: cropped.width,
                ignoredTrailingColumns: ignoredTrailingColumns)) > Self.videoCoverage
        dump?.write(index: index, time: time, frame: cropped, reference: reference, candidateOffset: candidate,
                    verifiedOffset: placement.offset, action: String(String(describing: placement).prefix { $0 != "(" }))
        if placement.isReference {
            reference = index
            referencePixels = pixels
        }
        return Update(placement: placement, height: await stitcher.stitchedHeight, isVideoPlaying: isVideoPlaying)
    }

    /// The bounding box of the pixels that differ, as a share of the frame;
    /// the trailing scroll bar columns are left out.
    static func changedShare(_ a: [UInt8], _ b: [UInt8], width: Int, usableWidth: Int) -> Double {
        let height = a.count / (width * 4)
        var top = height, bottom = -1, left = usableWidth, right = -1
        a.withUnsafeBytes { a in b.withUnsafeBytes { b in
            let a = a.bindMemory(to: UInt32.self), b = b.bindMemory(to: UInt32.self)
            for y in 0..<height {
                let row = y * width
                guard let first = (0..<usableWidth).first(where: { a[row + $0] != b[row + $0] }) else { continue }
                let last = (0..<usableWidth).last { a[row + $0] != b[row + $0] }!
                top = min(top, y); bottom = y
                left = min(left, first); right = max(right, last)
            }
        } }
        guard bottom >= 0 else { return 0 }
        return Double((bottom - top + 1) * (right - left + 1)) / Double(height * width)
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
