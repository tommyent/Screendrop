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
        await model.discardChanges()
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
        guard let root = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            throw Failure(description: "Run through check-recording-export-regressions.py")
        }
        let directory = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
        let support = ScreendropStorage.applicationSupportDirectory.resolvingSymlinksInPath().path
        try check(home == directory && support.hasPrefix(directory.path + "/"), "Foundation storage escaped isolated home")
        try await chapterAtPlayhead(in: directory)
        try await chapterRenameUndo(in: directory)
        try await unchangedRenderReuse(in: directory)
        try await quickLookInstant(in: directory)
        try await backgroundMusicStorage(in: directory)
        try await voiceIsolation(in: directory)
        try await cancelRetry(in: directory)
        try await cancelShareRetry(in: directory)
        try await captionPixels(in: directory)
    }
}
