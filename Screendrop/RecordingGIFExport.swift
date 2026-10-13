//
//  RecordingGIFExport.swift
//  Screendrop
//
//  GIF as an export format for recordings (sd-ahk). The Studio renders its
//  movie as usual, then this samples it into a looping GIF. Renders, cached
//  deliverables and previews stay movies.
//

import AVFoundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum GIFFrameRate: String, CaseIterable, Identifiable, Codable, Sendable {
    case fps10 = "10 fps"
    case fps15 = "15 fps"
    case fps24 = "24 fps"

    static let `default` = GIFFrameRate.fps15
    var id: String { rawValue }
    var framesPerSecond: Double {
        switch self {
        case .fps10: 10
        case .fps15: 15
        case .fps24: 24
        }
    }
}

nonisolated enum GIFWidth: String, CaseIterable, Identifiable, Codable, Sendable {
    case w640 = "640 px"
    case w960 = "960 px"
    case original = "Original"

    static let `default` = GIFWidth.w960
    var id: String { rawValue }
    /// Nil keeps the movie's own width; GIFs are never scaled up.
    var pixels: Int? {
        switch self {
        case .w640: 640
        case .w960: 960
        case .original: nil
        }
    }
}

nonisolated enum RecordingGIFExport {
    enum GIFError: LocalizedError {
        case emptyMovie, cannotWrite

        var errorDescription: String? {
            switch self {
            case .emptyMovie: "This recording has no frames to make a GIF from."
            case .cannotWrite: "The GIF could not be written."
            }
        }
    }

    /// Writes `movie` to `destination` as a GIF that loops forever, sampled
    /// at `frameRate` and no wider than `width`.
    static func write(
        movie: URL,
        to destination: URL,
        frameRate: GIFFrameRate,
        width: GIFWidth,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let asset = AVURLAsset(url: movie)
        let seconds = try await asset.load(.duration).seconds
        let fps = frameRate.framesPerSecond
        let count = seconds.isFinite ? Int(seconds * fps) : 0
        guard count > 0 else { throw GIFError.emptyMovie }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Half a frame either way: exact frames cost a decode from the last keyframe each.
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        if let pixels = width.pixels {
            // Fits the box, never upscales; the height is left free.
            generator.maximumSize = CGSize(width: pixels, height: 100_000)
        }

        guard let gif = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, count, nil)
        else { throw GIFError.cannotWrite }
        // A colour map per frame lets ImageIO write each frame as it comes. With
        // one global map it held every frame until the end: peak memory rose
        // 2.2 GB for 40 s at 960 px, and 26 MB this way (synthetic movie).
        CGImageDestinationSetProperties(gif, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0, kCGImagePropertyGIFHasGlobalColorMap: false],
        ] as CFDictionary)
        let frame = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 1 / fps,
                kCGImagePropertyGIFUnclampedDelayTime: 1 / fps,
            ],
        ] as CFDictionary
        for index in 0..<count {
            try Task.checkCancellation()
            let time = CMTime(seconds: Double(index) / fps, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            CGImageDestinationAddImage(gif, image, frame)
            progress(Double(index + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(gif) else { throw GIFError.cannotWrite }
    }
}
