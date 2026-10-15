import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum RecordingAgentPromptWriter {
    enum ExportError: LocalizedError {
        case invalidMovie
        case unavailableFrame(Double)
        case jpegFailed

        var errorDescription: String? {
            switch self {
            case .invalidMovie: "The rendered recording could not be read."
            case .unavailableFrame(let time): "No matching frame could be extracted at \(RecordingAgentPromptPlan.timestamp(time))."
            case .jpegFailed: "A recording still could not be saved."
            }
        }
    }

    @concurrent
    static func write(movie: URL, plan: RecordingAgentPromptPlan, to directory: URL,
                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.invalidMovie }
        let rate = try await track.load(.nominalFrameRate)
        let frameDuration = rate.isFinite && rate > 0 ? 1 / Double(rate) : 1 / 30
        guard abs(duration - plan.duration) <= max(frameDuration * 2, 0.1) else { throw ExportError.invalidMovie }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: frameDuration, preferredTimescale: 60_000)
        defer { generator.cancelAllCGImageGeneration() }

        let staging = directory.appendingPathComponent(".agent-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stills = staging.appendingPathComponent("stills", isDirectory: true)
        try FileManager.default.createDirectory(at: stills, withIntermediateDirectories: false)
        var frameTimes: [Double] = []
        for (index, moment) in plan.moments.enumerated() {
            try Task.checkCancellation()
            let requested = min(moment.time, max(0, duration - frameDuration))
            let frame = try await generator.image(at: CMTime(seconds: requested, preferredTimescale: 60_000))
            let actual = frame.actualTime.seconds
            guard actual.isFinite, actual >= 0, actual < duration,
                  abs(actual - requested) <= frameDuration + 0.001 else { throw ExportError.unavailableFrame(moment.time) }
            try Task.checkCancellation()
            let url = stills.appendingPathComponent(RecordingAgentPromptPlan.stillName(index))
            guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw ExportError.jpegFailed
            }
            CGImageDestinationAddImage(output, frame.image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw ExportError.jpegFailed }
            frameTimes.append(actual)
            progress(Double(index + 1) / Double(plan.moments.count))
        }
        try plan.markdown(frameTimes: frameTimes).write(to: staging.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        let safe = plan.title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = String((safe.isEmpty || safe == "." || safe == ".." ? "Recording" : safe).prefix(100)) + " Agent Prompt"
        for suffix in 0..<10_000 {
            let name = suffix == 0 ? stem : "\(stem) \(suffix)"
            let destination = directory.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            do {
                try FileManager.default.moveItem(at: staging, to: destination)
                return destination
            } catch CocoaError.fileWriteFileExists { continue }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
