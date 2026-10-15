import AVFoundation
import AppKit
import CoreImage
import CoreTransferable
import CoreVideo
import Darwin
import ImageIO
import Metal

nonisolated final class ChapterAssetProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var received: (mediaKey: String?, body: String)?

    static func payload() -> (mediaKey: String?, body: String)? { lock.withLock { received } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "chapter-upload.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        Self.lock.withLock { Self.received = (request.value(forHTTPHeaderField: "X-Media-Key"), String(decoding: body, as: UTF8.self)) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// Run with check-video-redaction.py and the Dev DerivedData path. No windows or live services.
@main
struct VideoRedactionChecks {
    enum Failure: Error { case check(String) }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.check(message) }
    }

    static func buffer(width: Int = 384, height: Int = 216) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        try check(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                                      &result) == kCVReturnSuccess, "Fixture allocation")
        guard let result else { throw Failure.check("Fixture buffer missing") }
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let pixels = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * CVPixelBufferGetBytesPerRow(result) + x * 4
                let value: UInt8 = (x / 3 + y / 3) % 2 == 0 ? 240 : 16
                pixels[index] = value; pixels[index + 1] = value; pixels[index + 2] = value; pixels[index + 3] = 255
            }
        }
        return result
    }

    static func movie(at url: URL, duration: Double = 3) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 384, AVVideoHeightKey: 216
        ])
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        try check(writer.startWriting(), "Fixture writer start")
        writer.startSession(atSourceTime: .zero)
        let source = try buffer()
        // Sparse capture: the same frame is held across both redaction boundaries.
        for time in [0.0, duration - 0.1] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            try check(adaptor.append(source, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)), "Fixture append")
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        try check(writer.status == .completed, "Fixture writer finish")
    }

    static func image(_ url: URL, time: Double, composition: AVVideoComposition? = nil) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    static func detail(_ image: CGImage, rect: CGRect) -> Double {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let x0 = Int(rect.minX * Double(image.width)), x1 = Int(rect.maxX * Double(image.width))
        let y0 = Int(rect.minY * Double(image.height)), y1 = Int(rect.maxY * Double(image.height))
        var sum = 0.0, count = 0.0
        for y in y0..<y1 {
            for x in x0..<max(x0, x1 - 1) {
                let index = y * context.bytesPerRow + x * 4
                sum += Double(abs(Int(bytes[index]) - Int(bytes[index + 4])))
                count += 1
            }
        }
        return sum / max(count, 1)
    }

    static func renderers() async throws {
        let size = CGSize(width: 384, height: 216)
        let source = try buffer(width: 768, height: 432)
        let context = CIContext()
        let device = MTLCreateSystemDefaultDevice()!
        let library = try await device.makeLibrary(source: String(contentsOfFile: "Screendrop/StudioMotionBlur.metal", encoding: .utf8), options: nil)
        let path = CGPath(roundedRect: CGRect(x: 12, y: 12, width: 360, height: 192), cornerWidth: 8, cornerHeight: 8, transform: nil)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for mode in RecordingRedaction.Mode.allCases {
            let region = RecordingRedaction(start: 0, end: 1, rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), mode: mode, strength: 1)
            let filtered = try RecordingRedactionFilter.buffer(from: source, redactions: [region], context: context)
            let renderer = StudioMetalScreenRenderer(canvasSize: size, backdrop: nil, cardPath: path, colorSpace: space, library: library)!
            for samples in [[CGRect(x: 12, y: 12, width: 360, height: 192)],
                            [CGRect(x: -30, y: -18, width: 480, height: 270), CGRect(x: -36, y: -21, width: 492, height: 276)]] {
                let destination = try buffer()
                let submission = renderer.submit(screenFrame: filtered, sampleRects: samples, into: destination)
                try check(submission != nil && renderer.wait(for: submission!), "Metal submission failed")
                let gpuImage = context.createCGImage(CIImage(cvPixelBuffer: destination), from: CGRect(origin: .zero, size: size))!
                let sourceImage = context.createCGImage(CIImage(cvPixelBuffer: filtered), from: CGRect(x: 0, y: 0, width: 768, height: 432))!
                let cpu = CGContext(data: nil, width: 384, height: 216, bitsPerComponent: 8, bytesPerRow: 384 * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                cpu.setFillColor(CGColor(gray: 0, alpha: 1)); cpu.fill(CGRect(origin: .zero, size: size))
                cpu.interpolationQuality = .high; cpu.addPath(path); cpu.clip()
                for (index, rect) in samples.enumerated() {
                    cpu.setAlpha(1 / CGFloat(index + 1))
                    cpu.draw(sourceImage, in: CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height))
                }
                let gpu = CGContext(data: nil, width: 384, height: 216, bitsPerComponent: 8, bytesPerRow: 384 * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                gpu.draw(gpuImage, in: CGRect(origin: .zero, size: size))
                let a = cpu.data!.assumingMemoryBound(to: UInt8.self), b = gpu.data!.assumingMemoryBound(to: UInt8.self)
                let interior = CGRect(x: 0.15, y: 0.15, width: 0.25, height: 0.2)
                let outside = CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2)
                var difference = 0.0, count = 0.0
                for y in 33..<75 {
                    for x in 58..<153 {
                        let offset = y * cpu.bytesPerRow + x * 4
                        difference += Double(abs(Int(a[offset]) - Int(b[offset]))); count += 1
                    }
                }
                try check(difference / count < 8, "CPU/Metal masked pixels differ: \(difference / count)")
                for image in [cpu.makeImage()!, gpuImage] {
                    try check(detail(image, rect: interior) < detail(image, rect: outside) * 0.4, "Mask did not obscure transformed pixels")
                }
            }
        }
        print("PASS actual Metal versus CPU filtered source, downsampling, crop/zoom and shutter samples")
    }

    static func frozenChapterSidecars(in home: URL) async throws {
        let session = RecordingSession(directoryURL: home.appendingPathComponent("chapter-fixture.screendroprec"))
        try FileManager.default.createDirectory(at: session.directoryURL, withIntermediateDirectories: true)
        try session.writeCaptureManifest(CaptureManifest(duration: 3, pixelWidth: 384, pixelHeight: 216))
        try session.updateProjectMetadata {
            $0.chapters = [RecordingChapter(title: "First", start: 0), RecordingChapter(title: "Cut", start: 1.2), RecordingChapter(title: "Later", start: 2.2)]
        }
        var document = RecordingEditDocument(style: .init(), zoomEnabled: false, zoomCues: [],
            clipTimeline: .full(sourceDuration: 3), exportSettings: .init())
        session.writeRenderStamp(document)
        let original = CloudSidecarUploader.chapterData(sessionDirectory: session.directoryURL, uploadedFileURL: session.finalURL)
        document.redactions = [.init(start: 0, end: 3, rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))]
        session.writeRenderStamp(document)
        try check(CloudSidecarUploader.chapterData(sessionDirectory: session.directoryURL, uploadedFileURL: session.finalURL) == original,
                  "Redaction-only replacement changed chapters")

        let cut = RecordingClipTimeline(segments: [.init(sourceStart: 0, sourceEnd: 1, speed: 2), .init(sourceStart: 2, sourceEnd: 3)])
        document = RecordingEditDocument(style: .init(), zoomEnabled: false, zoomCues: [], clipTimeline: cut, exportSettings: .init())
        session.writeRenderStamp(document)
        try await movie(at: session.finalURL, duration: cut.duration)
        // A newer draft must not change the cut whose movie is being uploaded.
        try session.writeDraftDocument(RecordingEditDocument(style: .init(), zoomEnabled: false, zoomCues: [],
            clipTimeline: .full(sourceDuration: 3), exportSettings: .init()))
        guard let frozen = CloudSidecarUploader.chapterData(sessionDirectory: session.directoryURL, uploadedFileURL: session.finalURL),
              let chapters = try JSONSerialization.jsonObject(with: frozen) as? [[String: Any]] else {
            throw Failure.check("Frozen chapter payload missing")
        }
        try check(chapters.compactMap { $0["title"] as? String } == ["First", "Later"], "Cut chapter was retained")
        try check(abs((chapters.last?["start"] as? Double ?? -1) - 0.7) < 0.000_001, "Cut/speed chapter time was not remapped")
        try session.updateProjectMetadata { $0.chapters = [] }
        session.writeRenderStamp(nil)

        try check(URLProtocol.registerClass(ChapterAssetProtocol.self), "Chapter transport fixture registration")
        defer { URLProtocol.unregisterClass(ChapterAssetProtocol.self) }
        let revision = "replacements/abcd1234/frozen-cut"
        try await CloudSidecarUploader.uploadVideoSidecars(uploadID: "abcd1234", uploadedFileURL: session.finalURL,
            transcriptData: nil, chapterData: frozen, createdAt: .distantPast, mediaKey: revision, replacingVideo: true,
            creds: CloudCredentials(workerURL: "https://chapter-upload.invalid", uploadToken: "synthetic-test-token"))
        guard let sent = ChapterAssetProtocol.payload() else { throw Failure.check("Chapter sidecar request missing") }
        try check(sent.mediaKey == revision && sent.body.contains("name=\"chapters\"")
                  && sent.body.contains(String(decoding: frozen, as: UTF8.self)), "Frozen chapters or media revision changed during sidecar upload")
        print("PASS frozen chapter sidecars: redaction-only unchanged, cuts/speed remapped, later draft/metadata ignored, revision-bound multipart verified")
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        try await renderers()
        let home = ProcessInfo.processInfo.environment["F2_FIXTURE_HOME"] ?? ""
        let isolated = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        let actualHome = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let support = ScreendropStorage.applicationSupportDirectory.resolvingSymlinksInPath().path
        try check(actualHome == isolated && support.hasPrefix(isolated + "/")
                  && home.hasPrefix("/private/tmp/"), "Foundation storage is not isolated: \(actualHome), \(support)")
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await frozenChapterSidecars(in: URL(fileURLWithPath: home))
        let root = URL(fileURLWithPath: home).appendingPathComponent("fixture.screendroprec")
        try check(root.path.hasPrefix("/private/tmp/"), "Harness home is not isolated")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = RecordingSession(directoryURL: root)
        try await movie(at: session.screenURL)
        let original = try Data(contentsOf: session.screenURL)
        let bounds = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let interior = CGRect(x: 0.05, y: 0.05, width: 0.4, height: 0.4)
        let outside = CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3)
        let baseline = try await image(session.screenURL, time: 1)
        let originalDetail = detail(baseline, rect: interior)
        let style = RecordingStudioStyle(background: .none, padding: 0, cornerRadius: 0, shadow: 0,
                                         camera: RecordingCameraBubbleSettings(isVisible: false))
        let timeline = RecordingClipTimeline.full(sourceDuration: 3)
        var settings = VideoCompressionSettings()
        settings.codec = .h264; settings.removeAudio = true; settings.frameRate = .fps30
        var document = RecordingEditDocument(style: style, zoomEnabled: false, zoomCues: [], clipTimeline: timeline, exportSettings: settings)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as! [String: Any]
        legacy.removeValue(forKey: "redactions"); legacy["formatVersion"] = 5
        let decoded = try JSONDecoder().decode(RecordingEditDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(decoded.redactions.isEmpty, "Legacy document decode")
        try session.writeEditDocument(document)
        _ = await ScreenshotHistoryStore.shared.importRecordingSession(session)
        let historyItem = ScreenshotHistoryStore.shared.items.first { $0.recordingSessionPath == root.standardizedFileURL.path }!
        let sharedLink = "https://share.example.invalid/abcd1234"
        ScreenshotHistoryStore.shared.setLibraryCloudURL(id: historyItem.id, cloudURL: sharedLink)
        let editor = RecordingStudioModel(url: root)
        await editor.load()
        try check(editor.isLoaded, "Editor load: \(editor.loadError ?? "")")
        editor.seek(to: 0.5)
        editor.beginRedaction(); editor.workingVideoCropRect = bounds; editor.addRedaction()
        try check(editor.redactions.count == 1 && session.loadDraftDocument()?.redactions.count == 1, "Add/draft")
        try check(editor.needsSharedVideoReplacement, "Legacy shared link must warn after Add")
        editor.undo(); try check(editor.redactions.isEmpty, "Undo redaction")
        try check(!editor.needsSharedVideoReplacement, "Undo Add clears the notice")
        editor.redo(); try check(editor.redactions.count == 1, "Redo redaction")
        var region = editor.redactions[0]
        region.end = 1.5; region.strength = 1
        editor.updateRedaction(region)
        var invalidEdit = region; invalidEdit.end = editor.sourceDuration + 1
        editor.updateRedaction(invalidEdit)
        try check(editor.redactionEditError != nil && editor.redactions == [region], "Invalid input silently ignored or changed masks")
        editor.updateRedaction(region)
        try check(editor.redactionEditError == nil, "Corrected input did not clear the inline error")
        try check(editor.saveProject(reportingFailure: false), "Save redaction")
        document = try session.editDocumentForRendering()!
        let roundTrip = try JSONDecoder().decode(RecordingEditDocument.self, from: JSONEncoder().encode(document))
        try check(roundTrip == document && roundTrip.redactions == [region], "Document roundtrip")
        try check(!RecordingSession.differsOnlyByExportContainer(document, decoded), "Redaction cache identity")
        editor.teardown()
        let reopened = RecordingStudioModel(url: root)
        await reopened.load()
        try check(reopened.isLoaded && reopened.redactions == [region], "Reopen masks")
        try check(reopened.needsSharedVideoReplacement, "Reopening must keep the stale-share notice")
        ScreenshotHistoryStore.shared.recordCloudUpload(id: historyItem.id, cloudURL: sharedLink, redactions: [region])
        try check(!reopened.needsSharedVideoReplacement, "Successful replacement clears the notice")
        let storedItem = ScreenshotHistoryStore.shared.items.first { $0.id == historyItem.id }!
        let diskItems = try JSONDecoder().decode([ScreenshotHistoryItem].self, from: Data(contentsOf:
            ScreendropStorage.applicationSupportDirectory.appendingPathComponent("history.json")))
        try check(diskItems.first { $0.id == historyItem.id } == storedItem, "Uploaded masks were not saved to History")
        let encodedItem = try JSONEncoder().encode(storedItem)
        let restoredItem = try JSONDecoder().decode(ScreenshotHistoryItem.self, from: encodedItem)
        try check(restoredItem.cloudURL == sharedLink && restoredItem.cloudRedactions == [region], "Uploaded masks persist with the same link")
        var legacyItem = try JSONSerialization.jsonObject(with: encodedItem) as! [String: Any]
        legacyItem.removeValue(forKey: "cloudRedactions")
        let legacyHistory = try JSONDecoder().decode(ScreenshotHistoryItem.self, from: JSONSerialization.data(withJSONObject: legacyItem))
        try check(legacyHistory.cloudRedactions == nil && legacyHistory.cloudURL == sharedLink, "Legacy History still loads conservatively")
        var changedRegion = region; changedRegion.strength = 0.7
        reopened.updateRedaction(changedRegion)
        try check(reopened.needsSharedVideoReplacement, "Editing a shared mask warns again")
        reopened.undo()
        try check(!reopened.needsSharedVideoReplacement, "Undo to the uploaded masks clears the notice")
        ScreenshotHistoryStore.shared.setLibraryCloudURL(id: historyItem.id, cloudURL: nil)
        try check(!reopened.needsSharedVideoReplacement, "Deleting the link clears the notice")
        print("PASS shared-video notice add/undo/reopen/replace/edit/delete and History legacy/snapshot persistence")
        for _ in 0..<200 where reopened.isPreparingRedactionPreview { try await Task.sleep(for: .milliseconds(10)) }
        try check(reopened.screenPlayer.currentItem?.videoComposition != nil, "Studio preview filter missing")
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: reopened.screenPlayer.currentItem)
        try check(reopened.redactionPreviewError != nil && reopened.screenPlayer.currentItem == nil, "Preview filter failure exposed old pixels")
        reopened.removeRedaction(region.id); try check(reopened.redactions.isEmpty, "Remove mask")
        reopened.undo(); try check(reopened.redactions == [region], "Undo removal")
        reopened.teardown()
        print("PASS legacy/document/draft/save/reopen/add/remove/undo/redo/cache identity")

        for mode in RecordingRedaction.Mode.allCases {
            region.mode = mode
            document.redactions = [region]
            try session.writeEditDocument(document); session.removeDraftDocument()
            let composition = try await RecordingRedactionFilter.composition(asset: AVURLAsset(url: session.screenURL), redactions: [region])
            for time in [0.0, 0.5, 1.0, 1.5, 2.0] {
                let frame = try await image(session.screenURL, time: time, composition: composition)
                let actual = detail(frame, rect: interior)
                try check(time >= 0.5 && time < 1.5 ? actual < originalDetail * 0.4 : actual > originalDetail * 0.8,
                          "Sparse preview \(mode) at \(time): detail \(actual), raw \(originalDetail)")
                try check(detail(frame, rect: outside) > originalDetail * 0.8, "Preview outside bounds")
            }
            print("PASS sparse \(mode) preview start/end, top-left bounds, outside unchanged")

            var configuration = try await RecordingSessionRenderer.makeConfiguration(for: session)
            try check(configuration.redactions == [region], "Library/export configuration")
            for renderer in ["cpu", "metal"] {
                setenv("SCREENDROP_EXPORT_RENDERER", renderer, 1)
                configuration.exportSettings.container = renderer == "cpu" ? .mov : .mp4
                let output = try await RecordingStudioExporter().export(configuration) { _ in }
                for time in [0.0, 0.5, 1.0, 1.5, 2.0] {
                    let frame = try await image(output, time: time)
                    let actual = detail(frame, rect: interior)
                    try check(time >= 0.5 && time < 1.5 ? actual < originalDetail * 0.4 : actual > originalDetail * 0.7,
                              "Export \(renderer) \(mode) \(time): detail \(actual), raw \(originalDetail)")
                    try check(detail(frame, rect: outside) > originalDetail * 0.7, "Export outside bounds")
                }
                let gif = root.appendingPathComponent("\(mode)-\(renderer).gif")
                try await RecordingGIFExport.write(movie: output, to: gif, frameRate: .fps10, width: .original)
                let gifSource = CGImageSourceCreateWithURL(gif as CFURL, nil)!
                let gifFrame = CGImageSourceCreateImageAtIndex(gifSource, 10, nil)!
                try check(detail(gifFrame, rect: interior) < originalDetail * 0.4, "GIF mask")
                print("PASS \(renderer) \(mode) MOV/MP4/GIF pixels and static cache boundaries")
            }
        }
        unsetenv("SCREENDROP_EXPORT_RENDERER")
        let dragFolder = root.appendingPathComponent("drag")
        try FileManager.default.createDirectory(at: dragFolder, withIntermediateDirectories: true)
        let dragged = try await CaptureDragExport(url: session.screenURL, isVideo: true).export(to: dragFolder, contentType: .movie)
        let dragFrame = try await image(dragged, time: 1)
        try check(detail(dragFrame, rect: interior) < originalDetail * 0.4, "Drag exported the master")
        print("PASS native drag transfer resolves redacted deliverable")
        var posterRegion = region; posterRegion.start = 0
        document.redactions = [posterRegion]
        try session.writeEditDocument(document)
        let poster = await CaptureLibraryThumbnails.shared.image(at: session.screenURL, isVideo: true)
        try check(poster != nil && detail(poster!, rect: interior) < originalDetail * 0.4, "Library poster or stale thumbnail cache")
        try check(Data(contentsOf: session.screenURL) == original, "Original movie changed")

        try Data("broken".utf8).write(to: session.draftDocumentURL)
        do { _ = try await RecordingSessionRenderer.ensureDeliverable(for: session); throw Failure.check("Unreadable draft rendered") }
        catch is DecodingError { }
        let unsafePoster = await CaptureLibraryThumbnails.shared.image(at: session.screenURL, isVideo: true)
        try check(unsafePoster == nil, "Unreadable draft poster fallback")
        session.removeDraftDocument()
        var invalid = region; invalid.rect = .zero
        document.redactions = [invalid]
        try session.writeEditDocument(document)
        do { _ = try await RecordingSessionRenderer.ensureDeliverable(for: session); throw Failure.check("Invalid region rendered") }
        catch is RecordingRedactionError { }
        print("PASS unreadable/invalid edits reject deliverable and poster; original bytes unchanged")
    }
}
