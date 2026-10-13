import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

// Built against the actual app sources by check-editor-idle-save.py.
@main
struct IdleSaveChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
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
        let guarder = EditorCloseGuard(savesWithoutAsking: true)
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
        try await savesOnlyRefreshExistingPreviews()
        try await titleFieldFocusSelectionAndCommands()
        try await titleRenameIsOnlyMetadata()
        try await nativeFieldFocusAndComposition()
        try await cropDuringRender()
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
