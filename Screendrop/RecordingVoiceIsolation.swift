import Accelerate
import AudioToolbox
import AVFoundation
import Foundation

nonisolated enum RecordingVoiceIsolation {
    static let fileName = "mic-isolated-v2.m4a"
    static let sampleRate = 48_000.0
    // shortcut: lag search stops at 250 ms; extend it if a future OS unit exceeds that delay.
    static let maximumLag = 12_000

    enum IsolationError: LocalizedError {
        case missingMicrophone, invalidAudio, renderFailed, alignmentFailed
        var errorDescription: String? {
            switch self {
            case .missingMicrophone: "The source microphone track could not be identified."
            case .invalidAudio: "The microphone audio could not be read."
            case .renderFailed: "Apple's voice isolation could not render this recording."
            case .alignmentFailed: "The isolated voice could not be aligned with the recording."
            }
        }
    }

    /// The capture writer adds system audio first, then its separate mono microphone track.
    static func microphoneTrack(in tracks: [AVAssetTrack], includesMicrophone: Bool, includesSystemAudio: Bool) -> AVAssetTrack? {
        let audio = tracks.filter { $0.mediaType == .audio }
        guard includesMicrophone, audio.count == (includesSystemAudio ? 2 : 1) else { return nil }
        return audio.last
    }

    @concurrent
    static func render(sourceURL: URL, microphoneTrackID: CMPersistentTrackID, destinationURL: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first(where: { $0.trackID == microphoneTrackID }) else {
            throw IsolationError.missingMicrophone
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw IsolationError.invalidAudio
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let cached = AVURLAsset(url: destinationURL)
            if let cachedDuration = try? await cached.load(.duration).seconds,
               abs(cachedDuration - duration) < 0.05,
               let tracks = try? await cached.loadTracks(withMediaType: .audio), tracks.count == 1 {
                progress(1)
                return
            }
        }
        let total = AVAudioFramePosition((duration * sampleRate).rounded())
        let scratchName = ".voice-\(UUID().uuidString)"
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(scratchName)
        let inputURL = scratch.appendingPathExtension("input.caf")
        let outputURL = scratch.appendingPathExtension("output.caf")
        let pendingURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(scratchName).appendingPathExtension("m4a")
        defer {
            for url in [inputURL, outputURL, pendingURL] { try? FileManager.default.removeItem(at: url) }
        }
        var lastPercent = -1
        func report(_ value: Double) {
            let percent = Int(value * 100)
            guard percent > lastPercent else { return }
            lastPercent = percent
            progress(value)
        }
        try await extract(track: track, asset: asset, total: total, format: format, url: inputURL) {
            report($0 * 0.2)
        }
        try Task.checkCancellation()
        let peakFrame = try renderOffline(inputURL: inputURL, outputURL: outputURL, format: format) { report(0.2 + $0 * 0.6) }
        let input = try AVAudioFile(forReading: inputURL)
        let output = try AVAudioFile(forReading: outputURL)
        let windowCount = min(Int(total), Int(sampleRate * 2))
        // Center on surviving output so removed input noise cannot select a silent window.
        let start = min(max(peakFrame - AVAudioFramePosition(sampleRate), AVAudioFramePosition(sampleRate)), total - AVAudioFramePosition(windowCount))
        input.framePosition = start
        output.framePosition = start
        let sourceWindow = try samples(input, count: windowCount)
        let renderedWindow = try samples(output, count: windowCount + maximumLag)
        guard let lag = RecordingAudioLag.measure(input: sourceWindow, output: renderedWindow, maximumLag: maximumLag) else {
            throw IsolationError.alignmentFailed
        }
        output.framePosition = AVAudioFramePosition(lag)
        try writeAligned(output, total: total, format: format, url: pendingURL) { report(0.8 + $0 * 0.2) }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: pendingURL)
        } else {
            try FileManager.default.moveItem(at: pendingURL, to: destinationURL)
        }
        progress(1)
    }

    private static func buffer(_ format: AVAudioFormat, capacity: AVAudioFrameCount = 4096) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw IsolationError.invalidAudio }
        return buffer
    }

    private static func extract(track: AVAssetTrack, asset: AVAsset, total: AVAudioFramePosition,
                                format: AVAudioFormat, url: URL, progress: (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw IsolationError.invalidAudio }
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer { reader.cancelReading() }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        defer { file.close() }
        let silence = try buffer(format)
        silence.frameLength = silence.frameCapacity
        memset(silence.floatChannelData![0], 0, Int(silence.frameLength) * MemoryLayout<Float>.size)
        var written: AVAudioFramePosition = 0
        func pad(to frame: AVAudioFramePosition) throws {
            while written < frame {
                try Task.checkCancellation()
                silence.frameLength = AVAudioFrameCount(min(4096, frame - written))
                try file.write(from: silence)
                written += AVAudioFramePosition(silence.frameLength)
            }
        }
        while let readySample = try await provider.next() {
            try Task.checkCancellation()
            let timestamp = readySample.presentationTimeStamp.seconds
            let sample = readySample.withUnsafeSampleBuffer { $0 }
            guard timestamp.isFinite, let data = CMSampleBufferGetDataBuffer(sample) else { throw IsolationError.invalidAudio }
            let frame = AVAudioFramePosition((timestamp * sampleRate).rounded())
            try pad(to: min(total, max(0, frame)))
            let frames = CMSampleBufferGetNumSamples(sample)
            let skip = Int(max(0, written - frame))
            let count = min(frames - skip, Int(total - written))
            guard count > 0 else { continue }
            let chunk = try buffer(format, capacity: AVAudioFrameCount(count))
            chunk.frameLength = AVAudioFrameCount(count)
            guard CMBlockBufferCopyDataBytes(data, atOffset: skip * 4, dataLength: count * 4,
                                            destination: chunk.floatChannelData![0]) == kCMBlockBufferNoErr else {
                throw IsolationError.invalidAudio
            }
            try file.write(from: chunk)
            written += AVAudioFramePosition(count)
            progress(Double(written) / Double(total))
        }
        guard reader.status != .failed else { throw reader.error ?? IsolationError.invalidAudio }
        try pad(to: total)
    }

    private static func renderOffline(inputURL: URL, outputURL: URL, format: AVAudioFormat,
                                      progress: (Double) -> Void) throws -> AVAudioFramePosition {
        let input = try AVAudioFile(forReading: inputURL)
        let output = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        defer { output.close() }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let effect = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        engine.attach(player)
        engine.attach(effect)
        try engine.connectNode(player, to: effect, format: format)
        try engine.connectNode(effect, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try effect.withAudioUnit { audioUnit in
            guard AudioUnitSetParameter(audioUnit, kAUSoundIsolationParam_WetDryMixPercent,
                                        kAudioUnitScope_Global, 0, 100, 0) == noErr,
                  AudioUnitSetParameter(audioUnit, kAUSoundIsolationParam_SoundToIsolate,
                                        kAudioUnitScope_Global, 0, Float(kAUSoundIsolationSoundType_HighQualityVoice), 0) == noErr else {
                throw IsolationError.renderFailed
            }
        }
        // Flush the unit's unreported delay so the final spoken samples survive the shift.
        let tail = try buffer(format, capacity: AVAudioFrameCount(maximumLag))
        tail.frameLength = tail.frameCapacity
        memset(tail.floatChannelData![0], 0, maximumLag * 4)
        player.scheduleFile(input, at: nil)
        player.scheduleBuffer(tail)
        try engine.start()
        defer { engine.stop() }
        try player.playAudio()
        let chunk = try buffer(format)
        let total = input.length + AVAudioFramePosition(maximumLag)
        var written: AVAudioFramePosition = 0
        var peakFrame: AVAudioFramePosition = 0
        var peakEnergy: Float = 0
        var retries = 0
        while written < total {
            try Task.checkCancellation()
            let status = try engine.renderOffline(AVAudioFrameCount(min(4096, total - written)), to: chunk)
            switch status {
            case .success where chunk.frameLength > 0:
                var energy: Float = 0
                vDSP_measqv(chunk.floatChannelData![0], 1, &energy, vDSP_Length(chunk.frameLength))
                if energy > peakEnergy { peakEnergy = energy; peakFrame = written }
                try output.write(from: chunk)
                written += AVAudioFramePosition(chunk.frameLength)
                retries = 0
                progress(Double(written) / Double(total))
            case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                retries += 1
                guard retries < 100 else { throw IsolationError.renderFailed }
            default: throw IsolationError.renderFailed
            }
        }
        return peakFrame
    }

    private static func samples(_ file: AVAudioFile, count: Int) throws -> [Float] {
        let chunk = try buffer(file.processingFormat)
        var result: [Float] = []
        result.reserveCapacity(count)
        while result.count < count {
            try file.read(into: chunk, frameCount: AVAudioFrameCount(min(4096, count - result.count)))
            guard chunk.frameLength > 0 else { throw IsolationError.invalidAudio }
            result.append(contentsOf: UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength)))
        }
        return result
    }

    private static func writeAligned(_ input: AVAudioFile, total: AVAudioFramePosition, format: AVAudioFormat,
                                     url: URL, progress: (Double) -> Void) throws {
        let output = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { output.close() }
        let chunk = try buffer(format)
        var written: AVAudioFramePosition = 0
        while written < total {
            try Task.checkCancellation()
            try input.read(into: chunk, frameCount: AVAudioFrameCount(min(4096, total - written)))
            guard chunk.frameLength > 0 else { throw IsolationError.invalidAudio }
            try output.write(from: chunk)
            written += AVAudioFramePosition(chunk.frameLength)
            progress(Double(written) / Double(total))
        }
    }
}
