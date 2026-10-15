import AVFoundation
import Foundation
import Testing

struct RecordingVoiceIsolationTests {
    @Test(arguments: [0, 27, 4440, 12000])
    func measuresOutputLagAgainstNoisyInput(_ lag: Int) throws {
        var seed: UInt32 = 19
        let signal: [Float] = (0..<4096).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed) / Float(UInt32.max) - 0.5
        }
        let output = Array(repeating: Float.zero, count: lag) + signal.map { $0 * 0.35 }
            + Array(repeating: Float.zero, count: 12000 - lag)
        let input = signal.enumerated().map { $0.element + sin(Float($0.offset)) * 0.05 }
        #expect(RecordingAudioLag.measure(input: input, output: output, maximumLag: 12000) == lag)
    }

    @Test func silenceAndInvalidWindows() {
        #expect(RecordingAudioLag.measure(input: [0, 0], output: [0, 0, 0], maximumLag: 1) == 0)
        #expect(RecordingAudioLag.measure(input: [1, 2], output: [0, 0, 0], maximumLag: 1) == nil)
        #expect(RecordingAudioLag.measure(input: [], output: [], maximumLag: 0) == nil)
        #expect(RecordingAudioLag.measure(input: [1], output: [1], maximumLag: 1) == nil)
        #expect(RecordingAudioLag.measure(input: [.nan], output: [1], maximumLag: 0) == nil)
        #expect(RecordingAudioLag.measure(input: [1], output: [1], maximumLag: -1) == nil)
        #expect(RecordingAudioLag.measure(input: [1, -1], output: [-1, 1], maximumLag: 0) == nil)
    }

    @Test func swapsOnlyMicrophoneAndRecutsBothTracks() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let systemURL = try makeAudio(in: directory, name: "system", amplitude: 0.1)
        let micURL = try makeAudio(in: directory, name: "mic", amplitude: 0.2)
        let isolatedURL = try makeAudio(in: directory, name: "isolated", amplitude: 0.3)
        let systemAsset = AVURLAsset(url: systemURL)
        let micAsset = AVURLAsset(url: micURL)
        let isolatedAsset = AVURLAsset(url: isolatedURL)
        let system = try #require(try await systemAsset.loadTracks(withMediaType: .audio).first)
        let mic = try #require(try await micAsset.loadTracks(withMediaType: .audio).first)
        let isolated = try #require(try await isolatedAsset.loadTracks(withMediaType: .audio).first)
        let source = AVMutableComposition()
        let originalSystem = try #require(source.addMutableTrack(withMediaType: .audio, preferredTrackID: 10))
        let originalMic = try #require(source.addMutableTrack(withMediaType: .audio, preferredTrackID: 20))
        let fullRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 48000))
        try originalSystem.insertTimeRange(fullRange, of: system, at: .zero)
        try originalMic.insertTimeRange(fullRange, of: mic, at: .zero)
        #expect(RecordingVoiceIsolation.microphoneTrack(in: source.tracks, includesMicrophone: true, includesSystemAudio: true)?.trackID == 20)
        #expect(RecordingVoiceIsolation.microphoneTrack(in: source.tracks, includesMicrophone: false, includesSystemAudio: true) == nil)
        #expect(RecordingVoiceIsolation.microphoneTrack(in: source.tracks, includesMicrophone: true, includesSystemAudio: false) == nil)
        let timeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0.5, sourceEnd: 1, speed: 1),
            RecordingClipSegment(sourceStart: 2, sourceEnd: 3, speed: 2)
        ])
        let result = try RecordingCompositionBuilder.makeAsset(from: source, timeline: timeline,
            sourceDuration: 3, microphoneTrackID: 20, isolatedMicrophone: isolated)
        let tracks = try await result.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 2)
        for (id, url) in [(10, systemURL), (20, isolatedURL)] {
            let track = try #require(tracks.first { $0.trackID == id })
            let segments = try await track.load(.segments).compactMap { $0 as? AVCompositionTrackSegment }.filter { !$0.isEmpty }
            #expect(segments.count == 2)
            #expect(segments.allSatisfy { $0.sourceURL == url })
            #expect(abs(segments[0].timeMapping.source.start.seconds - 0.5) < 0.001)
            #expect(abs(segments[1].timeMapping.source.start.seconds - 2) < 0.001)
            #expect(abs(segments[1].timeMapping.target.start.seconds - 0.5) < 0.001)
            #expect(abs(segments[1].timeMapping.target.duration.seconds - 0.5) < 0.001)
        }
        let restored = try RecordingCompositionBuilder.makeAsset(from: source, timeline: .full(sourceDuration: 3), sourceDuration: 3)
        #expect(restored === source)
        let cutOriginal = try RecordingCompositionBuilder.makeAsset(from: source, timeline: timeline, sourceDuration: 3)
        let originalURLs = try await cutOriginal.loadTracks(withMediaType: .audio).flatMap { $0.segments.compactMap { ($0 as? AVCompositionTrackSegment)?.sourceURL } }
        #expect(originalURLs.contains(micURL))
        #expect(!originalURLs.contains(isolatedURL))
    }

    @Test(arguments: [0.25, 3.0])
    func offlineRenderKeepsOriginalAndReusesCompletedCache(_ sourceDuration: Double) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = try makeAudio(in: directory, name: "silent-mic", amplitude: 0, duration: sourceDuration)
        let original = try Data(contentsOf: sourceURL)
        let asset = AVURLAsset(url: sourceURL)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let destination = directory.appendingPathComponent(RecordingVoiceIsolation.fileName)
        try await RecordingVoiceIsolation.render(sourceURL: sourceURL, microphoneTrackID: track.trackID,
            destinationURL: destination, progress: { progress in
                if progress >= 0.2 && progress < 0.8 {
                    let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
                    #expect(files?.contains(where: { $0.hasSuffix(".caf") }) == false)
                }
            })
        let rendered = AVURLAsset(url: destination)
        let duration = try await rendered.load(.duration).seconds
        #expect(abs(duration - sourceDuration) < 0.025)
        let first = try Data(contentsOf: destination)
        let modified = try destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try await RecordingVoiceIsolation.render(sourceURL: sourceURL, microphoneTrackID: track.trackID,
            destinationURL: destination, progress: { _ in })
        #expect(try Data(contentsOf: sourceURL) == original)
        #expect(try Data(contentsOf: destination) == first)
        #expect(try destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".voice-") })
    }

    @Test func failedRenderLeavesOriginalAndNoCache() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = try makeAudio(in: directory, name: "mic", amplitude: 0)
        let original = try Data(contentsOf: sourceURL)
        let destination = directory.appendingPathComponent(RecordingVoiceIsolation.fileName)
        await #expect(throws: (any Error).self) {
            try await RecordingVoiceIsolation.render(sourceURL: sourceURL, microphoneTrackID: 9999,
                destinationURL: destination, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: sourceURL) == original)
    }

    @Test func canceledRenderDoesNotInstallOrLeavePartialFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = try makeAudio(in: directory, name: "mic", amplitude: 0)
        let asset = AVURLAsset(url: sourceURL)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let destination = directory.appendingPathComponent(RecordingVoiceIsolation.fileName)
        let task = Task {
            try await RecordingVoiceIsolation.render(sourceURL: sourceURL, microphoneTrackID: track.trackID,
                destinationURL: destination, progress: { _ in })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["mic.wav"])
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAudio(in directory: URL, name: String, amplitude: Float, duration: Double = 3) throws -> URL {
        let url = directory.appendingPathComponent(name).appendingPathExtension("wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 48000)))
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][frame] = amplitude * sin(Float(frame) * 0.05)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
        return url
    }
}
