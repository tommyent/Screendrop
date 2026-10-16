import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Darwin

// Compiles actual app sources, without windows, speech recognition, or real recordings.
@main
struct RecordingExportRegressionChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }

    static func movie(at url: URL, colorAt: (Double) -> CGColor = { _ in CGColor(gray: 0.4, alpha: 1) }) async throws {
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
                context.setFillColor(colorAt(Double(frame) / 10))
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

    static func chapterRenameUndo(in directory: URL) async throws {
        let session = RecordingSession(directoryURL: directory.appendingPathComponent("chapter.screendroprec"))
        try FileManager.default.createDirectory(at: session.directoryURL, withIntermediateDirectories: false)
        try await movie(at: session.screenURL)
        let chapter = RecordingChapter(title: "Chapter 1", start: 0)

        for synchronize in [false, true] {
            try session.updateProjectMetadata { $0.chapters = [chapter] }
            let model = RecordingStudioModel(url: session.directoryURL)
            defer { model.teardown() }
            await model.load()
            try check(model.isLoaded && model.chapters == [chapter], "Chapter fixture did not load")
            var draft = StudioChapterNameDraft(text: "Masked section")
            draft.commit(model: model, chapter: chapter) // Return
            try check(model.chapterError == nil && draft.text == nil, "Return did not commit the rename")
            try check(session.loadProjectMetadata()?.chapters?.first?.title == "Masked section", "Rename was not saved")

            // Recreate the stale field value seen in VM check 5 after Return.
            draft.text = "Masked section"
            model.undo()
            try check(model.chapters == [chapter] && session.loadProjectMetadata()?.chapters == [chapter], "One Undo did not restore Chapter 1")
            if synchronize { draft.storedTitleChanged() } // The field's chapter.title onChange
            try check((draft.text ?? model.chapters[0].title) == (synchronize ? "Chapter 1" : "Masked section"), "Field did not follow the stored title")
            let undone = try Data(contentsOf: session.projectMetadataURL)
            draft.commit(model: model, chapter: model.chapters[0]) // Focus loss without typing

            if !synchronize {
                try check(session.loadProjectMetadata()?.chapters?.first?.title == "Masked section" && !model.canRedo, "Control did not reproduce the lost Undo")
                print("PASS: control without title synchronization reproduces stale field/focus-loss overwrite")
                continue
            }
            try check(model.chapters == [chapter] && Data(contentsOf: session.projectMetadataURL) == undone,
                      "Focus loss overwrote the undone title")
            try check(!model.canUndo && model.canRedo, "Focus loss added an undo step or discarded Redo")
            print("PASS: rename -> Return -> one Undo -> focus loss keeps Chapter 1 in field/model/project.json; no extra commit")

            draft.text = "Uncommitted edit"
            model.redo()
            draft.storedTitleChanged()
            try check(draft.text == nil && model.chapters[0].title == "Masked section", "Redo did not replace the field draft")
            let redone = try Data(contentsOf: session.projectMetadataURL)
            draft.commit(model: model, chapter: model.chapters[0])
            try check(Data(contentsOf: session.projectMetadataURL) == redone, "Focus loss overwrote Redo")
            draft.text = "Fresh edit after Redo"
            draft.commit(model: model, chapter: model.chapters[0])
            try check(session.loadProjectMetadata()?.chapters?.first?.title == "Fresh edit after Redo", "Fresh user editing no longer commits")
            print("PASS: Redo drops a pending draft; focus loss writes nothing; a fresh user edit still commits")
        }
    }

    static func unchangedRenderReuse(in directory: URL) async throws {
        let session = RecordingSession(directoryURL: directory.appendingPathComponent("reuse.screendroprec"))
        try FileManager.default.createDirectory(at: session.directoryURL, withIntermediateDirectories: false)
        try await movie(at: session.screenURL)
        func installStopRender() throws { // An unedited recording's render is stamped with no document.
            try Data("stop-time render".utf8).write(to: session.finalURL)
            session.writeRenderStamp(nil)
        }
        try installStopRender()

        let model = RecordingStudioModel(url: session.directoryURL)
        await model.load()
        try check(model.isLoaded, "Unedited fixture did not load")
        try check(session.freshFinalURL(matching: model.currentDocument()) == nil, "Control: the in-memory baseline matched the render")
        model.flushDraft() // Quick Look, Copy and Share flush every open project
        try check(session.freshFinalURL(matching: nil) == session.finalURL, "Flushing an unedited project dropped its render")
        model.teardown() // Closing Studio
        try check(session.freshFinalURL(matching: nil) == session.finalURL && !session.hasSavedProject
                  && !FileManager.default.fileExists(atPath: session.draftDocumentURL.path), "Closing Studio dropped the render or saved edits")

        let edited = RecordingStudioModel(url: session.directoryURL)
        defer { edited.teardown() }
        await edited.load()
        edited.zoomEnabled.toggle()
        edited.flushDraft()
        try check(session.existingFinalURL == nil, "An edited draft kept the stale render")
        try installStopRender()
        try check(edited.saveProject(reportingFailure: false) && session.existingFinalURL == nil, "A saved edit kept the stale render")
        print("PASS: an unedited recording keeps its Stop-time render through flush and close (control: baseline never matches it); drafts and saves with edits still drop it")
    }

    static func quickLookInstant(in directory: URL) async throws {
        let session = RecordingSession(directoryURL: directory.appendingPathComponent("quicklook.screendroprec"))
        try FileManager.default.createDirectory(at: session.directoryURL, withIntermediateDirectories: false)
        try await movie(at: session.screenURL)
        func shown(_ url: URL) -> URL? { QuickLookPreviewPresenter.immediateURL(for: url) }
        let still = directory.appendingPathComponent("still.png")
        try check(shown(still) == still, "A file outside a recording package was not shown as is")
        try check(shown(session.screenURL) == session.screenURL, "An unrendered recording waited for a render")

        try Data("render".utf8).write(to: session.finalURL)
        session.writeRenderStamp(nil)
        try check(shown(session.screenURL) == session.finalURL, "A fresh render was not shown")

        let redactions = [RecordingRedaction(start: 0, end: 8, rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3), mode: .pixelate)]
        let document = RecordingEditDocument(style: RecordingStudioStyle(), zoomEnabled: false, zoomCues: [], redactions: redactions)
        try session.writeDraftDocument(document)
        try check(shown(session.finalURL) == nil, "A pending redaction previewed the master or a stale render")
        session.writeRenderStamp(document)
        try check(shown(session.screenURL) == session.finalURL, "A fresh redacted render was not shown")

        session.removeDraftDocument()
        try Data("not json".utf8).write(to: session.editDocumentURL)
        try check(shown(session.screenURL) == nil, "Unreadable edits skipped the render")
        print("PASS: Quick Look shows a fresh render or the master at once; pending redactions and unreadable edits still render first")
    }

    static func chapterAtPlayhead(in directory: URL) async throws {
        let session = RecordingSession(directoryURL: directory.appendingPathComponent("chapter-at-playhead.screendroprec"))
        try FileManager.default.createDirectory(at: session.directoryURL, withIntermediateDirectories: false)
        try await movie(at: session.screenURL)
        let legacy = RecordingChapter(title: "Chapter 7", start: 0)
        let closing = RecordingChapter(title: "Closing", start: 7)
        try session.updateProjectMetadata { $0.chapters = [legacy, closing] }
        let cue = RecordingSubtitleCue(start: 4, end: 5, text: "Corrected opening! More detail.")
        let timeline = RecordingClipTimeline(segments: [.init(sourceStart: 0, sourceEnd: 2, speed: 2), .init(sourceStart: 4, sourceEnd: 8)])
        try session.writeEditDocument(RecordingEditDocument(
            style: RecordingStudioStyle(), zoomEnabled: false, zoomCues: [], clipTimeline: timeline,
            subtitleCues: [.init(start: 2, end: 4, text: "Removed narration."), cue,
                           .init(start: 7, end: 8, text: "Later narration.")]
        ))
        let model = RecordingStudioModel(url: session.directoryURL)
        defer { model.teardown() }
        await model.load()
        try check(model.isLoaded, "Add-at-playhead fixture did not load")
        model.currentTime = 1
        model.addChapterAtPlayhead()
        let added = model.chapters.last!
        try check(added.start == 4 && added.title == "Corrected opening" && added.autoTitle == true,
                  "Add at Playhead did not store the surviving corrected title at its source anchor")
        try check(session.loadProjectMetadata()?.chapters == model.chapters, "Automatic chapter was not persisted")
        model.addChapterAtPlayhead()
        try check(model.chapters.count == 3, "Duplicate playhead chapter was added")
        model.undo()
        try check(model.chapters == [legacy, closing], "Undo Add Chapter failed")
        model.redo()
        try check(model.chapters.last == added && session.loadProjectMetadata()?.chapters == model.chapters, "Redo Add Chapter was not persisted")
        model.updateSubtitleText(id: cue.id, text: "Updated narration.")
        try check(model.visibleChapters.first(where: { $0.id == added.id })?.title == "Updated narration", "Automatic chapter did not follow transcript edits")
        try check(model.visibleChapters.first?.title == "Chapter 7", "A legacy numbered chapter was renamed")
        model.renameChapter(id: added.id, title: "My title")
        model.updateSubtitleText(id: cue.id, text: "Another edit.")
        try check(model.visibleChapters.first(where: { $0.id == added.id })?.title == "My title"
                  && session.loadProjectMetadata()?.chapters?.last?.autoTitle == false, "Manual rename did not stop automatic titles")
        model.currentTime = 3
        model.addChapterAtPlayhead()
        try check(model.chapters.last?.title == "Chapter 3" && model.chapters.last?.autoTitle == true,
                  "Silence before the next chapter did not use a numbered automatic fallback")
        try check(model.saveProject(reportingFailure: false), "Chapter fixture save failed")
        model.teardown()
        let reopened = RecordingStudioModel(url: session.directoryURL)
        defer { reopened.teardown() }
        await reopened.load()
        try check(reopened.chapters == model.chapters && reopened.visibleChapters.map(\.title) == ["Chapter 7", "My title", "Chapter 3", "Closing"],
                  "Reopening did not preserve chapter names and automatic flags")
        print("PASS: Add at Playhead uses surviving corrected narration/source time, follows transcript edits until renamed, preserves legacy titles, bounds silence by the next chapter, persists and supports Undo/Redo")
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

    static func audioTone(at url: URL, frequency: Float, active: (Double) -> Bool = { _ in true }) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 384000)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][index] = active(Double(index) / 48000) ? 0.15 * sin(2 * .pi * frequency * Float(index) / 48000) : 0
        }
        let settings = url.pathExtension == "m4a"
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1] as [String: Any]
            : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        file.close()
    }

    static func audioLevels(at url: URL, time: Double = 0.2, length: Double = 0.5,
                            frequencies: [Float] = [220, 440, 900]) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: time, preferredTimescale: 48000),
                                      duration: CMTime(seconds: length, preferredTimescale: 48000))
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
        return frequencies.map { frequency in
            var real: Float = 0, imaginary: Float = 0
            for (index, sample) in samples.enumerated() {
                let phase = 2 * Float.pi * Float(frequency) * Float(index) / 48000
                real += sample * cos(phase); imaginary += sample * sin(phase)
            }
            return 2 * sqrt(real * real + imaginary * imaginary) / Float(samples.count)
        }
    }

    static func musicDelivery(in directory: URL) async throws {
        print("CHECK: preparing mic/camera/MP3 delivery fixture")
        let session = RecordingSession(directoryURL: directory.appendingPathComponent("music-delivery.screendroprec"))
        try FileManager.default.createDirectory(at: session.directoryURL, withIntermediateDirectories: false)
        let video = directory.appendingPathComponent("delivery-screen.mov")
        let mic = directory.appendingPathComponent("delivery-mic.wav")
        try await movie(at: video)
        try await movie(at: session.cameraURL, colorAt: { _ in CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1) })
        print("CHECK: screen and camera fixtures encoded")
        try audioTone(at: mic, frequency: 220, active: { (1...2).contains($0) })
        let composition = AVMutableComposition()
        for url in [video, mic] {
            let asset = AVURLAsset(url: url)
            for track in try await asset.load(.tracks) {
                let destination = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try destination.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 8, timescale: 1)), of: track, at: .zero)
            }
        }
        try await AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!.export(to: session.screenURL, as: .mov)
        print("CHECK: mic-only screen master muxed")
        var manifest = CaptureManifest()
        manifest.duration = 8; manifest.pixelWidth = 320; manifest.pixelHeight = 180
        manifest.includesMicrophone = true; manifest.cameraWidth = 320; manifest.cameraHeight = 180
        try session.writeCaptureManifest(manifest)
        var settings = VideoCompressionSettings()
        settings.container = .mp4; settings.codec = .h264; settings.resolution = .p720
        settings.frameRate = .fps30; settings.motionBlurEnabled = false; settings.exportsGIF = false
        let document = RecordingEditDocument(style: RecordingStudioStyle(), zoomEnabled: false, zoomCues: [],
            clipTimeline: .init(segments: [.init(sourceStart: 0, sourceEnd: 3)]), exportSettings: settings)
        try session.writeEditDocument(document)
        let model = RecordingStudioModel(url: session.directoryURL)
        defer { model.teardown() }
        await model.load()
        print("CHECK: Studio model loaded, error=\(model.loadError ?? "none")")
        let mp3 = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ScreendropTests/Fixtures/music-660-stereo.mp3")
        model.setBackgroundMusic(fileURL: mp3, displayName: "Stereo MP3 tone", credit: nil, startOffset: 0)
        try await until { !model.hasRunningWork }
        try check(model.hasCameraVideo && model.backgroundMusic != nil && model.backgroundMusicError == nil,
            "MP3/mic/camera fixture did not load")
        model.flushDraft()
        print("CHECK: MP3 imported and Studio draft flushed")
        var failures: [String] = []
        func verify(_ url: URL, _ label: String, expectsMusic: Bool = true) async throws {
            let levels = try await audioLevels(at: url, time: 0.2, length: 0.2, frequencies: [660])
            let present = levels[0] > 0.025
            print("\(present == expectsMusic ? "PASS" : "FAIL"): \(label), music amplitude=\(levels[0])")
            if present != expectsMusic { failures.append(label) }
            let underVoice = try await audioLevels(at: url, time: 1.3, length: 0.2, frequencies: [220, 660])
            try check(underVoice[0] > 0.1, "\(label) lost the microphone")
            if expectsMusic, present {
                try check(underVoice[1] > 0.004 && underVoice[1] < levels[0] * 0.4, "\(label) lost MP3 ducking")
            }
            let frame = try await pixels(in: url, at: 0.2)
            let cameraPixels = stride(from: 0, to: frame.count, by: 4).filter {
                frame[$0] > 100 && Int(frame[$0]) > Int(frame[$0 + 1]) * 2 && Int(frame[$0]) > Int(frame[$0 + 2]) * 2
            }.count
            try check(cameraPixels > 1000, "\(label) lost the camera bubble")
        }
        do {
            let fresh = try await RecordingStudioExporter().export(model.makeExportConfiguration(), progress: { _ in })
            defer { try? FileManager.default.removeItem(at: fresh) }
            try await verify(fresh, "fresh Studio-model MP4 720p with mic, camera and stereo MP3")
        } catch {
            print("FAIL: fresh Studio-model MP4 threw \(error)")
            failures.append("fresh Studio-model MP4 render error")
        }
        do {
            let upload = try await RecordingSessionRenderer.ensureDeliverable(for: session)
            try await verify(upload, "fresh upload-path movie with MP3 from the Studio draft")
        } catch {
            print("FAIL: fresh upload-path movie threw \(error)")
            failures.append("fresh upload-path render error")
        }
        session.removeFinalVideos()
        model.exportSettings.exportsGIF = true
        model.flushDraft()
        let gifDocument = model.currentDocument()
        let gifMovie = try await RecordingStudioExporter().export(model.makeExportConfiguration(), progress: { _ in })
        try await verify(gifMovie, "GIF intermediate deliberately omits music", expectsMusic: false)
        try session.installFinalVideo(movingFrom: gifMovie, renderedFrom: gifDocument)
        model.exportSettings.exportsGIF = false
        try check(!RecordingSession.differsOnlyByExportContainer(gifDocument, model.currentDocument()),
            "GIF and movie settings were treated as identical media")
        let cached = model.freshDeliverableURL()
        let movie = if let cached { cached } else {
            try await RecordingStudioExporter().export(model.makeExportConfiguration(), progress: { _ in })
        }
        defer { if cached == nil { try? FileManager.default.removeItem(at: movie) } }
        let saved = directory.appendingPathComponent("studio-gif-to-mp4.mp4")
        try await VideoFileActions.save(from: movie, to: saved)
        try await verify(saved, "Studio-model MP4 after a cached GIF intermediate")
        model.flushDraft()
        let afterGIF = try await RecordingSessionRenderer.ensureDeliverable(for: session)
        try await verify(afterGIF, "upload-path MP4 after a cached GIF intermediate")
        session.removeFinalVideos()
        model.exportSettings.exportsGIF = true
        model.flushDraft()
        let withGIFPreference = try await RecordingSessionRenderer.ensureDeliverable(for: session)
        try await verify(withGIFPreference, "upload movie while GIF export preference is on")
        try check(model.exportSettings.effectiveExportsGIF, "Movie delivery changed the user's GIF export preference")
        try check(session.loadRenderStamp()?.exportSettings?.effectiveExportsGIF == false,
            "Movie delivery cached the wrong render identity")
        model.flushDraft()
        try check(session.freshFinalURL(matching: model.currentDocument()) != nil,
            "Draft flushing invalidated the correct movie render")
        try check(model.freshDeliverableURL(forGIFExport: true) == nil,
            "GIF export reused the music-bearing movie render")
        let sharedConfiguration = try model.makeExportConfiguration(settings: model.currentDocument().forVideoRendering.exportSettings)
        let studioShare = try await RecordingStudioExporter().export(sharedConfiguration, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: studioShare) }
        try await verify(studioShare, "Studio upload configuration while GIF export preference is on")
        var remux = model.currentDocument().forVideoRendering
        remux.exportSettings?.container = .mov
        try check(RecordingSession.differsOnlyByExportContainer(remux, session.loadRenderStamp()),
            "Container-only reuse stopped working")
        try check(failures.isEmpty, "Music delivery failures: \(failures.joined(separator: "; "))")
    }

    static func backgroundMusicMixing(in directory: URL) async throws {
        func tone(_ url: URL, frequency: Float, duration: Double = 8, active: (Double) -> Bool = { _ in true }) throws {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(duration * 48000))!
            buffer.frameLength = buffer.frameCapacity
            for frame in 0..<Int(buffer.frameLength) {
                let time = Double(frame) / 48000
                buffer.floatChannelData![0][frame] = active(time) ? 0.15 * sin(2 * .pi * frequency * Float(time)) : 0
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            file.close()
        }
        func level(_ url: URL, at time: Double, frequency: Float) async throws -> Float {
            try await audioLevels(at: url, time: time, length: 0.12, frequencies: [frequency])[0]
        }
        let session = RecordingSession(directoryURL: directory.appendingPathComponent("music-mix.screendroprec"))
        try FileManager.default.createDirectory(at: session.directoryURL, withIntermediateDirectories: false)
        let videoURL = directory.appendingPathComponent("music-video.mov")
        let micURL = directory.appendingPathComponent("music-mic.wav")
        let systemURL = directory.appendingPathComponent("music-system.wav")
        let musicURL = directory.appendingPathComponent("music.wav")
        let isolatedURL = directory.appendingPathComponent("music-isolated.wav")
        try await movie(at: videoURL)
        try tone(micURL, frequency: 220, active: { (1...2).contains($0) || (4...5).contains($0) })
        try tone(systemURL, frequency: 900)
        try tone(isolatedURL, frequency: 440)
        try tone(musicURL, frequency: 660, duration: 3, active: { $0 >= 1 })
        let composition = AVMutableComposition()
        for url in [videoURL, systemURL, micURL] {
            let asset = AVURLAsset(url: url)
            for track in try await asset.load(.tracks) {
                let destination = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try destination.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 8, timescale: 1)), of: track, at: .zero)
            }
        }
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await exporter.export(to: session.screenURL, as: .mov)
        let original = try Data(contentsOf: session.screenURL)
        var manifest = CaptureManifest()
        manifest.duration = 8; manifest.pixelWidth = 320; manifest.pixelHeight = 180
        manifest.includesMicrophone = true; manifest.includesSystemAudio = true
        try session.writeCaptureManifest(manifest)
        let cut = RecordingClipTimeline(segments: [.init(sourceStart: 0.5, sourceEnd: 3), .init(sourceStart: 4, sourceEnd: 8, speed: 2)])
        let model = RecordingStudioModel(url: session.directoryURL)
        defer { model.teardown() }
        await model.load()
        model.setBackgroundMusic(fileURL: musicURL, displayName: "Tone music", credit: "Test credit", startOffset: 1)
        for _ in 0..<500 where model.backgroundMusic == nil && model.backgroundMusicError == nil { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.backgroundMusic != nil && model.backgroundMusicError == nil, "Music mixing fixture import failed")
        var document = model.currentDocument()
        document.clips = cut.segments
        document.zoomEnabled = false; document.zoomCues = []
        document.exportSettings?.resolution = .original
        try session.writeEditDocument(document)
        await model.discardChanges() // Restore through the model below by reopening the edited package.
        model.teardown()
        try session.writeEditDocument(document)
        session.removeDraftDocument()
        let preview = RecordingStudioModel(url: session.directoryURL)
        defer { preview.teardown() }
        await preview.load()
        try check(preview.isLoaded && preview.musicWaveform.count > 0, "Studio music preview or waveform did not load")
        let item = preview.screenPlayer.currentItem!
        let previewDuration = try await item.asset.load(.duration).seconds
        try check(abs(previewDuration - cut.duration) < 0.01, "Studio composition missed cut duration: \(previewDuration)")
        let previewURL = directory.appendingPathComponent("music-preview.m4a")
        let previewExport = AVAssetExportSession(asset: item.asset, presetName: AVAssetExportPresetAppleM4A)!
        previewExport.audioMix = item.audioMix
        try await previewExport.export(to: previewURL, as: .m4a)
        let shared = try await RecordingSessionRenderer.ensureDeliverable(for: session)
        let configuration = try await RecordingSessionRenderer.makeConfiguration(for: session)
        let micID = configuration.microphoneTrackID
        try check(micID != nil && configuration.backgroundMusic != nil, "Shared renderer lost mic/music configuration")
        let audio = try await RecordingAudioExporter().export(.init(screenURL: session.screenURL, clipTimeline: cut,
            replacementURL: nil, format: .wav, microphoneTrackID: micID, backgroundMusic: configuration.backgroundMusic), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: audio) }
        for url in [previewURL, shared, audio] {
            let quiet = try await level(url, at: 0.15, frequency: 660)
            let ducked = try await level(url, at: 0.85, frequency: 660)
            let voice = try await level(url, at: 0.85, frequency: 220)
            let system = try await level(url, at: 0.85, frequency: 900)
            let repeated = try await level(url, at: 2.1, frequency: 660)
            let faded = try await level(url, at: 4.3, frequency: 660)
            try check(quiet > 0.025 && ducked > 0.004 && ducked < quiet * 0.4 && voice > 0.1 && system > 0.1,
                "Music/voice/system mix or ducking failed: \(quiet), \(ducked), \(voice), \(system)")
            try check(repeated > 0.025 && faded < quiet * 0.3, "Music loop/start offset/fade failed: \(repeated), \(faded)")
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            // Playback duration is checked on the composition, separately from this harness-only encoded proxy.
            if url != previewURL {
                try check(abs(duration - cut.duration) < 0.06, "Music export missed cut duration: \(url.lastPathComponent) = \(duration), expected \(cut.duration)")
            }
        }
        let unducked = try await RecordingAudioExporter().export(.init(screenURL: session.screenURL, clipTimeline: cut,
            replacementURL: nil, format: .wav, microphoneTrackID: 9999,
            backgroundMusic: configuration.backgroundMusic), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: unducked) }
        let fallbackLevel = try await level(unducked, at: 0.85, frequency: 660)
        try check(fallbackLevel > 0.025, "Failed mic analysis did not export unducked music")
        let muted = try await RecordingAudioExporter().export(.init(screenURL: session.screenURL, clipTimeline: cut,
            replacementURL: nil, format: .wav, volume: 0, microphoneTrackID: micID,
            backgroundMusic: configuration.backgroundMusic), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: muted) }
        let mutedMusic = try await level(muted, at: 0.85, frequency: 660)
        try check(mutedMusic > 0.004, "Recorded volume muted independent music")
        for replacement in [false, true] {
            let url = try await RecordingAudioExporter().export(.init(screenURL: session.screenURL, clipTimeline: cut,
                replacementURL: replacement ? isolatedURL : nil, format: .wav,
                isolatedMicrophoneURL: replacement ? nil : isolatedURL, microphoneTrackID: micID,
                backgroundMusic: configuration.backgroundMusic), progress: { _ in })
            defer { try? FileManager.default.removeItem(at: url) }
            let levels = try await audioLevels(at: url, time: 0.85, length: 0.12, frequencies: [220, 440, 660, 900])
            try check(levels[0] < 0.005 && levels[1] > 0.1 && levels[2] > 0.004 && levels[2] < 0.02,
                "Replace/isolation lost music or source-mic ducking: \(levels)")
            try check(replacement ? levels[3] < 0.005 : levels[3] > 0.1, "Replace/isolation changed system track selection")
        }
        var gifDocument = document
        var gifSettings = configuration.exportSettings
        gifSettings.exportsGIF = true
        gifDocument.exportSettings = gifSettings
        gifDocument.backgroundMusic?.fileName = "background-music.absent.wav"
        try session.writeEditDocument(gifDocument)
        let sharedGIF = try await RecordingSessionRenderer.makeConfiguration(for: session)
        try check(sharedGIF.backgroundMusic == nil, "Shared GIF configuration retained music")
        let defensiveGIF = RecordingStudioExporter.Configuration(screenURL: session.screenURL, cameraURL: nil,
            cameraOffset: 0, style: configuration.style, viewportTimeline: .identity,
            pointerTimeline: nil, showsPressEffects: false, keystrokeTimeline: nil,
            keystrokePlacement: configuration.keystrokePlacement, subtitleTimeline: nil,
            subtitleStyle: configuration.subtitleStyle,
            canvasSize: configuration.canvasSize, clipTimeline: cut, exportSettings: gifSettings,
            microphoneTrackID: micID,
            backgroundMusic: .init(url: session.directoryURL.appendingPathComponent("background-music.absent.wav"), settings: gifDocument.backgroundMusic!))
        let intermediate = try await RecordingStudioExporter().export(defensiveGIF, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: intermediate) }
        let excludedMusic = try await level(intermediate, at: 0.85, frequency: 660)
        try check(excludedMusic < 0.005, "GIF intermediate mixed music")
        print("PASS: GIF configuration omits music; its intermediate exports without loading an absent song or applying music ducking")
        try check(try Data(contentsOf: session.screenURL) == original, "Mixing changed the source recording")
        print("PASS: Studio preview, shared video and audio-only exports retain voice/system audio, loop from offset, duck music on source mic and fade at edited end; independent volume; Replace/Isolate Voice remain compatible")
    }

    static func replacementVideoTiming(in directory: URL) async throws {
        let session = RecordingSession(directoryURL: directory.appendingPathComponent("replacement-video.screendroprec"))
        try FileManager.default.createDirectory(at: session.directoryURL, withIntermediateDirectories: false)
        let videoURL = directory.appendingPathComponent("replacement-colors.mov")
        try await movie(at: videoURL, colorAt: { time in
            CGColor(red: time < 4 ? 1 : 0, green: 0, blue: time < 4 ? 0 : 1, alpha: 1)
        })
        let originalAudio = directory.appendingPathComponent("replacement-original.wav")
        try audioTone(at: originalAudio, frequency: 220)
        let composition = AVMutableComposition()
        for url in [videoURL, originalAudio] {
            let asset = AVURLAsset(url: url)
            for track in try await asset.load(.tracks) {
                let destination = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try destination.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 8, timescale: 1)), of: track, at: .zero)
            }
        }
        let sourceExport = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await sourceExport.export(to: session.screenURL, as: .mov)
        let replacementURL = session.directoryURL.appendingPathComponent("\(RecordingSession.replacementAudioBaseName).\(UUID().uuidString).wav")
        try audioTone(at: replacementURL, frequency: 660, active: { $0 >= 2.5 })
        let cut = RecordingClipTimeline(segments: [.init(sourceStart: 0.5, sourceEnd: 3), .init(sourceStart: 4, sourceEnd: 8, speed: 2)])
        var style = RecordingStudioStyle()
        style.padding = 0; style.shadow = 0; style.cornerRadius = 0
        var settings = VideoCompressionSettings()
        settings.resolution = .original
        var document = RecordingEditDocument(style: style, zoomEnabled: false, zoomCues: [], clipTimeline: cut,
            exportSettings: settings, replacementAudioFileName: replacementURL.lastPathComponent)
        try session.writeEditDocument(document)
        let configuration = try await RecordingSessionRenderer.makeConfiguration(for: session)
        try check(configuration.backgroundMusic == nil, "Replacement-only video fixture unexpectedly selected music")
        let movie = try await RecordingSessionRenderer.ensureDeliverable(for: session)
        let duration = try await AVURLAsset(url: movie).load(.duration).seconds
        try check(abs(duration - cut.duration) < 0.03, "Replacement video duration missed the cut")
        let before = try await audioLevels(at: movie, time: 2.3, length: 0.12, frequencies: [220, 660])
        let after = try await audioLevels(at: movie, time: 2.65, length: 0.12, frequencies: [660])
        let end = try await audioLevels(at: movie, time: 4.25, length: 0.12, frequencies: [660])
        let red = try await pixels(in: movie, at: 2.35), blue = try await pixels(in: movie, at: 2.65)
        try check(before.allSatisfy { $0 < 0.005 } && after[0] > 0.1 && end[0] > 0.1,
                  "Replacement was re-cut, sped up, ended early or leaked original audio")
        try check(red[0] > 200 && red[2] < 50 && blue[2] > 200 && blue[0] < 50,
                  "Replacement tone onset did not align with the video's cut boundary")
        let invalid = session.directoryURL.appendingPathComponent("video-only.mov")
        try FileManager.default.copyItem(at: videoURL, to: invalid)
        document.replacementAudioFileName = invalid.lastPathComponent
        try session.writeEditDocument(document)
        do {
            _ = try await RecordingSessionRenderer.ensureDeliverable(for: session)
            throw Failure(description: "Video export accepted a replacement without audio")
        } catch let error as RecordingReplacementAudio.LoadError {
            try check(error.localizedDescription.contains("no readable audio track"), "Video replacement error was unclear")
        }
        do {
            _ = try await RecordingAudioExporter().export(.init(screenURL: session.screenURL, clipTimeline: cut,
                replacementURL: invalid, format: .wav), progress: { _ in })
            throw Failure(description: "Audio export accepted a replacement without audio")
        } catch let error as RecordingReplacementAudio.LoadError {
            try check(error.localizedDescription.contains("no readable audio track"), "Audio replacement error was unclear")
        }
        print("PASS: replacement VIDEO export without music preserves a cut/2x timeline, tone onset at the color boundary and audio to the end; invalid replacements give a clear video/audio error")
    }

    static func backgroundMusicHistory(in directory: URL) async throws {
        let session = RecordingSession(directoryURL: directory.appendingPathComponent("music-history.screendroprec"))
        try FileManager.default.createDirectory(at: session.directoryURL, withIntermediateDirectories: false)
        try await movie(at: session.screenURL)
        let first = directory.appendingPathComponent("history-a.wav"), second = directory.appendingPathComponent("history-b.wav")
        try audioTone(at: first, frequency: 440)
        try audioTone(at: second, frequency: 660)
        let model = RecordingStudioModel(url: session.directoryURL)
        defer { model.teardown() }
        await model.load()
        model.setBackgroundMusic(fileURL: first, displayName: "A", credit: "A credit", startOffset: 0)
        try await until { !model.hasRunningWork }
        let a = model.backgroundMusicSettings!
        try check(model.canUndo, "Adding music did not register Undo")
        model.undo()
        try await until { !model.hasRunningWork }
        try check(model.backgroundMusicSettings == nil && model.backgroundMusic == nil && model.canRedo, "Undo Add Music failed")
        model.redo()
        try await until { !model.hasRunningWork }
        try check(model.backgroundMusicSettings == a && model.backgroundMusic != nil, "Redo Add Music failed")
        model.setBackgroundMusic(fileURL: second, displayName: "B", credit: "B credit", startOffset: 1)
        try await until { !model.hasRunningWork }
        let b = model.backgroundMusicSettings!
        model.undo()
        try await until { !model.hasRunningWork }
        try check(model.backgroundMusicSettings == a, "Undo Replace Music lost the previous selection")
        model.redo()
        try await until { !model.hasRunningWork }
        try check(model.backgroundMusicSettings == b, "Redo Replace Music failed")
        model.removeBackgroundMusic()
        model.undo()
        try await until { !model.hasRunningWork }
        try check(model.backgroundMusicSettings == b && model.backgroundMusic != nil, "Undo Remove Music failed")
        model.redo()
        try await until { !model.hasRunningWork }
        try check(model.backgroundMusicSettings == nil, "Redo Remove Music failed")
        model.undo()
        try await until { !model.hasRunningWork }
        model.setMusicSliderEditing(true)
        model.musicVolume = 0.3; model.musicVolume = 0.4; model.musicVolume = 0.5
        model.setMusicSliderEditing(false)
        model.undo()
        try await until { !model.hasRunningWork }
        try check(model.musicVolume == CGFloat(b.volume), "Volume drag was not one Undo step")
        model.redo()
        try await until { !model.hasRunningWork }
        try check(model.musicVolume == 0.5, "Volume drag Redo did not restore the final value")
        model.setMusicSliderEditing(true)
        model.musicStartOffset = 2; model.musicStartOffset = 3
        model.setMusicSliderEditing(false)
        model.undo()
        try await until { !model.hasRunningWork }
        try check(model.musicStartOffset == CGFloat(b.startOffset), "Start-offset drag was not one Undo step")
        model.redo()
        try await until { !model.hasRunningWork }
        try check(model.musicStartOffset == 3, "Start-offset drag Redo failed")
        let before = model.backgroundMusicSettings!
        model.musicLoops = false
        model.undo()
        try await until { !model.hasRunningWork }
        try check(model.backgroundMusicSettings == before, "Loop Undo failed")
        model.redo()
        try await until { !model.hasRunningWork }
        try check(!model.musicLoops, "Loop Redo failed")
        model.musicDucks = false
        model.undo()
        try await until { !model.hasRunningWork }
        try check(model.musicDucks, "Ducking Undo failed")
        model.redo()
        try await until { !model.hasRunningWork }
        try check(!model.musicDucks, "Ducking Redo failed")
        model.musicDuckAmount = .aLot
        model.undo()
        try await until { !model.hasRunningWork }
        try check(model.musicDuckAmount == .medium, "Duck amount Undo failed")
        model.redo()
        try await until { !model.hasRunningWork }
        try check(model.musicDuckAmount == .aLot, "Duck amount Redo failed")
        print("PASS: music Add/Replace/Remove/settings support Undo/Redo; volume and start-offset drags each use one history step")
    }

    static func backgroundMusicRetention(in directory: URL) async throws {
        let session = RecordingSession(directoryURL: directory.appendingPathComponent("music-retention.screendroprec"))
        try FileManager.default.createDirectory(at: session.directoryURL, withIntermediateDirectories: false)
        try await movie(at: session.screenURL)
        let sourceBytes = try Data(contentsOf: session.screenURL)
        func song(_ label: String) throws -> RecordingBackgroundMusic {
            let name = "\(RecordingBackgroundMusic.baseName).\(UUID().uuidString).wav"
            try audioTone(at: session.directoryURL.appendingPathComponent(name), frequency: 660)
            return RecordingBackgroundMusic(fileName: name, displayName: label, credit: label)
        }
        let saved = try song("Saved"), draft = try song("Draft only"), snapshotOnly = try song("Snapshot only"), orphan = try song("Orphan")
        let replacement = "\(RecordingSession.replacementAudioBaseName).\(UUID().uuidString).wav"
        try audioTone(at: session.directoryURL.appendingPathComponent(replacement), frequency: 440)
        var savedDoc = RecordingEditDocument(style: RecordingStudioStyle(), zoomEnabled: false, zoomCues: [],
            clipTimeline: .full(sourceDuration: 8), backgroundMusic: saved)
        savedDoc.replacementAudioFileName = replacement
        var draftDoc = savedDoc
        draftDoc.backgroundMusic = draft
        var snapshotDoc = savedDoc
        snapshotDoc.backgroundMusic = snapshotOnly
        snapshotDoc.clips = [.init(sourceStart: 4, sourceEnd: 8, speed: 2)]
        try session.writeEditDocument(savedDoc)
        try session.writeDraftDocument(draftDoc)
        let store = CaptureSessionSnapshots(directory: session.sessionSnapshotsURL)
        let snapshot = try store.keep(document: CaptureSessionSnapshots.encode(snapshotDoc), openedAt: Date()).first!
        let retained = try [saved.fileName, draft.fileName, snapshotOnly.fileName, replacement].map { name in
            (name, try Data(contentsOf: session.directoryURL.appendingPathComponent(name)))
        }
        let model = RecordingStudioModel(url: session.directoryURL)
        await model.load()
        try check(model.isLoaded && model.backgroundMusicSettings == draft, "Draft-only song did not reopen")
        model.teardown()
        for (name, bytes) in retained {
            try check(try Data(contentsOf: session.directoryURL.appendingPathComponent(name)) == bytes, "Cleanup removed or changed referenced music: \(name)")
        }
        try check(!FileManager.default.fileExists(atPath: session.directoryURL.appendingPathComponent(orphan.fileName).path), "Cleanup did not collect orphan music")
        try check(try Data(contentsOf: session.screenURL) == sourceBytes, "Music cleanup changed the source video")
        let reopened = RecordingStudioModel(url: session.directoryURL)
        await reopened.load()
        try check(reopened.backgroundMusicSettings == draft, "Draft-only music did not survive close/reopen")
        let previous = reopened.currentDocument()
        reopened.revertToSession(snapshot)
        try await until { !reopened.hasRunningWork }
        try check(reopened.backgroundMusicSettings == snapshotOnly && reopened.backgroundMusic != nil && reopened.clipTimeline.segments == snapshotDoc.clips,
                  "Revert to Session did not restore snapshot-only music and cuts")
        reopened.undo()
        try await until { !reopened.hasRunningWork }
        try check(reopened.backgroundMusicSettings == draft && reopened.clipTimeline.segments == previous.clips, "Undo snapshot restore did not restore draft music/cuts")
        reopened.redo()
        try await until { !reopened.hasRunningWork }
        try check(reopened.backgroundMusicSettings == snapshotOnly && reopened.clipTimeline.segments == snapshotDoc.clips, "Redo snapshot restore lost music/cuts")
        reopened.revertToOriginal()
        try await until { !reopened.hasRunningWork }
        try check(reopened.backgroundMusicSettings == nil, "Revert to Original retained music")
        reopened.undo()
        try await until { !reopened.hasRunningWork }
        try check(reopened.backgroundMusicSettings == snapshotOnly && reopened.backgroundMusic != nil, "Undo Revert to Original did not restore music")
        reopened.teardown()

        let broken = RecordingSession(directoryURL: directory.appendingPathComponent("music-unreadable-snapshot.screendroprec"))
        try FileManager.default.createDirectory(at: broken.directoryURL, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: session.screenURL, to: broken.screenURL)
        let protectedURL = broken.directoryURL.appendingPathComponent("\(RecordingBackgroundMusic.baseName).\(UUID().uuidString).wav")
        try audioTone(at: protectedURL, frequency: 440)
        let protectedBytes = try Data(contentsOf: protectedURL)
        let plain = RecordingEditDocument(style: RecordingStudioStyle(), zoomEnabled: false, zoomCues: [])
        try broken.writeEditDocument(plain)
        let brokenStore = CaptureSessionSnapshots(directory: broken.sessionSnapshotsURL)
        let corruptEntry = try brokenStore.keep(document: CaptureSessionSnapshots.encode(plain), openedAt: Date()).first!
        let corruptURL = broken.sessionSnapshotsURL.appendingPathComponent(corruptEntry.id.uuidString).appendingPathComponent("document.json")
        try Data("unreadable snapshot".utf8).write(to: corruptURL)
        let cautious = RecordingStudioModel(url: broken.directoryURL)
        await cautious.load()
        try check(cautious.isLoaded, "Unreadable snapshot fixture could not load the saved project")
        cautious.teardown()
        try check(try Data(contentsOf: protectedURL) == protectedBytes, "Unreadable snapshot did not protect potentially referenced music")
        print("PASS: saved, draft-only and snapshot-only music retain bytes; orphan music is collected; replacement/source stay; snapshot Revert/Undo/Redo restores music and cuts; unreadable snapshots stop collection")
    }

    static func backgroundMusicStorage(in directory: URL) async throws {
        let session = RecordingSession(directoryURL: directory.appendingPathComponent("music-storage.screendroprec"))
        try FileManager.default.createDirectory(at: session.directoryURL, withIntermediateDirectories: false)
        try await movie(at: session.screenURL)
        let input = directory.appendingPathComponent("download.wav")
        try audioTone(at: input, frequency: 660)
        let original = try Data(contentsOf: session.screenURL)
        let model = RecordingStudioModel(url: session.directoryURL)
        await model.load()
        try check(model.isLoaded, "Music storage fixture did not load")
        model.setBackgroundMusic(fileURL: input, displayName: "Test music", credit: "Test credit", startOffset: 2)
        try FileManager.default.removeItem(at: input) // Picker removes its temp on callback return.
        for _ in 0..<500 where model.backgroundMusic == nil && model.backgroundMusicError == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let stored = model.currentDocument()
        try check(stored.backgroundMusic?.startOffset == 2 && stored.backgroundMusic?.credit == "Test credit", "Music import lost metadata")
        try check(model.backgroundMusic != nil && model.backgroundMusicError == nil, "Synchronous copy did not survive deleted download")
        try check(model.saveProject(), "Music project did not save")
        let storedURL = session.directoryURL.appendingPathComponent(stored.backgroundMusic!.fileName)
        let musicBytes = try Data(contentsOf: storedURL)
        model.musicVolume = 0.4
        model.removeBackgroundMusic()
        try check(model.currentDocument().backgroundMusic == nil, "Music removal did not clear selection")
        let restoreGate = Gate()
        model.musicAnalysisOverride = { _, _ in await restoreGate.wait(); return nil }
        model.screenPlayer.isMuted = true
        model.cameraPlayer.isMuted = true
        model.play()
        try check(model.isPlaying, "Muted restore fixture did not start its synthetic playback clock")
        let restoring = Task { await model.discardChanges() }
        try await until { restoreGate.continuation != nil }
        let heldSettings = model.backgroundMusicSettings
        let heldFiles = try FileManager.default.contentsOfDirectory(atPath: session.directoryURL.path)
        try check(model.isRestoringDocument && model.hasRunningWork && !model.canUndo && !model.canRedo, "Restore did not own its busy state")
        model.play()
        model.musicVolume = 0.9
        model.musicStartOffset = 1
        model.musicLoops = false
        model.musicDucks = false
        model.musicDuckAmount = .aLot
        model.removeBackgroundMusic()
        model.setBackgroundMusic(fileURL: storedURL, displayName: "Interleaved", credit: nil, startOffset: 0)
        await model.discardChanges()
        try check(!model.isPlaying && model.backgroundMusicSettings == heldSettings && model.isRestoringDocument,
                  "Play or music edits interleaved with held restoration")
        try check(try FileManager.default.contentsOfDirectory(atPath: session.directoryURL.path) == heldFiles,
                  "A blocked import still copied a file")
        restoreGate.resume()
        await restoring.value
        try check(!model.isRestoringDocument && !model.hasRunningWork, "Completed restore kept its owned busy state")
        model.musicAnalysisOverride = { _, _ in nil }
        try check(!model.isPlaying, "Restoring music left the previous player running during audio reload")
        try check(model.backgroundMusic != nil && model.backgroundMusicError == nil, "Unavailable analysis prevented Studio music restoration")
        try check(model.backgroundMusic != nil && model.currentDocument().backgroundMusic == stored.backgroundMusic, "Discard did not restore saved music")
        let bad = directory.appendingPathComponent("invalid-audio.wav")
        try Data("not audio".utf8).write(to: bad)
        model.setBackgroundMusic(fileURL: bad, displayName: "Invalid", credit: nil, startOffset: 0)
        for _ in 0..<500 where model.backgroundMusicError == nil { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.backgroundMusicError != nil && model.currentDocument().backgroundMusic == stored.backgroundMusic, "Invalid import replaced valid music")
        model.teardown()
        try check(try Data(contentsOf: storedURL) == musicBytes && Data(contentsOf: session.screenURL) == original, "Music cleanup touched a referenced file or the source")
        let data = try CaptureManifest.encoder.encode(stored)
        try check(try CaptureManifest.decoder.decode(RecordingEditDocument.self, from: data) == stored, "Music document did not round trip")
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "backgroundMusic")
        let old = try CaptureManifest.decoder.decode(RecordingEditDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(old.backgroundMusic == nil && old.formatVersion == 6, "Legacy document selected music or changed version")
        print("PASS: held music restore blocks Play/import/removal/settings until resolution and player rebuild finish")
        print("PASS: music copies before picker callback returns; metadata/save/discard/legacy round trip; invalid import preserves selection; cleanup preserves source and saved music")
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
        let redactions = [RecordingRedaction(start: 0, end: 8, rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3), mode: .pixelate)]
        var document = RecordingEditDocument(style: style, zoomEnabled: false, zoomCues: [], clipTimeline: cut,
                                             isolateVoice: true, redactions: redactions)
        let data = try CaptureManifest.encoder.encode(document)
        let decoded = try CaptureManifest.decoder.decode(RecordingEditDocument.self, from: data)
        try check(decoded.formatVersion == 6 && decoded.isolateVoice && decoded.redactions == redactions,
                  "Version 6 did not preserve both isolation and redactions")
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy["formatVersion"] = 5
        legacy.removeValue(forKey: "isolateVoice")
        legacy.removeValue(forKey: "redactions")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let oldDocument = try CaptureManifest.decoder.decode(RecordingEditDocument.self, from: legacyData)
        try check(!oldDocument.isolateVoice && oldDocument.redactions.isEmpty, "Old edits enabled isolation or redactions")
        try session.writeEditDocument(document)
        let configuration = try await RecordingSessionRenderer.makeConfiguration(for: session)
        try check(configuration.isolatedMicrophoneURL == isolatedURL && configuration.microphoneTrackID != nil, "Shared export missed isolated microphone")
        try check(configuration.redactions == redactions, "Isolation dropped shared-export redactions")
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
        try check(model.currentDocument().redactions == redactions, "Studio dropped redactions while restoring isolation")
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
        print("PASS: version 6 preserves isolation and redactions; legacy off; shared video and audio exports use isolated mic plus system audio through cuts; Studio progress/cancel/cache/off, unfinished draft stays off, and failure fallback")
    }

    static func cancelShareRetry(in directory: URL) async throws {
        let model = RecordingStudioModel(url: directory.appendingPathComponent("unloaded.mov"))
        defer { model.teardown() }
        let first = Gate(), retry = Gate(), deletion = Gate()
        var starts = 0
        model.shareState = .uploading
        model.startShareTask {
            starts += 1
            await first.wait()
            model.shareState = Task.isCancelled ? .idle : .finished("first")
        }
        try await until { first.continuation != nil }
        model.cancelShare()
        model.cancelShare()
        try check(model.shareState.isBusy && model.hasRunningWork, "Cancel cleared share busy state before exit")
        model.startShareTask { starts += 1 }
        await Task.yield()
        try check(starts == 1 && model.shareState.isBusy && model.hasRunningWork, "Retry entered while the canceled share was held")
        first.resume()
        try await until { !model.hasRunningWork }
        try check(model.shareState == .idle, "Canceled share did not settle at idle")

        model.shareState = .rendering(progress: 0)
        model.startShareTask {
            starts += 1
            await retry.wait()
            model.shareState = .finished("replacement")
        }
        try await until { retry.continuation != nil }
        await Task.yield()
        try check(starts == 2 && model.shareState == .rendering(progress: 0) && model.hasRunningWork,
                  "The old share cleared the retry's state")
        retry.resume()
        try await until { !model.hasRunningWork }
        try check(model.shareState == .finished("replacement"), "Replacement retry did not complete")

        // Deletion uses the same retained task even while no share progress is shown.
        model.shareState = .idle
        model.startShareTask { await deletion.wait() }
        try await until { deletion.continuation != nil }
        model.cancelShare()
        try check(model.hasRunningWork, "A canceled deletion released the shared task guard")
        model.startShareTask { starts += 1 }
        await Task.yield()
        try check(starts == 2, "Share entered while deletion was unwinding")
        deletion.resume()
        try await until { !model.hasRunningWork }
        print("PASS: held share cancel/retry retains busy state until exit; stale completion cannot clear retry; deletion shares the guard")
    }

    static func main() async throws {
        setbuf(stdout, nil)
        guard let root = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            throw Failure(description: "Run through check-recording-export-regressions.py")
        }
        let directory = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
        let support = ScreendropStorage.applicationSupportDirectory.resolvingSymlinksInPath().path
        try check(home == directory && support.hasPrefix(directory.path + "/"), "Foundation storage escaped isolated home")
        if ProcessInfo.processInfo.environment["SCREENDROP_CHECK_MUSIC_DELIVERY_ONLY"] == "1" {
            try await musicDelivery(in: directory)
            return
        }
        try await chapterAtPlayhead(in: directory)
        try await chapterRenameUndo(in: directory)
        try await unchangedRenderReuse(in: directory)
        try await quickLookInstant(in: directory)
        try await musicDelivery(in: directory)
        try await replacementVideoTiming(in: directory)
        try await backgroundMusicMixing(in: directory)
        try await backgroundMusicHistory(in: directory)
        try await backgroundMusicRetention(in: directory)
        try await backgroundMusicStorage(in: directory)
        try await voiceIsolation(in: directory)
        try await cancelRetry(in: directory)
        try await cancelShareRetry(in: directory)
        try await captionPixels(in: directory)
    }
}
