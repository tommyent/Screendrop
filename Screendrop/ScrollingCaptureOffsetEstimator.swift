import CoreGraphics
import Foundation
import Vision

/// Proposes how far the content moved up between two frames, in device pixels
/// (`new[y] == last[y + offset]`), with Vision's translational registration.
/// Only a candidate: it can be a few pixels off, so OffsetVerifier confirms it
/// exactly. Frames are tightly packed BGRA (premultipliedFirst, little endian),
/// as `ScrollingCaptureStitcher.pixels(of:colorSpace:)` draws them.
nonisolated enum ScrollingCaptureOffsetEstimator {
    /// Side-by-side bands, each the full height: a pinned sidebar or a playing
    /// video spoils one or two of them, not the page's motion in the rest.
    static let bands = 5
    /// Bands that must agree, so one or two spoiled bands can't decide.
    static let consensusBands = 4
    /// How far apart agreeing bands may be: Vision's registration is subpixel
    /// but drifts a few pixels on text.
    static let consensusSpread = 3.0

    /// The candidate offset: the bands' consensus, else the whole frame's
    /// shift. Vision's confidence is no gate (1.0 for all 63 whole-frame
    /// results on the corpus, unrelated frames included); the verifier is.
    static func candidateOffset(from last: [UInt8], to new: [UInt8], width: Int, height: Int,
                                ignoredTrailingColumns: Int) -> Int? {
        guard let images = images(last, new, width: width, height: height) else { return nil }
        let usable = ScrollingCaptureOffsetVerifier.hashedWidth(width: width, ignoredTrailingColumns: ignoredTrailingColumns)
        if let agreed = consensus(bandShifts(images, usable: usable)) { return agreed }
        return translation(images, in: CGRect(x: 0, y: 0, width: usable, height: height)).map { Int($0.rounded()) }
    }

    /// Each band's shift, nil-free, for the consensus.
    static func bandShifts(from last: [UInt8], to new: [UInt8], width: Int, height: Int,
                           ignoredTrailingColumns: Int) -> [Double] {
        guard let images = images(last, new, width: width, height: height) else { return [] }
        return bandShifts(images, usable: ScrollingCaptureOffsetVerifier.hashedWidth(width: width,
            ignoredTrailingColumns: ignoredTrailingColumns))
    }

    /// The mean of the tightest `consensusBands` shifts, rounded, when they lie
    /// within `consensusSpread` of each other.
    static func consensus(_ shifts: [Double]) -> Int? {
        let sorted = shifts.sorted()
        guard sorted.count >= consensusBands else { return nil }
        let run = (0...(sorted.count - consensusBands)).map { sorted[$0..<($0 + consensusBands)] }
            .min { $0.last! - $0.first! < $1.last! - $1.first! }!
        guard run.last! - run.first! <= consensusSpread else { return nil }
        return Int((run.reduce(0, +) / Double(run.count)).rounded())
    }

    private static func bandShifts(_ images: (last: CGImage, new: CGImage), usable: Int) -> [Double] {
        (0..<bands).compactMap { band in
            translation(images, in: CGRect(x: band * usable / bands, y: 0, width: usable / bands,
                                           height: images.new.height))
        }
    }

    /// Vision's vertical translation from `last` to `new`, as an upward content
    /// offset: Vision's y axis points up, so content moving up reads negative.
    private static func translation(_ images: (last: CGImage, new: CGImage), in rect: CGRect) -> Double? {
        guard let last = images.last.cropping(to: rect), let new = images.new.cropping(to: rect) else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: new)
        guard (try? VNImageRequestHandler(cgImage: last).perform([request])) != nil,
              let result = request.results?.first else { return nil }
        return -Double(result.alignmentTransform.ty)
    }

    /// The edge to Vision: CGImages of the packed bytes.
    private static func images(_ last: [UInt8], _ new: [UInt8], width: Int, height: Int) -> (last: CGImage, new: CGImage)? {
        guard let last = image(last, width: width, height: height), let new = image(new, width: width, height: height)
        else { return nil }
        return (last, new)
    }

    private static func image(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard pixels.count == width * height * 4,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                           | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
