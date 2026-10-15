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

    static func main() async throws {
        guard let root = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            throw Failure(description: "Run through check-recording-export-regressions.py")
        }
        let directory = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
        let support = ScreendropStorage.applicationSupportDirectory.resolvingSymlinksInPath().path
        try check(home == directory && support.hasPrefix(directory.path + "/"), "Foundation storage escaped isolated home")
        try await cancelRetry(in: directory)
        try await captionPixels(in: directory)
    }
}
