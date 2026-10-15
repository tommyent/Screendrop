import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

/// Fixed, top-left normalized bounds in the original screen movie, on its source clock.
nonisolated struct RecordingRedaction: Codable, Equatable, Identifiable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case blur, pixelate

        var title: String { self == .blur ? "Blur" : "Pixelate" }
    }

    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var rect: CGRect
    var mode: Mode = .blur
    var strength: Double = 0.8

    /// Legacy links have no snapshot and must be treated as unredacted.
    static func needsSharedReplacement(_ current: [Self], shared: [Self]?) -> Bool {
        !current.isEmpty && current != (shared ?? [])
    }

    func validate(sourceDuration: TimeInterval? = nil) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start,
              sourceDuration.map({ end <= $0 + 0.000_001 }) ?? true,
              [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.minX >= 0, rect.minY >= 0, rect.width > 0, rect.height > 0,
              rect.maxX <= 1, rect.maxY <= 1,
              strength.isFinite, (0...1).contains(strength) else {
            throw RecordingRedactionError.invalidRegion
        }
    }

    func pixelRect(in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + rect.minX * extent.width,
               y: extent.minY + (1 - rect.maxY) * extent.height,
               width: rect.width * extent.width, height: rect.height * extent.height)
            .integral.intersection(extent)
    }

    /// Intersect the output frame with mapped mask ranges, rounding coverage outward.
    func covers(editorTime: TimeInterval, frameDuration: TimeInterval, timeline: RecordingClipTimeline) -> Bool {
        timeline.slices(overlapping: start, sourceEnd: end).contains {
            editorTime < $0.editorEnd && editorTime + frameDuration > $0.editorStart
        }
    }
}

nonisolated enum RecordingRedactionError: LocalizedError {
    case invalidRegion, filterFailed

    var errorDescription: String? {
        switch self {
        case .invalidRegion: "A video redaction has invalid bounds or timing. Fix it in Studio before exporting."
        case .filterFailed: "The video redaction could not be rendered. No unredacted output was used."
        }
    }
}

nonisolated enum RecordingRedactionFilter {
    static func apply(_ redactions: [RecordingRedaction], to source: CIImage) throws -> CIImage {
        var result = source
        for region in redactions {
            try region.validate()
            let rect = region.pixelRect(in: source.extent)
            guard !rect.isEmpty else { throw RecordingRedactionError.filterFailed }
            let filtered: CIImage?
            switch region.mode {
            case .blur:
                let radius = RedactionImageProcessor.blurRadius(for: max(region.strength, 0.35))
                let filter = CIFilter.gaussianBlur()
                filter.inputImage = result.cropped(to: rect.insetBy(dx: -radius * 3, dy: -radius * 3)
                    .intersection(source.extent)).clampedToExtent()
                filter.radius = Float(radius)
                filtered = filter.outputImage
            case .pixelate:
                let filter = CIFilter.pixellate()
                filter.inputImage = result.clampedToExtent()
                filter.scale = Float(RedactionImageProcessor.pixelBlockSize(for: max(region.strength, 0.35)))
                filter.center = CGPoint(x: rect.midX, y: rect.midY)
                filtered = filter.outputImage
            }
            guard let filtered else { throw RecordingRedactionError.filterFailed }
            result = filtered.cropped(to: rect).composited(over: result).cropped(to: source.extent)
        }
        return result
    }

    /// Materialize once before either screen renderer; the master is never mutated.
    static func buffer(from source: CVPixelBuffer, redactions: [RecordingRedaction], context: CIContext) throws -> CVPixelBuffer {
        guard !redactions.isEmpty else { return source }
        let image = try apply(redactions, to: CIImage(cvPixelBuffer: source))
        guard let cgImage = context.createCGImage(image, from: image.extent, format: .BGRA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false) else {
            throw RecordingRedactionError.filterFailed
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, cgImage.width, cgImage.height, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferMetalCompatibilityKey: true,
                                   kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw RecordingRedactionError.filterFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let bitmap = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: cgImage.width, height: cgImage.height,
                                     bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw RecordingRedactionError.filterFailed }
        bitmap.draw(cgImage, in: image.extent)
        bitmap.flush()
        return buffer
    }

    static func composition(asset: AVAsset, redactions: [RecordingRedaction], timeline: RecordingClipTimeline? = nil) async throws -> AVVideoComposition {
        for region in redactions { try region.validate() }
        let duration = try await asset.load(.duration).seconds
        let map = timeline ?? .full(sourceDuration: duration)
        let interval = 1.0 / 60
        let context = CIContext(options: [.cacheIntermediates: false])
        let composition = try await AVVideoComposition(applyingFiltersTo: asset) { parameters in
            let active = redactions.filter {
                $0.covers(editorTime: parameters.compositionTime.seconds, frameDuration: interval, timeline: map)
            }
            return AVCIImageFilteringResult(resultImage: try apply(active, to: parameters.sourceImage), ciContext: context)
        }
        // A static capture may hold one source frame across a mask boundary.
        // Force filtering on the playback clock rather than only at source samples.
        return AVVideoComposition(configuration: .init(
            customVideoCompositorClass: composition.customVideoCompositorClass,
            frameDuration: CMTime(value: 1, timescale: 60),
            instructions: composition.instructions,
            renderSize: composition.renderSize,
            sourceTrackIDForFrameTiming: kCMPersistentTrackID_Invalid
        ))
    }
}
