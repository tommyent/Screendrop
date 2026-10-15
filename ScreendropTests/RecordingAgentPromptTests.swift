import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing

struct RecordingAgentPromptTests {
    private let cut = RecordingClipTimeline(segments: [
        .init(sourceStart: 0, sourceEnd: 2),
        .init(sourceStart: 4, sourceEnd: 8, speed: 2),
    ])

    @Test func cutsAndSpeedMapAllEvidenceWithoutLeakingRemovedSpeech() {
        let plan = RecordingAgentPromptPlan(title: "Fixture", timeline: cut, cues: [
            .init(start: 0, end: 1, text: "Corrected caption"),
            .init(start: 2, end: 4, text: "Removed secret"),
            .init(start: 4, end: 6, text: "Fast caption"),
        ], words: [
            .init(text: "Original", start: 0, end: 1),
            .init(text: "Removed secret", start: 2, end: 4),
            .init(text: "Fast", start: 4, end: 6),
        ], capture: PointerCaptureFile(presses: [
            .init(time: 2, x: 0.1, y: 0.2, button: 0, phase: .down),
            .init(time: 3, x: 0.1, y: 0.2, button: 0, phase: .down),
            .init(time: 5, x: 0.72, y: 0.28, button: 0, phase: .down),
            .init(time: 5.1, x: 0.72, y: 0.28, button: 0, phase: .up),
        ], keystrokes: [.init(time: 5.3, modifiers: ["⌘"], key: "E")]))
        #expect(plan.duration == 4)
        #expect(plan.transcript.map(\.text) == ["Corrected caption", "Fast caption"])
        #expect(plan.transcript[1].start == 2 && plan.transcript[1].end == 3)
        let markdown = plan.markdown(frameTimes: plan.moments.map(\.time))
        #expect(!markdown.contains("Removed secret"))
        #expect(markdown.contains("Click 00:02.500: left; source position x=0.720, y=0.280"))
        #expect(markdown.contains("Shortcut 00:02.650: ⌘E"))
        #expect(markdown.components(separatedBy: "Click 00:").count == 2)
        #expect(markdown.contains("Original recognizer wording"))
        #expect(plan.words.map(\.text) == ["Original", "Fast"])
    }

    @Test func partialCueKeepsCorrectedSurvivingWords() {
        let plan = RecordingAgentPromptPlan(title: "Fixture", timeline: cut,
            cues: [.init(start: 1, end: 5, text: "Fixed private finish")], words: [
                .init(text: "wrong ", start: 1, end: 2),
                .init(text: "secret ", start: 2, end: 4),
                .init(text: "finish", start: 4, end: 5),
            ], capture: nil)
        #expect(plan.transcript.map(\.text) == ["Fixed", "finish"])
        #expect(plan.transcript.map(\.start) == [1, 2])
        #expect(!plan.markdown(frameTimes: []).contains("private"))
    }

    @Test func partialCueWithoutReliableCorrectedTimingDoesNotDumpWholeCaption() {
        let plan = RecordingAgentPromptPlan(title: "Fixture", timeline: cut,
            cues: [.init(start: 1, end: 5, text: "Removed secret and surviving speech")], words: [], capture: nil)
        #expect(plan.transcript.count == 1)
        #expect(plan.transcript[0].text.contains("wording unavailable"))
        #expect(!plan.markdown(frameTimes: []).contains("Removed secret"))
    }

    @Test func groupingPreservesEveryActionAndDoesNotChainOrCapMoments() {
        let keys = (0..<200).map { RecordingKeystrokeEvent(time: Double($0), modifiers: ["⌘"], key: "K") }
        let plan = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 201), cues: [], words: [],
                                           capture: PointerCaptureFile(keystrokes: keys))
        #expect(plan.moments.count == 200)
        let close = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 2), cues: [], words: [],
            capture: PointerCaptureFile(keystrokes: [0.0, 0.4, 0.8].map { .init(time: $0, key: "⇥") }))
        #expect(close.moments.count == 2)
        #expect(close.moments[0].evidence.count == 2)
        #expect(close.moments[1].evidence.count == 1)
    }

    @Test func cueOnlySilentAndLiteralMarkdownRemainUsable() {
        let silent = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 1), cues: [], words: [], capture: nil)
        #expect(silent.moments.count == 1 && silent.moments[0].time == 0)
        #expect(silent.markdown(frameTimes: [0]).contains("No input log"))
        #expect(silent.markdown(frameTimes: [0]).contains("No narration available"))
        let plan = RecordingAgentPromptPlan(title: "Title\n# injected", timeline: .full(sourceDuration: 1),
            cues: [.init(start: 0, end: 0.5, text: "![link](file) <script> | **text**")], words: [], capture: nil)
        let markdown = plan.markdown(frameTimes: [0.025])
        #expect(markdown.contains("# Title \\# injected\n"))
        #expect(markdown.contains("\\!\\[link\\](file) &lt;script&gt; \\| \\*\\*text\\*\\*"))
        #expect(markdown.contains("![Frame at 00:00.025](stills/0001.jpg)"))
        #expect(!markdown.contains("## Word Timings"))
    }

    @Test func invalidEventsAndFinalBoundaryAreExcluded() {
        let capture = PointerCaptureFile(presses: [
            .init(time: .nan, x: 0, y: 0, button: 0, phase: .down),
            .init(time: 0, x: .infinity, y: 0, button: 0, phase: .down),
            .init(time: 1, x: 0, y: 0, button: 0, phase: .down),
        ])
        let plan = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 1), cues: [], words: [], capture: capture)
        #expect(plan.moments[0].evidence == ["No timed narration or actions available."])
    }

    @Test func extractedSchemasStillDecodeLegacyInputAndCueOnlyTranscripts() throws {
        let capture = try JSONDecoder().decode(PointerCaptureFile.self, from: Data(#"{"travel":[{"time":0,"x":0.5,"y":0.25}],"presses":[]}"#.utf8))
        #expect(capture.keystrokes.isEmpty && capture.artwork.isEmpty && !capture.isSanitized)
        #expect(capture.travel.first?.kind == .move)
        let decoded = try JSONDecoder().decode(PointerCaptureFile.self, from: JSONEncoder().encode(capture))
        #expect(decoded == capture)
        let cue = try JSONDecoder().decode(RecordingSubtitleCue.self, from: Data(#"{"start":0,"end":1,"text":"Legacy cue"}"#.utf8))
        #expect(cue.text == "Legacy cue")
    }

    @Test func generatedFolderContainsMatchingStillsAndPreservesPriorExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("fixture.mov")
        try await makeMovie(at: movie)
        let plan = RecordingAgentPromptPlan(title: "Fixture/path", timeline: .full(sourceDuration: 3),
            cues: [.init(start: 0, end: 0.5, text: "Red"), .init(start: 2, end: 2.5, text: "Blue")], words: [], capture: nil)
        let first = try await RecordingAgentPromptWriter.write(movie: movie, plan: plan, to: directory)
        let markdown = try String(contentsOf: first.appendingPathComponent("prompt.md"), encoding: .utf8)
        #expect(markdown.contains("stills/0001.jpg") && markdown.contains("stills/0002.jpg"))
        #expect(first.lastPathComponent == "Fixture-path Agent Prompt")
        let firstData = try Data(contentsOf: first.appendingPathComponent("stills/0001.jpg"))
        let lastData = try Data(contentsOf: first.appendingPathComponent("stills/0002.jpg"))
        #expect(firstData != lastData)
        let red = try sample(firstData), blue = try sample(lastData)
        #expect(red[0] > 200 && red[2] < 50)
        #expect(blue[2] > 200 && blue[0] < 50)
        let again = try await RecordingAgentPromptWriter.write(movie: movie, plan: plan, to: directory)
        #expect(again != first)
        #expect(try String(contentsOf: first.appendingPathComponent("prompt.md"), encoding: .utf8) == markdown)
        let invalid = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 99), cues: [], words: [], capture: nil)
        do { _ = try await RecordingAgentPromptWriter.write(movie: movie, plan: invalid, to: directory); Issue.record("Mismatched movie accepted") }
        catch RecordingAgentPromptWriter.ExportError.invalidMovie { }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".agent-prompt-") })
    }

    @Test func cancellationRemovesStagingAndKeepsExistingOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prior = directory.appendingPathComponent("prior.txt")
        try "keep".write(to: prior, atomically: true, encoding: .utf8)
        let movie = directory.appendingPathComponent("fixture.mov")
        try await makeMovie(at: movie)
        let plan = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 3),
            cues: [0.0, 0.6, 1.2, 1.8, 2.4].map { .init(start: $0, end: $0 + 0.1, text: "Frame") }, words: [], capture: nil)
        let (updates, continuation) = AsyncStream<Double>.makeStream()
        let task = Task { try await RecordingAgentPromptWriter.write(movie: movie, plan: plan, to: directory) { continuation.yield($0) } }
        var iterator = updates.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        do { _ = try await task.value; Issue.record("Canceled export completed") }
        catch is CancellationError { }
        continuation.finish()
        #expect(try String(contentsOf: prior, encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["fixture.mov", "prior.txt"])
    }

    private func sample(_ data: Data) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 96 && image.height == 64)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }

    private func makeMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 96, AVVideoHeightKey: 64,
        ])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: .init(rawValue: kCVPixelFormatType_32ARGB), size: .init(width: 96, height: 64))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            var pixels = try CVMutablePixelBuffer(attributes)
            try pixels.accessUnsafeMutableRawPlaneBytes { planes in
                let plane = try #require(planes.first)
                let context = try #require(CGContext(data: plane.bytes.baseAddress, width: 96, height: 64,
                    bitsPerComponent: 8, bytesPerRow: plane.properties.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
                context.setFillColor(frame < 10 ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(red: 0, green: 0, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            }
            try await receiver.append(CVReadOnlyPixelBuffer(pixels), with: CMTime(value: Int64(frame), timescale: 10))
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: 1))
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
