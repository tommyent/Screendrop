import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Built against the actual app sources by check-editor-idle-save.py.
@main
struct IdleSaveChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }

    @MainActor static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            try check(ContinuousClock.now < deadline, "Timed out waiting for a save transition")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @MainActor final class Gate {
        var snapshots: [AnnotationSaveSnapshot] = []
        var continuation: CheckedContinuation<Void, Never>?
        var hold = true
        var active = 0
        var maximumActive = 0

        func render(_ snapshot: AnnotationSaveSnapshot) async throws -> URL {
            active += 1
            maximumActive = max(active, maximumActive)
            defer { active -= 1 }
            snapshots.append(snapshot)
            if hold { await withCheckedContinuation { continuation = $0 } }
            return try await snapshot.render()
        }

        func resume() {
            hold = false
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor static func png(width: Int = 200, height: Int = 100) throws -> Data {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "Cannot allocate fixture bitmap")
        }
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for y in stride(from: 0, to: height, by: 37) {
            context.setFillColor(CGColor(red: 0.2, green: CGFloat(y % 255) / 255, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 20, y: y, width: width - 40, height: 8))
        }
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil),
              let image = context.makeImage() else { throw Failure(description: "Cannot encode fixture") }
        CGImageDestinationAddImage(writer, image, nil)
        try check(CGImageDestinationFinalize(writer), "Fixture PNG failed")
        return data as Data
    }

    @MainActor static func fixture(_ gate: Gate) throws -> AnnotationEditorModel {
        let directory = ScreenshotHistoryStore.historyDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("idle-save-\(UUID()).png")
        try png().write(to: source)
        let model = AnnotationEditorModel(renderSave: gate.render)
        model.sourceURL = source
        model.baseImageURL = source
        model.imageSize = CGSize(width: 200, height: 100)
        model.updateViewport(imageFrame: CGRect(x: 0, y: 0, width: 200, height: 100))
        model.markSaved()
        model.engine.replaceDocument(shapes: [rect()])
        return model
    }

    static func rect(x: Double = 10) -> AnnoShape {
        AnnoShape(x: x, y: 10, kind: .geo(GeoProps(w: 40, h: 30)))
    }

    @MainActor static func sessionStoreRetention() throws {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("SessionStore")
        let store = CaptureSessionSnapshots(directory: directory)
        try check(try store.entries().isEmpty, "Empty store made entries")
        let sibling = URL(fileURLWithPath: ScreenshotHistoryStore.historyDirectory.path + "-outside/capture.png")
        try check(!ScreenshotHistoryStore.shared.isHistoryURL(sibling), "History prefix accepted a sibling directory")
        let firstBase = directory.deletingLastPathComponent().appendingPathComponent("first-base.png")
        let secondBase = directory.deletingLastPathComponent().appendingPathComponent("same-base.png")
        try png().write(to: firstBase)
        try FileManager.default.copyItem(at: firstBase, to: secondBase)
        var published: [CaptureSessionSnapshot] = []
        for index in 0..<7 {
            let entries = try store.keep(document: Data("{\"state\":\(index)}".utf8), baseImage: firstBase,
                                         openedAt: Date(timeIntervalSince1970: Double(index)))
            published.append(entries[0])
        }
        let kept = try store.entries()
        try check(kept.count == 5 && kept.first == published[6] && kept.last == published[2], "Five-session limit/order failed")
        try check(Set(published.map(\.title)).count == published.count, "Sessions within one minute had identical labels")
        for entry in published.prefix(2) {
            try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.id.uuidString).path), "Old session wasn't pruned")
        }
        let deduped = try store.keep(document: Data("{\"state\":6}".utf8), baseImage: secondBase, openedAt: Date())
        try check(deduped == kept, "Identical state at another path created a duplicate")
        try png(width: 220).write(to: secondBase)
        let changed = try store.keep(document: Data("{\"state\":6}".utf8), baseImage: secondBase, openedAt: Date())
        try check(changed.count == 5 && changed[0].id != kept[0].id, "Changed base pixels were deduplicated")
        do {
            _ = try store.keep(document: Data(), baseImage: directory.appendingPathComponent("missing.png"), openedAt: Date())
            throw Failure(description: "Missing base was published")
        } catch is Failure { throw Failure(description: "Missing base was published") } catch {}
        let afterFailure = try store.entries()
        try check(afterFailure == changed, "Failed copy displaced a complete session")
        print("PASS session store: newest-first, five kept, old folders pruned, content dedupe, changed pixels, failed copy preserves history")
    }

    @MainActor static func openImage(_ url: URL) throws -> AnnotationEditorModel {
        let model = AnnotationEditorModel()
        model.load(url: url, dismiss: EnvironmentValues().dismiss)
        try check(model.errorMessage == nil && model.imageSize.width > 0, "Image fixture didn't load: \(model.errorMessage ?? "empty image")")
        model.updateViewport(imageFrame: CGRect(origin: .zero, size: model.imageSize))
        return model
    }

    @MainActor static func sessionImageRestore() async throws {
        let directory = ScreenshotHistoryStore.historyDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("sessions-\(UUID()).png")
        let captured = try png()
        try captured.write(to: source)
        let store = CaptureSessionSnapshots(directory: ScreenshotHistoryStore.sessionSnapshotsURL(for: source))
        let untouched = try openImage(source)
        untouched.releaseEditorResources()
        try check(!FileManager.default.fileExists(atPath: store.directory.path), "Open/close without an edit kept a session")

        let first = try openImage(source)
        first.engine.replaceDocument(shapes: [rect()])
        try check(first.sessionSnapshots.count == 1 && first.previousSessionSnapshots.isEmpty, "Image menu repeated this session's Last Opened state")
        _ = try await first.commitEdits()
        first.releaseEditorResources()
        try check(try store.entries().count == 1, "Edit/close didn't keep exactly one opening state")
        let originalEntry = try store.entries()[0]

        let second = try openImage(source)
        try check(second.previousSessionSnapshots == [originalEntry], "Reopening didn't expose the earlier image session")
        second.isCropping = true
        second.cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        second.applyCrop()
        try check(second.sessionSnapshots.count == 2 && second.previousSessionSnapshots == [originalEntry], "Image menu didn't keep only previous sessions after the crop")
        _ = try await second.commitEdits()
        let croppedShapes = second.shapes
        let croppedPixels = try Data(contentsOf: source)
        second.releaseEditorResources()

        let third = try openImage(source)
        try check(third.imageSize.width == 100 && third.shapes == croppedShapes, "Cropped opening state was wrong")
        var moved = third.shapes
        moved[0].x += 10
        third.engine.replaceDocument(shapes: moved)
        _ = try await third.commitEdits()
        third.releaseEditorResources()
        let croppedEntry = try store.entries()[0]

        let restored = try openImage(source)
        restored.revertToSession(croppedEntry)
        try check(restored.errorMessage == nil && restored.shapes == croppedShapes && restored.imageSize.width == 100,
                  "Session restore lost cropped pixels/marks")
        restored.undo()
        try check(restored.shapes == moved && restored.imageSize.width == 100, "One Undo didn't recover work after restore")
        restored.redo()
        try await until { !restored.hasUnsavedChanges && restored.saveStatus == "Saved" }
        let restoredPixels = try Data(contentsOf: source)
        try check(restoredPixels == croppedPixels, "Auto-saved restored composite differs from the earlier crop")
        // The newest snapshot is this window's opening state. Another edit in
        // that same state in a new window must not record it again.
        restored.undo()
        _ = try await restored.commitEdits()
        restored.releaseEditorResources()
        let beforeDedupe = try store.entries()
        let reopened = try openImage(source)
        try check(reopened.previousSessionSnapshots == beforeDedupe, "Reopening hid an earlier kept session")
        reopened.engine.replaceDocument(shapes: croppedShapes)
        _ = try await reopened.commitEdits()
        try check(try store.entries() == beforeDedupe, "Reopening the newest kept state created a duplicate")
        try check(reopened.previousSessionSnapshots == beforeDedupe, "Deduplication hid a different session with an identical opening state")
        // Untouched capture snapshots must use the original bytes and clear edits.
        reopened.revertToSession(originalEntry)
        try await until { !reopened.hasUnsavedChanges && reopened.saveStatus == "Saved" }
        let originalPixels = try Data(contentsOf: source)
        try check(originalPixels == captured && !ScreenshotHistoryStore.shared.hasEditDocument(for: source), "Original session re-rendered or stayed edited")
        reopened.releaseEditorResources()
        print("PASS image sessions: unedited opens keep nothing, edit/close keeps one, cropped pixels+marks, one Undo/Redo, auto-save, dedupe, original bytes")
    }

    @MainActor static func sessionPrunedRestoreAndPictures() async throws {
        let gate = Gate(), model = try fixture(gate)
        gate.hold = false
        let source = model.sourceURL!
        let asset = AnnoImageAsset(data: try png(width: 20, height: 12))!
        let imageID = model.engine.insertImage(asset, assetID: "session-picture")
        _ = try await model.commitEdits()
        model.releaseEditorResources()
        let withPicture = try openImage(source)
        let pictureShapes = withPicture.shapes
        withPicture.engine.replaceDocument(shapes: [rect(x: 30)])
        _ = try await withPicture.commitEdits()
        withPicture.releaseEditorResources()
        let store = CaptureSessionSnapshots(directory: ScreenshotHistoryStore.sessionSnapshotsURL(for: source))
        let pictureEntry = try store.entries()[0]
        // Fill the remaining places so this restore's first edit prunes the
        // very entry it chose. Its image must already belong to Undo history.
        for index in 0..<4 {
            _ = try store.keep(document: Data("filler-\(index)".utf8), baseImage: source,
                               openedAt: pictureEntry.openedAt.addingTimeInterval(Double(index + 1)))
        }
        let current = try openImage(source)
        try check(current.engine.imageAssets["session-picture"] == nil, "Picture fixture already had the missing asset")
        current.revertToSession(pictureEntry)
        try check(current.errorMessage == nil && current.shapes == pictureShapes && current.shapes.contains(where: { $0.id == imageID })
                  && current.engine.imageAssets["session-picture"] != nil, "Snapshot didn't restore pasted picture bytes")
        try check(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(pictureEntry.id.uuidString).path), "Restored oldest entry wasn't pruned")
        current.undo()
        try check(current.shapes.count == 1 && current.shapes[0].x == 30, "Pruned restore Undo lost the newer work")
        current.redo()
        _ = try await current.commitEdits()
        let document = try ScreenshotHistoryStore.shared.loadEditDocument(for: source)
        try check(document?.images["session-picture"] == asset.data, "Save dropped restored picture bytes")
        current.releaseEditorResources()
        let reopened = try openImage(source)
        try check(reopened.shapes == pictureShapes && reopened.engine.imageAssets["session-picture"] != nil, "Saved picture restore didn't reopen")
        reopened.releaseEditorResources()
        print("PASS restoring an entry pruned by the same edit: owned crop pixels, Undo/Redo, missing pasted picture assets, save/reopen")
    }

    @MainActor static func sessionTrash() throws {
        let gate = Gate(), model = try fixture(gate), source = model.sourceURL!
        model.releaseEditorResources()
        let snapshots = ScreenshotHistoryStore.sessionSnapshotsURL(for: source)
        let item = CaptureLibraryItem(id: "trash-session", historyIDs: [], name: source.lastPathComponent, customName: nil,
            fileURL: source, session: nil, createdAt: Date(), modifiedAt: Date(), pixelWidth: 200, pixelHeight: 100,
            duration: nil, isVideo: false, hasEdits: true, hasDraft: false, cloudURL: nil, tags: [], thumbnailKey: "session")
        try check(item.ownedFileURLs.contains(snapshots) && CaptureLibraryScanner.sizeOnDisk(of: snapshots) > 0, "Snapshots omitted from ownership/Size on Disk")
        let trash = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("FixtureTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try CaptureLibraryFiles.trash(item) { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        try check(!FileManager.default.fileExists(atPath: source.path) && !FileManager.default.fileExists(atPath: snapshots.path), "Trash left snapshot companions behind")
        let trashedStore = CaptureSessionSnapshots(directory: trash.appendingPathComponent(snapshots.lastPathComponent))
        try check(try trashedStore.entries().count == 1, "Trash lost the snapshot contents")
        print("PASS Library Trash moves capture and session folder; recursive Size on Disk includes snapshots (isolated destination)")
    }

    @MainActor static func studioSessionRestore() async throws {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("StudioSessions.screendroprec")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = RecordingSession(directoryURL: root)
        let writer = try AVAssetWriter(outputURL: session.screenURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90
        ])
        writer.add(input)
        try check(writer.startWriting(), "Fixture writer failed")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            try await until { input.isReadyForMoreMediaData || writer.status != .writing }
            var buffer: CVPixelBuffer?
            try check(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess, "Fixture frame allocation failed")
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), 0x88, CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            try check(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)), "Fixture frame append failed")
        }
        input.markAsFinished()
        await writer.finishWriting()
        try check(writer.status == .completed, "Fixture movie failed")
        let noEdit = RecordingStudioModel(url: root)
        await noEdit.load()
        try check(noEdit.isLoaded && noEdit.loadError == nil, "Studio fixture didn't load")
        noEdit.teardown()
        try check(!FileManager.default.fileExists(atPath: session.sessionSnapshotsURL.path), "Studio unedited open kept a session")

        let first = RecordingStudioModel(url: root)
        await first.load()
        let originalPadding = first.style.padding
        first.style.padding += 12
        try check(first.sessionSnapshots.count == 1 && first.saveProject(reportingFailure: false), "Studio first real edit wasn't kept/saved")
        try check(first.previousSessionSnapshots.isEmpty, "Studio menu repeated this session's Last Opened state")
        let firstEntry = first.sessionSnapshots[0]
        first.teardown()

        let second = RecordingStudioModel(url: root)
        await second.load()
        try check(second.previousSessionSnapshots == [firstEntry], "Reopening didn't expose the earlier Studio session")
        second.style.padding += 24
        try check(second.saveProject(reportingFailure: false) && second.sessionSnapshots.count == 2, "Studio second session wasn't kept")
        try check(second.previousSessionSnapshots == [firstEntry], "Studio menu didn't keep only previous sessions after editing")
        let laterPadding = second.style.padding
        second.revertToSession(firstEntry)
        try check(second.style.padding == originalPadding && second.canUndo, "Studio snapshot restore failed")
        second.undo()
        try check(second.style.padding == laterPadding, "Studio snapshot wasn't one Undo step")
        second.redo()
        try await until { !second.hasUnsavedChanges && second.saveStatus == "Saved" }
        try check(session.loadEditDocument()?.style.value.padding == originalPadding, "Studio snapshot didn't auto-save")
        second.revertToSession(second.sessionSnapshots[0])
        try await until { !second.hasUnsavedChanges && second.saveStatus == "Saved" }
        second.teardown()
        let third = RecordingStudioModel(url: root)
        await third.load()
        let before = third.sessionSnapshots
        let unchangedZoom = third.zoomEnabled
        third.zoomEnabled = unchangedZoom // didSet without a real change
        try check(third.sessionSnapshots == before, "Studio no-op assignment kept a snapshot")
        third.style.padding += 6
        try check(third.sessionSnapshots == before, "Studio duplicated the newest opening state")
        try check(third.previousSessionSnapshots == before, "Studio deduplication hid a different session with an identical opening state")
        // Soundtrack cleanup must see saved sessions, even when the current
        // edit no longer references their imported audio.
        var soundtrackDocument = session.loadEditDocument()!
        let name = "\(RecordingSession.replacementAudioBaseName).kept.wav"
        soundtrackDocument.replacementAudioFileName = name
        let keptAudio = root.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: keptAudio)
        let unusedAudio = root.appendingPathComponent("\(RecordingSession.replacementAudioBaseName).unused.wav")
        try Data([4, 5]).write(to: unusedAudio)
        _ = try CaptureSessionSnapshots(directory: session.sessionSnapshotsURL).keep(
            document: CaptureSessionSnapshots.encode(soundtrackDocument), openedAt: Date())
        try check(third.saveProject(reportingFailure: false), "Studio soundtrack cleanup fixture didn't save")
        third.teardown()
        try check(FileManager.default.fileExists(atPath: keptAudio.path) && !FileManager.default.fileExists(atPath: unusedAudio.path), "Studio cleanup deleted a snapshot's soundtrack or retained unused audio")
        let failed = RecordingStudioModel(url: root)
        await failed.load()
        let savedBytes = try Data(contentsOf: session.editDocumentURL)
        let backup = root.appendingPathComponent("sessions-backup")
        try FileManager.default.moveItem(at: session.sessionSnapshotsURL, to: backup)
        try Data([0]).write(to: session.sessionSnapshotsURL) // a file blocks the snapshot directory
        failed.audioVolume = 0.7
        failed.flushDraft()
        try check(failed.saveStatus == "Not Saved" && !failed.saveProject(reportingFailure: false), "Studio snapshot failure didn't report/block the save")
        try check(try Data(contentsOf: session.editDocumentURL) == savedBytes && !session.hasUnsavedDraft, "Snapshot failure overwrote Studio's opening state")
        try FileManager.default.moveItem(at: session.sessionSnapshotsURL, to: root.appendingPathComponent("failed-marker"))
        try FileManager.default.moveItem(at: backup, to: session.sessionSnapshotsURL)
        try check(failed.saveProject(reportingFailure: false), "Studio couldn't retry after snapshot storage recovered")
        failed.teardown()
        print("PASS Studio sessions: no-edit boundary, first edit, dated restore, one Undo/Redo, auto-save, no-op/dedupe and snapshot soundtrack retention")
        print("PASS snapshot storage failure blocks draft/commit, reports Not Saved, preserves disk edits and retries after recovery")
    }

    @MainActor static func savesOnlyRefreshExistingPreviews() async throws {
        let directory = ScreenshotHistoryStore.historyDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("preview-original.png")
        let edited = directory.appendingPathComponent("preview-edited.png")
        let latest = directory.appendingPathComponent("preview-latest.png")
        try png().write(to: original)
        try png(width: 240).write(to: edited)
        let latestPixels = try png(width: 280)
        try latestPixels.write(to: latest)
        let exports = directory.appendingPathComponent("Exports", isDirectory: true)
        UserDefaults.standard.setVolatileDomain([
            ScreendropPreferences.autoCopyKey: true,
            ScreendropPreferences.autoSaveKey: true,
            ScreendropPreferences.exportDirectoryPathKey: exports.path,
            ScreendropPreferences.exportFormatKey: "png"
        ], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
        var copies: [URL] = []
        let stack = ScreenshotPreviewStack(copyImage: { copies.append($0) })
        stack.isCollapsed = true
        let missing = await stack.applyAnnotation(originalURL: original, historyURL: edited)
        try check(!missing && stack.items.isEmpty && stack.isCollapsed && copies.isEmpty, "Save inserted a card, expanded the overlay or copied a missing preview")
        try check(!FileManager.default.fileExists(atPath: exports.path), "Missing preview save created an export")

        await stack.previewExistingImage(url: original)
        guard let id = stack.items.first?.id else { throw Failure(description: "Cannot seed preview fixture") }
        stack.collapse()
        let explicit = await stack.applyAnnotation(originalURL: original, historyURL: edited)
        guard let export = stack.items.first?.autoSavedURL else { throw Failure(description: "Explicit save did not publish its export") }
        try check(explicit && copies == [edited], "Explicit save didn't republish the existing preview")
        let idle = await stack.applyAnnotation(originalURL: edited, historyURL: latest, updatesClipboard: false)
        try check(idle && stack.items.count == 1 && stack.items[0].id == id && stack.items[0].url == latest && stack.isCollapsed, "Idle save inserted/replaced a card or expanded the overlay")
        try check(copies == [edited], "Idle save touched the clipboard with auto-copy enabled")
        let exportedPixels = try Data(contentsOf: export)
        try check(exportedPixels == latestPixels, "Idle save left the existing export stale")
        let unrelated = await stack.applyAnnotation(originalURL: original, historyURL: edited, updatesClipboard: false)
        try check(!unrelated && stack.items.count == 1 && copies == [edited], "Save inserted a missing card beside an existing card")
        print("PASS no insert/expansion on saves, idle refresh without clipboard writes, explicit republish and export synchronization")
    }

    @MainActor static func titleFieldFocusSelectionAndCommands() async throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for command in ["return", "escape", "blur"] {
            let field = AnnotationTitleNSTextField(frame: CGRect(x: 10, y: 50, width: 320, height: 24))
            field.stringValue = "Existing 🖼 name"
            var draft = field.stringValue, commits = 0, cancels = 0
            field.onChange = { draft = $0 }
            field.onCommit = { commits += 1 }
            field.onCancel = { cancels += 1 }
            window.contentView?.addSubview(field)
            try await until { field.currentEditor() != nil }
            guard let editor = field.currentEditor() as? NSTextView else { throw Failure(description: "Title field has no text editor") }
            try check(window.firstResponder === editor && !window.isVisible, "Title field didn't focus off-screen")
            try check(commits == 0 && cancels == 0, "Focusing/selecting the title ended its edit before typing")
            try check(editor.selectedRange() == NSRange(location: 0, length: field.stringValue.utf16.count), "Existing title wasn't fully selected")
            guard let accessible = NSAccessibility.unignoredDescendant(of: field) as? any NSAccessibilityProtocol else {
                throw Failure(description: "Title field has no exposed accessibility element")
            }
            try check(accessible.accessibilityRole() == .textField && accessible.accessibilityLabel() == "Name", "Title field lost native accessibility semantics")
            editor.insertText("Replacement", replacementRange: editor.selectedRange())
            try check(draft == "Replacement" && field.stringValue == draft, "Typing didn't replace the selected title/update the draft")
            if command == "blur" {
                window.makeFirstResponder(nil)
            } else {
                editor.doCommand(by: command == "return" ? #selector(NSResponder.insertNewline(_:)) : #selector(NSResponder.cancelOperation(_:)))
            }
            try check(commits == (command == "escape" ? 0 : 1) && cancels == (command == "escape" ? 1 : 0), "Title \(command) took the wrong completion path")
            AnnotationTitleNameField.dismantleNSView(field, coordinator: ())
            field.removeFromSuperview()
            try check(commits + cancels == 1, "Title teardown committed a cancelled/completed edit again")
        }
        print("PASS native title field attachment focus, full-name selection, typing, AX semantics, Return/Escape/blur and teardown")
    }

    @MainActor static func recordingRenameIsOnlyMetadata() throws {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = RecordingSession(directoryURL: directory), store = RecordingProjectStore.shared
        store.rename(session, to: "  Demo take \n")
        try check(session.customName == "Demo take" && session.displayName == "Demo take", "Recording rename didn't trim or persist")
        // Writes are atomic, so a rewrite with the same bytes still replaces the file.
        let inode = { try FileManager.default.attributesOfItem(atPath: session.projectMetadataURL.path)[.systemFileNumber] as? Int }
        let written = try inode()
        store.rename(session, to: "Demo take")
        let unchanged = try inode()
        try check(written != nil && unchanged == written, "Unchanged recording rename rewrote metadata")
        store.rename(session, to: " \n ")
        try check(session.customName == nil && session.displayName == directory.lastPathComponent, "Empty recording rename didn't restore the default name")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try check(files == [RecordingSession.projectMetadataFileName], "Recording rename wrote more than its metadata")
        print("PASS recording rename: trim, no-op, clear to the default name, metadata only")
    }

    @MainActor static func studioStyleTransfer() throws {
        let store = RecordingStudioStylePresetStore.shared
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("styles-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ data: Data, _ name: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }

        let style = RecordingStudioStyle(
            background: .gradient(AnnotationBackgroundGradient.presets[0]), padding: 0.1, cornerRadius: 0.05,
            shadow: 0.3, cursorScale: 2.5, hidesCursor: true,
            camera: RecordingCameraBubbleSettings(isVisible: false, center: CGPoint(x: 0.2, y: 0.7), size: 0.3, roundness: 0.4)
        )
        guard let saved = store.savePreset(named: "Dawn \(UUID().uuidString.prefix(4))", style: style) else {
            throw Failure(description: "Couldn't save the Studio style fixture")
        }
        let exported = try store.exportedData(for: saved.id)
        let imported = try store.importStyles(from: write(exported.data, "dawn.screendroppreset"))
        try check(!exported.omitsWallpaper && imported.omittedWallpaperCount == 0 && imported.presets.count == 1,
                  "A Studio style export or import miscounted")
        try check(imported.presets[0].value == style && imported.presets[0].name != saved.name,
                  "A Studio style didn't round-trip under a fresh name")

        var walledStyle = style
        walledStyle.background = .customWallpaper(AnnotationCustomWallpaper(url: folder.appendingPathComponent("wall.png")))
        let walled = RecordingStudioStyleTransferFile(preset: RecordingStudioStylePreset(name: "Walled", style: walledStyle))
        let walledImport = try store.importStyles(from: write(walled.encodedData(), "walled.screendroppreset"))
        try check(walledImport.omittedWallpaperCount == 1 && walledImport.presets[0].value.background == .none,
                  "A local wallpaper went into a shared Studio style")

        // Each editor names the other's files rather than misreading them.
        let shot = AnnotationBackgroundPresetTransferFile(
            preset: AnnotationBackgroundPreset(name: "Shot", settings: AnnotationBackgroundSettings())
        )
        do {
            _ = try store.importStyles(from: write(shot.encodedData(), "shot.screendroppreset"))
            throw Failure(description: "Studio imported a screenshot style")
        } catch AnnotationBackgroundPresetTransferError.screenshotStyle {}
        do {
            _ = try AnnotationBackgroundPresetStore.shared.importStyles(from: write(exported.data, "dawn-2.screendroppreset"))
            throw Failure(description: "The image editor imported a Studio style")
        } catch AnnotationBackgroundPresetTransferError.recordingStyle {}

        // The image editor's own styles still round-trip after the shared background code.
        let editorStore = AnnotationBackgroundPresetStore.shared
        var settings = AnnotationBackgroundSettings()
        settings.style = .gradient(AnnotationBackgroundGradient.presets[0])
        guard let editorSaved = editorStore.savePreset(named: "Shot \(UUID().uuidString.prefix(4))", settings: settings) else {
            throw Failure(description: "Couldn't save the screenshot style fixture")
        }
        let editorExported = try editorStore.exportedData(for: editorSaved.id)
        let editorImported = try editorStore.importStyles(from: write(editorExported.data, "shot-2.screendroppreset"))
        try check(editorImported.presets.count == 1 && editorImported.presets[0].settings.style == settings.style,
                  "A screenshot style didn't round-trip")

        for preset in [saved] + imported.presets + walledImport.presets { store.deletePreset(id: preset.id) }
        for preset in [editorSaved] + editorImported.presets { editorStore.deletePreset(id: preset.id) }
        print("PASS style export and import: Studio and editor round trips, wallpaper left out, each editor refuses the other's file")
    }

    @MainActor static func titleRenameIsOnlyMetadata() async throws {
        let gate = Gate(), model = try fixture(gate), store = ScreenshotHistoryStore.shared
        gate.hold = false
        let source = store.importScreenshot(from: model.sourceURL!)
        model.sourceURL = source
        model.baseImageURL = source
        _ = try await model.commitEdits()
        guard let item = store.item(for: source) else { throw Failure(description: "Missing rename fixture") }
        let pixels = try Data(contentsOf: source)
        let sidecar = try Data(contentsOf: ScreenshotHistoryStore.editDocumentURL(for: source))
        let revision = model.revision

        AnnotationEditorTitle.rename(item, to: "  Named capture \n")
        store.reload()
        guard let named = store.item(for: source) else { throw Failure(description: "Rename lost History item") }
        try check(named.displayName == "Named capture" && named.fileName == item.fileName, "Rename changed the History file key or didn't persist")
        AnnotationEditorTitle.rename(named, to: "Named capture")
        AnnotationEditorTitle.rename(nil, to: "External file")
        try check(store.item(for: source) == named, "Unchanged/external rename wrote metadata")
        AnnotationEditorTitle.rename(named, to: " \n ")
        store.reload()
        try check(store.item(for: source)?.displayName == nil, "Empty rename didn't restore the date fallback")
        try await Task.sleep(for: .milliseconds(2100))
        let afterPixels = try Data(contentsOf: source)
        let afterSidecar = try Data(contentsOf: ScreenshotHistoryStore.editDocumentURL(for: source))
        try check(afterPixels == pixels && afterSidecar == sidecar, "Rename changed capture/annotation files")
        try check(model.revision == revision && !model.hasUnsavedChanges && model.saveStatus == "Saved", "Rename marked annotations edited")
        try check(gate.snapshots.count == 1 && !model.isCommitting, "Rename started an annotation save")
        model.releaseEditorResources()
        print("PASS title metadata rename, clear, no-op, external file, persistence, unchanged files/status and no idle render")
    }

    @MainActor static func cropDuringRender() async throws {
        let gate = Gate(), model = try fixture(gate)
        let saving = Task { try await model.commitEdits(idle: true) }
        try await until { gate.continuation != nil }
        try check(model.isCommitting && !model.isBlockingCommit, "Idle render blocked input")
        model.isCropping = true
        model.cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        model.applyCrop()
        let crop = model.baseImageURL
        gate.resume()
        _ = try await saving.value
        try check(model.baseImageURL == crop && model.imageSize.width == 100, "Save replaced a newer crop")
        try check(model.hasUnsavedChanges && model.saveStatus == "Edited", "New crop was marked saved")
        model.undo()
        try check(!model.hasUnsavedChanges, "Undo to the captured state must be clean")
        model.redo()
        try check(model.baseImageURL == crop && model.hasUnsavedChanges, "Crop redo was damaged")
        model.releaseEditorResources()
        print("PASS crop during render, saved baseline, undo and redo")
    }

    @MainActor static func savedCropKeepsOriginal() async throws {
        let gate = Gate(), model = try fixture(gate)
        gate.hold = false
        let source = model.sourceURL!, captured = try Data(contentsOf: source)
        let base = ScreenshotHistoryStore.baseImageURL(for: source)
        let original = ScreenshotHistoryStore.originalImageURL(for: source)
        model.isCropping = true
        model.cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        model.applyCrop()
        _ = try await model.commitEdits()
        model.releaseEditorResources()
        try check(ScreenshotImageLoader.imageSize(at: source)?.width == 100
                  && ScreenshotImageLoader.imageSize(at: base)?.width == 100, "The crop wasn't saved")
        let kept = try Data(contentsOf: original)
        try check(kept == captured, "Saving a crop lost the original pixels")

        // A later session draws on the cropped base; the original stays as captured.
        let reopened = AnnotationEditorModel(renderSave: gate.render)
        reopened.sourceURL = source
        reopened.baseImageURL = base
        reopened.imageSize = CGSize(width: 100, height: 100)
        reopened.updateViewport(imageFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        reopened.markSaved()
        reopened.engine.replaceDocument(shapes: [rect(x: 20)])
        _ = try await reopened.commitEdits()
        reopened.releaseEditorResources()
        let keptAgain = try Data(contentsOf: original)
        try check(keptAgain == captured, "A later save replaced the original")
        print("PASS a saved crop keeps the original's bytes after the editor closes and through a later save")
    }

    @MainActor static func revertToOriginalAndLastOpened() async throws {
        let store = ScreenshotHistoryStore.shared
        func size(_ url: URL?) -> CGFloat? { url.flatMap { ScreenshotImageLoader.imageSize(at: $0)?.width } }

        // Original: after a saved crop, back to the capture, as one undo step.
        let gate = Gate(), model = try fixture(gate)
        gate.hold = false
        let source = model.sourceURL!, captured = try Data(contentsOf: source)
        let base = ScreenshotHistoryStore.baseImageURL(for: source)
        let sidecar = ScreenshotHistoryStore.editDocumentURL(for: source)
        let original = ScreenshotHistoryStore.originalImageURL(for: source)
        model.isCropping = true
        model.cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        model.applyCrop()
        _ = try await model.commitEdits()
        try check(model.canRevertToOriginal, "Original was off after a saved crop")
        model.revertToOriginal()
        try check(model.baseImageURL == original && model.shapes.isEmpty && model.imageSize.width == 200
                  && !model.isCropped && model.hasUnsavedChanges, "Revert to Original didn't show the capture")
        try check(!model.canRevertToOriginal, "Original stayed on at the original")
        model.undo()
        try check(model.imageSize.width == 100 && !model.shapes.isEmpty, "Undo didn't bring the crop and marks back")
        model.redo()
        _ = try await model.commitEdits()
        let display = try Data(contentsOf: source), kept = try Data(contentsOf: original)
        try check(display == captured && kept == captured, "Saving the revert didn't restore the captured pixels")
        try check(!FileManager.default.fileExists(atPath: base.path) && !FileManager.default.fileExists(atPath: sidecar.path)
                  && store.hasEditDocument(for: source) == false, "The revert left edits to open")
        model.releaseEditorResources()

        // Last Opened: drawn, saved and cropped since opening, back to how it opened.
        let gate2 = Gate(), opened = try fixture(gate2)
        gate2.hold = false
        let source2 = opened.sourceURL!, captured2 = try Data(contentsOf: source2)
        _ = try await opened.commitEdits()
        opened.isCropping = true
        opened.cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        opened.applyCrop()
        try check(opened.canRevertToLastOpened, "Last Opened was off after edits")
        opened.revertToLastOpened()
        try check(opened.shapes.isEmpty && opened.imageSize.width == 200 && size(opened.baseImageURL) == 200
                  && !opened.canRevertToLastOpened, "Revert to Last Opened didn't return to the opened state")
        _ = try await opened.commitEdits()
        let display2 = try Data(contentsOf: source2)
        try check(display2 == captured2, "Saving Last Opened didn't restore the opened pixels")
        opened.undo()
        try check(opened.imageSize.width == 100, "Undo didn't bring the crop back")
        opened.releaseEditorResources()

        // The Library's revert, on disk: a saved crop back to the capture.
        let gate3 = Gate(), library = try fixture(gate3)
        gate3.hold = false
        let source3 = library.sourceURL!, captured3 = try Data(contentsOf: source3)
        library.isCropping = true
        library.cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        library.applyCrop()
        _ = try await library.commitEdits()
        library.releaseEditorResources()
        try store.revertToOriginal(displayURL: source3)
        let display3 = try Data(contentsOf: source3)
        try check(display3 == captured3 && !store.hasEditDocument(for: source3)
                  && FileManager.default.fileExists(atPath: ScreenshotHistoryStore.originalImageURL(for: source3).path),
                  "The Library's revert didn't restore the capture and keep its original")
        print("PASS Revert To Original and Last Opened: one undo step each, saved as the captured or opened pixels; Library revert on disk")
    }

    @MainActor static func editStateIgnoresHover() async throws {
        let gate = Gate(), model = try fixture(gate)
        gate.hold = false
        _ = try await model.commitEdits()
        let saved = model.editState, revision = model.revision
        model.engine.setHoveredShape(model.shapes.first?.id)
        model.engine.selectAll()
        try check(model.revision != revision && model.editState == saved, "Hover or selection counted as an edit")
        model.backgroundSettings.padding += 0.05
        try check(model.editState != saved, "A background change didn't count as an edit")
        model.backgroundSettings.padding -= 0.05
        model.engine.replaceDocument(shapes: [rect(x: 60)])
        try check(model.editState != saved, "A shape change didn't count as an edit")
        model.releaseEditorResources()
        print("PASS edit state: hover and selection aren't edits; shape and background changes are")
    }

    @MainActor static func undoDuringRender() async throws {
        let gate = Gate(), model = try fixture(gate)
        model.isCropping = true
        model.cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        model.applyCrop()
        let saving = Task { try await model.commitEdits(idle: true) }
        try await until { gate.continuation != nil }
        let retained = gate.snapshots[0].baseURL
        model.undo()
        let undoneBase = model.baseImageURL
        // Trim the cropped redo entry while its pixels are still being rendered.
        model.engine.replaceDocument(shapes: [rect(x: 30)])
        try check(FileManager.default.fileExists(atPath: retained.path), "Trimmed history deleted in-flight pixels")
        gate.resume()
        _ = try await saving.value
        try check(model.baseImageURL == undoneBase && model.imageSize.width == 200, "Save overwrote crop undo")
        try check(model.hasUnsavedChanges, "A later edit was marked saved")
        model.releaseEditorResources()
        print("PASS undo across crop and retained pixels after redo-history trimming")
    }

    @MainActor static func imageDeletionDuringRender() async throws {
        let gate = Gate(), model = try fixture(gate)
        guard let asset = AnnoImageAsset(data: try png(width: 40, height: 30)) else {
            throw Failure(description: "Missing image asset fixture")
        }
        model.engine.insertImage(asset, assetID: "picture")
        let saving = Task { try await model.commitEdits(idle: true) }
        try await until { gate.continuation != nil }
        model.engine.deleteSelected()
        // Also prove the captured pixels/bytes survive asset cleanup.
        model.engine.imageAssets.removeAll()
        gate.resume()
        _ = try await saving.value
        let saved = try AnnotationDocument.load(from: ScreenshotHistoryStore.editDocumentURL(for: model.sourceURL!))
        try check(saved?.images["picture"] == asset.data, "Sidecar reread live assets after the render")
        try check(saved?.shapes.contains { $0.imageProps?.assetID == "picture" } == true, "Saved image shape disappeared")
        try check(model.hasUnsavedChanges, "Image deletion was marked saved")
        model.releaseEditorResources()
        print("PASS image deletion and asset cleanup during render")
    }

    @MainActor static func nativeFieldFocusAndComposition() async throws {
        let gate = Gate(), model = try fixture(gate)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 160, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextView(frame: CGRect(x: 0, y: 0, width: 140, height: 30))
        field.isFieldEditor = true
        window.contentView?.addSubview(field)
        try check(window.makeFirstResponder(field), "Could not focus the native field fixture")
        model.allowsIdleSave = { AnnotationEditorWindow.allowsIdleSave(in: window, keyWindow: nil) }
        try check(model.allowsIdleSave(), "Plain native field focus blocked idle saving")
        field.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(field.hasMarkedText() && !model.allowsIdleSave(), "Native IME composition did not block saving")
        model.scheduleIdleSave(after: .milliseconds(5))
        try await Task.sleep(for: .milliseconds(40))
        try check(gate.snapshots.isEmpty, "Save started during native IME composition")
        field.unmarkText()
        let text = field.string
        try check(model.allowsIdleSave(), "Native field focus still blocked after composition ended")
        model.scheduleIdleSave(after: .milliseconds(5))
        try await until { gate.continuation != nil }
        gate.resume()
        try await until { model.saveStatus == "Saved" }
        try check(window.firstResponder === field && field.string == text, "Idle save ended or disturbed native field editing")
        model.releaseEditorResources()
        print("PASS native field focus permits saving; real marked text blocks it; focus and text survive")
    }

    @MainActor static func idleGatesAndUndo() async throws {
        let gate = Gate(), model = try fixture(gate)
        let text = AnnoShape(x: 10, y: 10, kind: .text(TextProps(text: "draft")))
        model.engine.replaceDocument(shapes: [text])
        model.engine.startEditingText(text.id)
        _ = try await model.commitEdits(idle: true)
        try check(gate.snapshots.isEmpty && model.editingTextID == text.id, "Idle save ended text editing")
        model.engine.stopEditingText()
        model.allowsIdleSave = { false } // Native marked-text gate.
        model.scheduleIdleSave(after: .milliseconds(5))
        try await Task.sleep(for: .milliseconds(40))
        try check(gate.snapshots.isEmpty, "Idle save entered native IME composition")
        model.allowsIdleSave = { true }
        model.beginInteraction(at: CGPoint(x: 190, y: 90), imageFrame: CGRect(x: 0, y: 0, width: 200, height: 100), boundaryFrame: .zero)
        _ = try await model.commitEdits(idle: true)
        try check(gate.snapshots.isEmpty, "Idle save entered a pointer press")
        model.endInteraction(at: CGPoint(x: 190, y: 90), imageFrame: CGRect(x: 0, y: 0, width: 200, height: 100), boundaryFrame: .zero)
        let before = model.shapes
        model.setInspectorEditing(true)
        model.engine.replaceDocument(shapes: [rect(x: 50)])
        _ = try await model.commitEdits(idle: true)
        try check(gate.snapshots.isEmpty, "Idle save split an inspector drag")
        model.setInspectorEditing(false)
        model.scheduleIdleSave(after: .milliseconds(5))
        try await until { gate.continuation != nil }
        gate.resume()
        try await until { model.saveStatus == "Saved" }
        model.undo()
        try check(model.shapes == before, "Idle save changed the inspector undo group")
        model.releaseEditorResources()
        print("PASS text/composition, pointer and inspector gates; one undo step")
    }

    @MainActor static func coalescingAndExplicitSave() async throws {
        let gate = Gate(), model = try fixture(gate)
        let first = Task { try await model.commitEdits(idle: true) }
        try await until { gate.continuation != nil }
        for x in [20.0, 30, 40] { model.engine.replaceDocument(shapes: [rect(x: x)]) }
        model.scheduleIdleSave(after: .milliseconds(5))
        try await Task.sleep(for: .milliseconds(40))
        try check(gate.snapshots.count == 1, "Overlapping idle renders")
        gate.resume()
        _ = try await first.value
        try await until { model.saveStatus == "Saved" }
        try check(gate.snapshots.count == 2 && gate.maximumActive == 1, "Idle changes did not coalesce into one follow-up")
        try check(gate.snapshots.last?.document.shapes == model.shapes, "Follow-up didn't capture latest edits")
        model.releaseEditorResources()

        let explicitGate = Gate(), explicitModel = try fixture(explicitGate)
        let idle = Task { try await explicitModel.commitEdits(idle: true) }
        try await until { explicitGate.continuation != nil }
        explicitModel.engine.replaceDocument(shapes: [rect(x: 70)])
        let explicit = Task { try await explicitModel.commitEdits() }
        try await until { explicitModel.isBlockingCommit }
        try check(explicitGate.snapshots.count == 1, "Explicit save overlapped idle render")
        explicitGate.resume()
        _ = try await idle.value
        _ = try await explicit.value
        try check(explicitGate.snapshots.count == 2 && !explicitModel.hasUnsavedChanges, "Explicit save lost its queued request")
        explicitModel.releaseEditorResources()
        print("PASS coalescing and explicit save waiting for an idle render")
    }

    @MainActor static func undoToCleanDuringRender() async throws {
        let gate = Gate(), model = try fixture(gate)
        let original = try Data(contentsOf: model.sourceURL!)
        let saving = Task { try await model.commitEdits(idle: true) }
        try await until { gate.continuation != nil }
        model.undo()
        try check(!model.hasUnsavedChanges, "Undo didn't reach the old saved baseline")
        gate.resume()
        _ = try await saving.value
        try await until { model.saveStatus == "Saved" }
        try check(model.shapes.isEmpty, "An older save resurrected undone content")
        let display = try Data(contentsOf: model.sourceURL!)
        try check(display == original, "Undo to clean wasn't persisted after the older render")
        try check(!FileManager.default.fileExists(atPath: ScreenshotHistoryStore.editDocumentURL(for: model.sourceURL!).path), "Cleared document left a sidecar")
        model.releaseEditorResources()
        print("PASS undo to old clean baseline queues a follow-up after the older save")
    }

    @MainActor static func failedTransaction() async throws {
        let gate = Gate(), model = try fixture(gate)
        let source = model.sourceURL!, original = try Data(contentsOf: source)
        let saving = Task { try await model.commitEdits(idle: true) }
        try await until { gate.continuation != nil }
        let directory = source.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        gate.resume()
        let result = await saving.result
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard case .failure = result else { throw Failure(description: "Read-only transaction should fail") }
        let afterFailure = try Data(contentsOf: source)
        try check(afterFailure == original, "Failed save damaged original pixels")
        try check(model.hasUnsavedChanges && model.saveStatus == "Not Saved", "Failed transaction claimed Saved")
        try check(model.errorMessage != nil, "Commit didn't publish the save failure")
        _ = try await model.commitEdits()
        try check(!model.hasUnsavedChanges && model.saveStatus == "Saved", "Retry didn't recover")
        try check(model.errorMessage == nil, "Successful retry left a stale save error")
        model.releaseEditorResources()
        print("PASS failed transaction preserves pixels and dirty state, successful retry")
    }

    @MainActor static func closeAndQuitDuringRender(idle: Bool) async throws {
        let gate = Gate(), model = try fixture(gate)
        let saving = Task { try await model.commitEdits(idle: idle) }
        try await until { gate.continuation != nil }
        model.engine.replaceDocument(shapes: [rect(x: 80)])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 160, height: 120), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let guarder = EditorCloseGuard()
        var closeFinished = false, quitFinished: Bool?
        guarder.hasUnsavedChanges = { model.hasUnsavedChanges || model.isCommitting || model.isBlockingCommit }
        guarder.onDecision = { _, done in
            Task {
                do {
                    _ = try await model.commitEdits()
                    model.releaseEditorResources()
                    closeFinished = true
                    done(true)
                } catch { done(false) }
            }
        }
        guarder.attach(to: window)
        // A plain movie in Studio asks first; quitting leaves it to its own alert.
        try check(!EditorCloseGuard.reviewBeforeQuit { _ in }, "Quit saved an editor that asks first")
        guarder.savesWithoutAsking = { true }
        // The delegate path used by Cmd-W, without displaying or focusing a window.
        try check(!guarder.windowShouldClose(window), "Close didn't wait for the pending save")
        try await until { model.isBlockingCommit }
        try check(EditorCloseGuard.reviewBeforeQuit { quitFinished = $0 }, "Quit ignored a pending close")
        try check(!closeFinished && quitFinished == nil, "Close/quit finished before the pending write")
        gate.resume()
        _ = try await saving.value
        try await until { closeFinished && quitFinished != nil }
        try check(quitFinished == true && gate.snapshots.count == 2, "Close/quit did not save the latest state")
        try check(model.sourceURL == nil, "Close did not release the editor")
        print("PASS close during \(idle ? "idle" : "explicit") render, quit waiting for that close (window never shown)")
    }

    @MainActor static func benchmark() async throws {
        let data = try png(width: 5120, height: 2880)
        for run in 1...3 {
            let source = ScreenshotHistoryStore.historyDirectory.appendingPathComponent("benchmark-\(run).png")
            try data.write(to: source)
            var renderSeconds = 0.0
            let model = AnnotationEditorModel { snapshot in
                let start = Date()
                let result = try await snapshot.render()
                renderSeconds = Date().timeIntervalSince(start)
                return result
            }
            model.sourceURL = source
            model.baseImageURL = source
            model.imageSize = CGSize(width: 5120, height: 2880)
            model.backgroundSettings.style = .solid(AnnotationBackgroundColor("bench", title: "Fixture", red: 0.2, green: 0.3, blue: 0.6))
            model.backgroundSettings.progressiveBlur.isEnabled = true
            model.markSaved()
            model.engine.replaceDocument(shapes: [rect()])
            let start = Date()
            _ = try await model.commitEdits(idle: true)
            print("BENCH 5120x2880 background + progressive blur, run \(run): render=\(renderSeconds)s commit=\(Date().timeIntervalSince(start))s")
            model.releaseEditorResources()
        }
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        guard let root = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            throw Failure(description: "Run through check-editor-idle-save.py with an isolated home")
        }
        let isolated = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let actualHome = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let support = ScreendropStorage.applicationSupportDirectory.resolvingSymlinksInPath().path
        try check(actualHome == isolated && support.hasPrefix(isolated + "/"), "Foundation storage escaped isolated home")
        NSApplication.shared.setActivationPolicy(.prohibited)
        try sessionStoreRetention()
        try await sessionImageRestore()
        try await sessionPrunedRestoreAndPictures()
        try sessionTrash()
        try await studioSessionRestore()
        try await savesOnlyRefreshExistingPreviews()
        try await titleFieldFocusSelectionAndCommands()
        try await titleRenameIsOnlyMetadata()
        try recordingRenameIsOnlyMetadata()
        try studioStyleTransfer()
        try await nativeFieldFocusAndComposition()
        try await cropDuringRender()
        try await savedCropKeepsOriginal()
        try await revertToOriginalAndLastOpened()
        try await editStateIgnoresHover()
        try await undoDuringRender()
        try await imageDeletionDuringRender()
        try await idleGatesAndUndo()
        try await coalescingAndExplicitSave()
        try await undoToCleanDuringRender()
        try await failedTransaction()
        try await closeAndQuitDuringRender(idle: true)
        try await closeAndQuitDuringRender(idle: false)
        try await benchmark()
        try check(ScreenshotPreviewStack.shared.items.isEmpty, "Actual idle-save callers inserted preview cards")
        print("All idle-save model checks passed; no app window was shown")
    }
}
