//
//  RecordingAudioExport.swift
//  Screendrop
//
//  Audio-only export and audio replacement for Studio projects. Together
//  they close the loop around speech-cleanup tools that offer no API
//  (Adobe Podcast Enhance and friends): export the edited soundtrack, run
//  it through the tool, drop the cleaned file back in, and re-export the
//  video - without leaving Screendrop for ffmpeg and a second app.
//
//  Both halves speak the same timeline. The exported audio is the finished
//  cut's soundtrack, so whatever comes back lies flat on the edited
//  timeline from zero rather than being re-cut through the clip list.
//

import AVFoundation
import Foundation
import UniformTypeIdentifiers

nonisolated enum RecordingAudioFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    /// AAC in an MP4 container. Screen recordings capture AAC already, so
    /// this is transparent, and it keeps hour-long narration well under the
    /// upload limits enhancement services impose.
    case m4a
    /// Uncompressed, for tools that accept nothing else.
    case wav

    var id: Self { self }

    var title: String {
        switch self {
        case .m4a: "M4A"
        case .wav: "WAV"
        }
    }

    var fileExtension: String { rawValue }

    var fileType: AVFileType {
        switch self {
        case .m4a: .m4a
        case .wav: .wav
        }
    }

    var writerSettings: [String: Any] {
        switch self {
        case .m4a:
            [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
        case .wav:
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }
    }

    /// What the import panel accepts. Enhancement services hand back MP3,
    /// WAV, or M4A depending on the service and the plan.
    static let importContentTypes: [UTType] = [.audio, .mp3, .wav, .mpeg4Audio, .aiff]
}

/// Renders the project's soundtrack on its own - the same audio the video
/// export would carry, mixed and cut identically.
nonisolated final class RecordingAudioExporter: @unchecked Sendable {
    struct Configuration: Sendable {
        let screenURL: URL
        let clipTimeline: RecordingClipTimeline
        /// When set, this file *is* the soundtrack: the recording's own
        /// audio is ignored and the file is simply transcoded, clamped to
        /// the edited timeline's length.
        let replacementURL: URL?
        let format: RecordingAudioFormat
        var volume: Double = 1
        var isolatedMicrophoneURL: URL? = nil
        var microphoneTrackID: CMPersistentTrackID? = nil
        var backgroundMusic: RecordingBackgroundMusicMixer.Configuration? = nil
    }

    enum ExportError: LocalizedError {
        case noAudioTrack
        case writerFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                "This recording has no audio to export."
            case .writerFailed(let error):
                error?.localizedDescription ?? "Writing the exported audio failed."
            }
        }
    }

    func export(
        _ configuration: Configuration,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let sourceAsset = AVURLAsset(url: configuration.screenURL)
        let sourceDuration = try await sourceAsset.load(.duration).seconds
        let timeline = configuration.clipTimeline.normalized(to: sourceDuration)
        let duration = timeline.duration
        guard duration >= RecordingClipSegment.minimumDuration else {
            throw VideoTrimExportError.invalidRange
        }

        let isolatedMicrophone = if let url = configuration.isolatedMicrophoneURL {
            await RecordingReplacementAudio.load(url: url, displayName: "Isolated voice")
        } else { nil as RecordingReplacementAudio? }
        if configuration.isolatedMicrophoneURL != nil, isolatedMicrophone == nil {
            throw RecordingVoiceIsolation.IsolationError.invalidAudio
        }
        let audioAsset: AVAsset = if let replacementURL = configuration.replacementURL {
            AVURLAsset(url: replacementURL)
        } else {
            try RecordingCompositionBuilder.makeAsset(
                from: sourceAsset,
                timeline: timeline,
                sourceDuration: sourceDuration,
                microphoneTrackID: configuration.microphoneTrackID,
                isolatedMicrophone: isolatedMicrophone?.track
            )
        }

        let prepared = try await RecordingBackgroundMusicMixer.prepare(asset: audioAsset, music: configuration.backgroundMusic,
            sourceURL: configuration.screenURL, microphoneTrackID: configuration.microphoneTrackID,
            timeline: timeline, volume: configuration.volume)
        let tracks = try await prepared.asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw ExportError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: prepared.asset)
        // Clamps a replacement that overruns the cut; a shorter one simply
        // ends early rather than being stretched.
        reader.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: nil)
        output.audioMix = prepared.mix
        output.alwaysCopiesSampleData = false
        reader.add(output)

        let outputURL = Self.temporaryOutputURL(pathExtension: configuration.format.fileExtension)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: configuration.format.fileType)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: configuration.format.writerSettings
        )
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        guard reader.startReading() else {
            throw reader.error ?? ExportError.writerFailed(nil)
        }
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        do {
            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let sampleBuffer = try Self.clipped(sampleBuffer, endingAt: reader.timeRange.end) else { break }
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    if writer.status == .failed { throw ExportError.writerFailed(writer.error) }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                guard input.append(sampleBuffer) else {
                    throw ExportError.writerFailed(writer.error)
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                if time.isFinite {
                    progress(min(0.98, max(0, time / duration)))
                }
            }
            if reader.status == .failed {
                throw reader.error ?? ExportError.writerFailed(nil)
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: reader.timeRange.end)
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.writerFailed(writer.error)
        }
        progress(1)
        return outputURL
    }

    /// Retimed mix readers can return their processing tail beyond the requested time range.
    static func clipped(_ buffer: CMSampleBuffer, endingAt end: CMTime) throws -> CMSampleBuffer? {
        let remaining = (end - CMSampleBufferGetPresentationTimeStamp(buffer)).seconds
        guard remaining.isFinite else { throw CocoaError(.fileReadCorruptFile) }
        guard remaining > 0 else { return nil }
        guard let description = CMSampleBufferGetFormatDescription(buffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              format.pointee.mSampleRate > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let count = CMSampleBufferGetNumSamples(buffer)
        let keep = min(count, Int((remaining * format.pointee.mSampleRate).rounded(.down)))
        guard keep > 0 else { return nil }
        if keep == count { return buffer }
        var result: CMSampleBuffer?
        guard CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
            sampleRange: CFRange(location: 0, length: keep), sampleBufferOut: &result) == noErr,
              let result else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    private static func temporaryOutputURL(pathExtension: String) -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(ScreendropStorage.directoryName, isDirectory: true)
            .appendingPathComponent("StudioExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
    }
}
