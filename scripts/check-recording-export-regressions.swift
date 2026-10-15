import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

// Compiles actual app sources, without windows, speech recognition, or real recordings.
@main
struct RecordingExportRegressionChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }

    static func movie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: .init(rawValue: kCVPixelFormatType_32ARGB),
                                                       size: .init(width: 320, height: 180))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<80 {
            var pixels = try CVMutablePixelBuffer(attributes)
            try pixels.accessUnsafeMutableRawPlaneBytes { planes in
                guard let plane = planes.first,
                      let context = CGContext(data: plane.bytes.baseAddress, width: 320, height: 180,
                        bitsPerComponent: 8, bytesPerRow: plane.properties.bytesPerRow,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
                else { throw Failure(description: "Cannot create fixture pixels") }
                context.setFillColor(CGColor(gray: 0.4, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            }
            try await receiver.append(CVReadOnlyPixelBuffer(pixels), with: CMTime(value: Int64(frame), timescale: 10))
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: 8, timescale: 1))
        await writer.finishWriting()
        try check(writer.status == .completed, "Fixture encode failed: \(String(describing: writer.error))")
    }

    static func pixels(in url: URL, at time: Double) async throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw Failure(description: "Cannot decode rendered pixels") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    static func difference(_ lhs: [UInt8], _ rhs: [UInt8]) throws -> Int {
        try check(lhs.count == rhs.count, "Render dimensions differ")
        return zip(lhs, rhs).count { abs(Int($0.0) - Int($0.1)) > 20 }
    }

    static func captionPixels(in directory: URL) async throws {
        let session = RecordingSession(directoryURL: directory.appendingPathComponent("fixture.screendroprec"))
        try FileManager.default.createDirectory(at: session.directoryURL, withIntermediateDirectories: false)
        try await movie(at: session.screenURL)
        let cut = RecordingClipTimeline(segments: [.init(sourceStart: 0, sourceEnd: 2), .init(sourceStart: 4, sourceEnd: 8)])
        let words: [RecordingTranscriptWord] = [
            .init(text: "wrong ", start: 1, end: 2), .init(text: "secret ", start: 2, end: 4),
            .init(text: "finish", start: 4, end: 5),
        ]
        var style = RecordingStudioStyle()
        style.padding = 0
        style.cornerRadius = 0
        style.shadow = 0
        var settings = VideoCompressionSettings()
        settings.removeAudio = true
        settings.frameRate = .fps30
        settings.motionBlurEnabled = false
        var document = RecordingEditDocument(style: style, zoomEnabled: false, zoomCues: [], clipTimeline: cut,
            exportSettings: settings, subtitleCues: [.init(start: 1, end: 5, text: "Fixed private finish")], subtitleWords: words)

        for karaoke in [false, true] {
            document.subtitleWordHighlight = karaoke
            try session.writeEditDocument(document)
            let configuration = try await RecordingSessionRenderer.makeConfiguration(for: session)
            try check(configuration.subtitleTimeline?.text(at: 1) == "Fixed finish", "Cut wording reached subtitle renderer")
            try check(configuration.karaokeTimeline?.line(at: 1)?.words == ["Fixed", "finish"], "Cut wording reached karaoke renderer")
            let actual = try await RecordingSessionRenderer.ensureDeliverable(for: session, editDocument: document)
            let first = try await pixels(in: actual, at: 1)
            let last = try await pixels(in: actual, at: 2)

            var safe = document
            safe.subtitleCues = [.init(start: 1, end: 5, text: "Fixed finish")]
            safe.subtitleWords = [words[0], words[2]]
            let expected = try await RecordingSessionRenderer.ensureDeliverable(for: session, editDocument: safe)
            let firstExpected = try await pixels(in: expected, at: 1)
            let lastExpected = try await pixels(in: expected, at: 2)
            let firstDifference = try difference(first, firstExpected)
            let lastDifference = try difference(last, lastExpected)
            try check(firstDifference < 20 && lastDifference < 20, "Cut caption pixels differ from safe reference: \(firstDifference), \(lastDifference)")

            var uncut = document
            uncut.clips = RecordingClipTimeline.full(sourceDuration: 8).segments
            let leaking = try await RecordingSessionRenderer.ensureDeliverable(for: session, editDocument: uncut)
            let leaked = try await pixels(in: leaking, at: 1)
            let leakedDifference = try difference(first, leaked)
            try check(leakedDifference > 100, "Pixel check cannot distinguish the removed word: \(leakedDifference)")
            print("PASS: \(karaoke ? "karaoke" : "plain") cut-caption pixels match safe wording; differences \(firstDifference)/\(lastDifference), removed-word control \(leakedDifference)")
        }

        // A pre-fix stamp naming the identical edit must force a fresh render.
        try Data("old cached movie".utf8).write(to: session.finalURL)
        let encoded = try CaptureManifest.encoder.encode(document)
        var old: [String: Any] = ["layoutVersion": 2]
        old["document"] = try JSONSerialization.jsonObject(with: encoded)
        try JSONSerialization.data(withJSONObject: old).write(to: session.renderStampURL)
        try check(session.freshFinalURL(matching: document) == nil, "Pre-fix render cache was reused")
        let refreshed = try await RecordingSessionRenderer.ensureDeliverable(for: session, editDocument: document)
        _ = try await pixels(in: refreshed, at: 1)
        try check(session.freshFinalURL(matching: document) == refreshed, "Fresh render was not reusable")
        print("PASS: version-2 cache rejected, re-rendered, and version-3 cache reused")
    }

    final class Gate {
        var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation = $0 }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            try check(ContinuousClock.now < deadline, "Timed out waiting for export state")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    static func cancelRetry(in directory: URL) async throws {
        let model = RecordingStudioModel(url: directory.appendingPathComponent("unloaded.mov"))
        defer { model.teardown() }
        let first = Gate(), retry = Gate()
        var starts = 0
        model.startExportTask {
            starts += 1
            await first.wait()
            model.exportState = Task.isCancelled ? .idle : .finished(directory)
        }
        try await until { first.continuation != nil }
        model.cancelExport()
        model.cancelExport()
        try check(model.exportState.isExporting && model.hasRunningWork, "Cancel cleared busy state before the task exited")
        model.startExportTask { starts += 1 }
        await Task.yield()
        try check(starts == 1 && model.exportState.isExporting && model.hasRunningWork, "Retry started while canceled export was suspended")
        first.resume()
        try await until { !model.hasRunningWork }
        if case .idle = model.exportState { } else { throw Failure(description: "Canceled export did not return to idle") }

        model.startExportTask {
            starts += 1
            await retry.wait()
            model.exportState = .finished(directory)
        }
        try await until { retry.continuation != nil }
        await Task.yield()
        try check(starts == 2 && model.exportState.isExporting && model.hasRunningWork, "Completed cancellation cleared the retry's state")
        retry.resume()
        try await until { !model.hasRunningWork }
        if case .finished = model.exportState { } else { throw Failure(description: "Retry did not complete") }
        print("PASS: canceled model task stays busy, blocks retry until exit, and releases the task for a successful retry")
    }

    static func audioTone(at url: URL, frequency: Float) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 384000)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][index] = 0.15 * sin(2 * .pi * frequency * Float(index) / 48000)
        }
        let settings = url.pathExtension == "m4a"
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1] as [String: Any]
            : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        file.close()
    }

    static func audioLevels(at url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: 0.2, preferredTimescale: 48000),
                                      duration: CMTime(seconds: 0.5, preferredTimescale: 48000))
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        var samples: [Float] = []
        while let ready = try await provider.next() {
            try ready.withUnsafeSampleBuffer { sample in
                guard let data = CMSampleBufferGetDataBuffer(sample) else { throw Failure(description: "Missing test audio") }
                var chunk = [Float](repeating: 0, count: CMSampleBufferGetNumSamples(sample))
                let result = chunk.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                try check(result == noErr, "Cannot decode test audio")
                samples += chunk
            }
        }
        try check(!samples.isEmpty, "Export has no audible samples")
        return [220, 440, 900].map { frequency in
            var real: Float = 0, imaginary: Float = 0
            for (index, sample) in samples.enumerated() {
                let phase = 2 * Float.pi * Float(frequency) * Float(index) / 48000
                real += sample * cos(phase); imaginary += sample * sin(phase)
            }
            return 2 * sqrt(real * real + imaginary * imaginary) / Float(samples.count)
        }
    }

    static func voiceIsolation(in directory: URL) async throws {
        let session = RecordingSession(directoryURL: directory.appendingPathComponent("voice.screendroprec"))
        try FileManager.default.createDirectory(at: session.directoryURL, withIntermediateDirectories: false)
        let videoURL = directory.appendingPathComponent("voice-video.mov")
        let systemURL = directory.appendingPathComponent("system.wav")
        let micURL = directory.appendingPathComponent("microphone.wav")
        let isolatedURL = session.directoryURL.appendingPathComponent(RecordingVoiceIsolation.fileName)
        try await movie(at: videoURL)
        try audioTone(at: systemURL, frequency: 900)
        try audioTone(at: micURL, frequency: 220)
        try audioTone(at: isolatedURL, frequency: 440)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let systemAsset = AVURLAsset(url: systemURL)
        let micAsset = AVURLAsset(url: micURL)
        for asset in [videoAsset, systemAsset, micAsset] {
            for track in try await asset.load(.tracks) {
                let destination = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try destination.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 8, timescale: 1)), of: track, at: .zero)
            }
        }
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await export.export(to: session.screenURL, as: .mov)
        let sourceBytes = try Data(contentsOf: session.screenURL)
        var manifest = CaptureManifest()
        manifest.duration = 8; manifest.pixelWidth = 320; manifest.pixelHeight = 180
        manifest.includesSystemAudio = true; manifest.includesMicrophone = true
        try session.writeCaptureManifest(manifest)
        var style = RecordingStudioStyle()
        style.padding = 0; style.shadow = 0; style.cornerRadius = 0
        let cut = RecordingClipTimeline(segments: [.init(sourceStart: 0.5, sourceEnd: 1.5), .init(sourceStart: 4, sourceEnd: 6, speed: 2)])
        var document = RecordingEditDocument(style: style, zoomEnabled: false, zoomCues: [], clipTimeline: cut, isolateVoice: true)
        let data = try CaptureManifest.encoder.encode(document)
        try check(try CaptureManifest.decoder.decode(RecordingEditDocument.self, from: data).isolateVoice, "Voice choice was not persisted")
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "isolateVoice")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        try check(try !CaptureManifest.decoder.decode(RecordingEditDocument.self, from: legacyData).isolateVoice, "Old edits enabled voice isolation")
        try session.writeEditDocument(document)
        let configuration = try await RecordingSessionRenderer.makeConfiguration(for: session)
        try check(configuration.isolatedMicrophoneURL == isolatedURL && configuration.microphoneTrackID != nil, "Shared export missed isolated microphone")
        let movie = try await RecordingStudioExporter().export(configuration, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: movie) }
        let audio = try await RecordingAudioExporter().export(.init(screenURL: session.screenURL, clipTimeline: cut,
            replacementURL: nil, format: .wav, isolatedMicrophoneURL: isolatedURL,
            microphoneTrackID: configuration.microphoneTrackID), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: audio) }
        for url in [movie, audio] {
            let levels = try await audioLevels(at: url)
            try check(levels[0] < 0.01 && levels[1] > 0.1 && levels[2] > 0.1,
                      "Export mixed wrong microphone or removed system audio: \(levels)")
        }
        let model = RecordingStudioModel(url: session.directoryURL)
        await model.load()
        try check(model.isolateVoice && model.voiceIsolationError == nil, "Studio did not restore isolated voice")
        model.isolateVoice = false
        try check(!model.currentDocument().isolateVoice, "Studio off did not persist")
        model.isolateVoice = true
        try check(model.voiceIsolationProgress != nil && model.hasRunningWork, "Studio did not expose render progress")
        model.isolateVoice = false
        try await until { !model.hasRunningWork }
        try check(!model.isolateVoice && model.voiceIsolationProgress == nil, "Canceled render restored a stale selection")
        model.isolateVoice = true
        try await until { !model.hasRunningWork }
        try check(model.isolateVoice && model.voiceIsolationError == nil, "Studio could not reuse isolated track: \(String(describing: model.voiceIsolationError))")
        model.teardown()
        session.removeDraftDocument()
        document.isolateVoice = false
        try session.writeEditDocument(document)
        let restored = try await RecordingSessionRenderer.makeConfiguration(for: session)
        try check(restored.isolatedMicrophoneURL == nil, "Off did not restore source microphone")
        let firstUse = RecordingStudioModel(url: session.directoryURL)
        await firstUse.load()
        firstUse.isolateVoice = true
        try check(firstUse.isIsolatingVoice && !firstUse.currentDocument().isolateVoice,
                  "An unfinished isolation request reached the edit document")
        firstUse.flushDraft()
        try check(session.effectiveEditDocument()?.isolateVoice == false, "Draft flush persisted unfinished isolation")
        try await until { !firstUse.hasRunningWork }
        try check(firstUse.currentDocument().isolateVoice, "Completed isolation was not persistable")
        firstUse.teardown()
        try check(try Data(contentsOf: session.screenURL) == sourceBytes, "Isolation modified the original recording")
        let broken = RecordingSession(directoryURL: directory.appendingPathComponent("missing-mic.screendroprec"))
        try FileManager.default.createDirectory(at: broken.directoryURL, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: videoURL, to: broken.screenURL)
        try broken.writeCaptureManifest(manifest)
        document.isolateVoice = true
        try broken.writeEditDocument(document)
        let failedModel = RecordingStudioModel(url: broken.directoryURL)
        await failedModel.load()
        try check(!failedModel.isolateVoice && failedModel.voiceIsolationError?.contains("original microphone audio") == true,
                  "Render failure did not return to original audio with an explanation")
        failedModel.flushDraft()
        try check(broken.effectiveEditDocument()?.isolateVoice == false, "Failed render left the saved on-choice active for other exports")
        failedModel.teardown()
        print("PASS: voice choice round-trip and legacy off; shared video and audio exports use isolated mic plus system audio through cuts; Studio progress/cancel/cache/off and failure fallback")
    }

    static func main() async throws {
        guard let root = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            throw Failure(description: "Run through check-recording-export-regressions.py")
        }
        let directory = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
        let support = ScreendropStorage.applicationSupportDirectory.resolvingSymlinksInPath().path
        try check(home == directory && support.hasPrefix(directory.path + "/"), "Foundation storage escaped isolated home")
        try await voiceIsolation(in: directory)
        try await cancelRetry(in: directory)
        try await captionPixels(in: directory)
    }
}
