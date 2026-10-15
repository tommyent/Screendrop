import AVFoundation
import Foundation
import OSLog

nonisolated struct RecordingMusicAnalysis: Sendable {
    var levels: [Float]
    let speech: [ClosedRange<Double>]
    init(levels: [Float]) {
        self.levels = levels
        speech = RecordingMusicEnvelope.speechRanges(levels: levels)
    }
    var waveform: [Float] {
        guard !levels.isEmpty else { return [] }
        let count = min(180, levels.count)
        let peak = max(levels.max() ?? 0, 0.0001)
        return (0..<count).map { index in
            let start = index * levels.count / count
            let end = (index + 1) * levels.count / count
            return (levels[start..<end].max() ?? 0) / peak
        }
    }

    @concurrent
    static func read(url: URL, trackID: CMPersistentTrackID) async throws -> Self {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first(where: { $0.trackID == trackID }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let rate = 16_000.0
        let framesPerWindow = Int(rate * RecordingMusicEnvelope.window)
        let count = Int(ceil(duration / RecordingMusicEnvelope.window))
        var sums = [Double](repeating: 0, count: count)
        var counts = [Int](repeating: 0, count: count)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer { reader.cancelReading() }
        while let ready = try await provider.next() {
            try Task.checkCancellation()
            let time = ready.presentationTimeStamp.seconds
            guard time.isFinite else { throw CocoaError(.fileReadCorruptFile) }
            try ready.withUnsafeSampleBuffer { sample in
                guard let data = CMSampleBufferGetDataBuffer(sample) else { throw CocoaError(.fileReadCorruptFile) }
                let frames = CMSampleBufferGetNumSamples(sample)
                var samples = [Float](repeating: 0, count: frames)
                let status = samples.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                guard status == noErr else { throw CocoaError(.fileReadCorruptFile) }
                let first = Int((time * rate).rounded())
                for (offset, value) in samples.enumerated() {
                    let frame = first + offset
                    guard frame >= 0, value.isFinite else { continue }
                    let index = frame / framesPerWindow
                    if index < count {
                        sums[index] += Double(value) * Double(value)
                        counts[index] += 1
                    }
                }
            }
        }
        guard reader.status != .failed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        return Self(levels: zip(sums, counts).map { sum, count in count > 0 ? Float(sqrt(sum / Double(count))) : 0 })
    }
}

/// Source-time analysis survives trims, speed changes and repeated export routes.
actor RecordingMusicAnalysisCache {
    static let shared = RecordingMusicAnalysisCache()
    nonisolated static let logger = Logger(subsystem: "com.tommyent.Sukusho", category: "MusicAnalysis")
    private struct Key: Hashable {
        var url: URL
        var trackID: CMPersistentTrackID
        var size: Int?
        var modified: Date?
    }
    private var entries: [Key: Task<RecordingMusicAnalysis, Error>] = [:]

    func analysis(url: URL, trackID: CMPersistentTrackID) async throws -> RecordingMusicAnalysis {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = Key(url: url.standardizedFileURL, trackID: trackID, size: values.fileSize, modified: values.contentModificationDate)
        let task: Task<RecordingMusicAnalysis, Error>
        if let cached = entries[key] { task = cached }
        else {
            task = Task { try await RecordingMusicAnalysis.read(url: url, trackID: trackID) }
            // Keep only a handful of source tracks; analysis is cheap to recreate on reopening.
            if entries.count >= 4 { entries.removeAll() }
            entries[key] = task
        }
        do { return try await Self.wait(for: task) }
        catch {
            if !(error is CancellationError) { entries[key] = nil }
            throw error
        }
    }

    func availableAnalysis(url: URL, trackID: CMPersistentTrackID) async throws -> RecordingMusicAnalysis? {
        do { return try await analysis(url: url, trackID: trackID) }
        catch is CancellationError { throw CancellationError() }
        catch {
            Self.logger.warning("Audio analysis failed; music continues without that waveform or ducking: \(error.localizedDescription)")
            return nil
        }
    }

    /// A stream's wait is cancellable even while the shared cache task keeps decoding.
    nonisolated static func wait(for task: Task<RecordingMusicAnalysis, Error>) async throws -> RecordingMusicAnalysis {
        try Task.checkCancellation()
        let stream = AsyncThrowingStream<RecordingMusicAnalysis, Error> { continuation in
            let waiter = Task {
                do { continuation.yield(try await task.value); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in waiter.cancel() }
        }
        var iterator = stream.makeAsyncIterator()
        guard let result = try await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return result
    }
}
