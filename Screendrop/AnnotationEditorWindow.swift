//
//  AnnotationEditorWindow.swift
//  Screendrop
//
//  Created by Codex on 27/04/26.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AnnotationEditorWindow: View {
    @Binding var url: URL?

    @State private var model = AnnotationEditorModel()
    @State private var probe = PixelProbe()
    @State private var wallpaperStore = AnnotationWallpaperStore.shared
    @State private var backgroundPresetStore = AnnotationBackgroundPresetStore.shared
    @State private var isInspectorPresented = true
    @State private var isFinishing = false
    @State private var isSaving = false
    @State private var isUploading = false
    /// No close-button dot: Apple's HIG says that with autosave on, a dot
    /// implies people must act to keep their work. The subtitle says it instead.
    @State private var closeGuard = EditorCloseGuard()
    @State private var didCopyLink = false
    /// Found once per load: matching by URL probes each recording on disk,
    /// and the title is read on every edit.
    @State private var historyID: UUID?
    @FocusState private var focusedField: AnnotationEditorFocusedField?
    @Environment(\.dismiss) private var dismissWindow

    private var isBusy: Bool { isSaving || isFinishing || isUploading || model.isBlockingCommit }

    var body: some View {
        mainContent
            .disabled(model.isBlockingCommit)
            .allowsHitTesting(!model.isBlockingCommit)
            .modifier(CaptureLibraryEditorRegistration(url: url))
            .navigationTitle(windowTitle)
            .navigationSubtitle(model.saveStatus)
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    AnnotationEditorTitle(title: windowTitle, status: model.saveStatus, item: historyItem)
                        .id(historyID)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.isCropping {
                        cropActions
                    } else {
                        editingActions.disabled(isBusy)
                    }
                }
                // Bare icons, as in the Library and the Studio: no glass capsule.
                .sharedBackgroundVisibility(.hidden)
            }
            .task(id: url) {
                historyID = url.flatMap { ScreenshotHistoryStore.shared.item(for: $0)?.id }
                clearInspectorFocus()
                model.load(url: url, dismiss: dismissWindow)
            }
            .onAppear {
                Task { await wallpaperStore.reload() }
                AnnotationEditorActivationPolicy.enter(hidePreview: true)
            }
            .onDisappear {
                closeGuard.detach()
                probe.release()
                model.releaseEditorResources()
                AnnotationEditorActivationPolicy.leave(restorePreview: true)
            }
            .onWindowChange { window in
                guard let window else {
                    closeGuard.detach()
                    return
                }
                model.allowsIdleSave = { [weak window] in
                    guard let window else { return false }
                    return Self.allowsIdleSave(in: window, keyWindow: NSApp.keyWindow)
                }
                configureCloseGuard()
                closeGuard.attach(to: window)
            }
            // Saves at a pause, so History and the Library keep up without a
            // Save button. Not on resign key: the editor's own popovers take
            // key (the Unsplash search, a style's name) but never main.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignMainNotification)) { note in
                if let window = note.object as? NSWindow, window.delegate === closeGuard { saveAtPause(in: window) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                if let window = NSApp.windows.first(where: { $0.delegate === closeGuard }) { saveAtPause(in: window) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                if let window = note.object as? NSWindow, window.delegate === closeGuard {
                    model.scheduleIdleSave()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidEndEditingNotification)) { note in
                if let control = note.object as? NSView, control.window?.delegate === closeGuard {
                    model.scheduleIdleSave()
                }
            }
            .onChange(of: focusedField) { _, _ in model.scheduleIdleSave() }
            .onDeleteCommand {
                if !model.isBlockingCommit { model.deleteSelectedAnnotation() }
            }
            .onChange(of: model.isCropping) { _, isCropping in
                if isCropping {
                    probe.isPicking = false
                    probe.isMeasuringTool = false
                }
            }
            .onChange(of: model.revision) { _, _ in
                if didCopyLink { withAnimation(.snappy(duration: 0.2)) { didCopyLink = false } }
            }
            .onChange(of: model.backgroundSettings) { _, _ in
                if didCopyLink { withAnimation(.snappy(duration: 0.2)) { didCopyLink = false } }
            }
            .focusedSceneValue(\.annotationEditor, model)
            .onChange(of: model.saveAsRequest) { _, _ in saveAs() }
            .onChange(of: model.saveRequest) { _, _ in saveEdits() }
            // The pixels under the pointer come from the base image, so they
            // are read again whenever a crop or its undo replaces it.
            .task(id: model.previewCGImage.map(ObjectIdentifier.init)) {
                await probe.load(model.baseImageURL, preview: model.previewCGImage)
            }
            .background(AnnotationKeyCommandHandler(
                isEnabled: { !model.isBlockingCommit },
                onDelete: model.deleteSelectedAnnotation,
                onSave: saveEdits,
                onCopy: copyAndFinishEditing,
                onUndo: model.undo,
                onRedo: model.redo,
                onSelectAll: model.selectAllAnnotations,
                onSelectTool: { tool in
                    probe.isPicking = false
                    probe.isMeasuringTool = false
                    model.selectTool(tool)
                },
                onZoomIn: model.zoomIn,
                onZoomOut: model.zoomOut,
                onFitCanvas: model.fitCanvas,
                onActualSize: { model.setZoomPercent(100) },
                onToggleCrop: { withAnimation(.snappy(duration: 0.2)) { model.toggleCropping() } },
                onApplyCrop: { withAnimation(.snappy(duration: 0.2)) { model.applyCrop() } },
                onCancelCrop: { withAnimation(.snappy(duration: 0.2)) { model.cancelCrop() } },
                isCropping: { model.isCropping },
                onCopyColor: probe.copyHovered,
                onPaste: {
                    guard model.pasteImage() else { return false }
                    probe.isPicking = false
                    probe.isMeasuringTool = false
                    return true
                },
                onMeasure: probe.measure,
                // Points of the image, as the ruler measures them.
                onNudge: { step in
                    model.nudgeSelection(dx: step.dx * probe.pixelsPerPoint, dy: step.dy * probe.pixelsPerPoint)
                },
                onEscape: {
                    if EditorPopovers.closeNewest() { return }
                    if probe.isPicking || probe.isMeasuringTool {
                        probe.isPicking = false
                        probe.isMeasuringTool = false
                    } else {
                        model.escapeSelectionOrDisarm()
                    }
                }
            ))
            .inspector(isPresented: $isInspectorPresented) {
                AnnotationEditorInspector(
                    model: model,
                    wallpaperStore: wallpaperStore,
                    backgroundPresetStore: backgroundPresetStore,
                    focusedField: $focusedField,
                    onEditorAction: clearInspectorFocus,
                    onPickWallpaper: pickCustomWallpaper
                )
                .disabled(model.isCropping || model.isBlockingCommit)
            }
            .environment(probe)
    }

    // MARK: Toolbar actions

    /// The standard trailing actions shown when not cropping.
    @ViewBuilder
    private var editingActions: some View {
        if CloudUploader.shared.isConfigured {
            CloudUploadButton(
                suggestedTitle: model.sourceURL?.deletingPathExtension().lastPathComponent ?? "",
                onUpload: uploadAnnotation
            ) {
                if isUploading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Uploading...")
                    }
                    .padding(.horizontal, 6)
                } else if didCopyLink {
                    Label("Link copied", systemImage: "checkmark.icloud")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6)
                } else {
                    Label("Upload", systemImage: "icloud.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6)
                }
            }
            .tint(.accentColor)
            .help("Upload to the cloud and copy the link")
            .disabled(isUploading)
        }

        Button {
            clearInspectorFocus()
            isInspectorPresented.toggle()
        } label: {
            Label(isInspectorPresented ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
                .labelStyle(.iconOnly)
        }
        .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
    }

    /// The crop controls that replace the trailing actions while cropping.
    @ViewBuilder
    private var cropActions: some View {
        Menu {
            Picker("Aspect Ratio", selection: aspectBinding) {
                ForEach(CropAspectRatio.allCases) { aspect in
                    Text(aspect.title).tag(aspect)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(model.cropAspect.title, systemImage: "aspectratio")
                .labelStyle(.titleAndIcon)
        }
        .help("Aspect ratio")

        Button {
            clearInspectorFocus()
            withAnimation(.snappy(duration: 0.18)) { model.resetCrop() }
        } label: {
            Text("Reset").padding(.horizontal, 6)
        }
        .help("Reset the selection to the whole image")

        Button(action: exitCrop) {
            Text("Cancel").padding(.horizontal, 6)
        }
        .keyboardShortcut(.cancelAction)

        Button(action: applyCropAction) {
            Text("Crop").padding(.horizontal, 8)
        }
        .keyboardShortcut(.defaultAction)
    }

    private var aspectBinding: Binding<CropAspectRatio> {
        Binding(
            get: { model.cropAspect },
            set: { newValue in
                clearInspectorFocus()
                withAnimation(.snappy(duration: 0.18)) { model.setCropAspect(newValue) }
            }
        )
    }

    private func enterCrop() {
        clearInspectorFocus()
        withAnimation(.snappy(duration: 0.22)) { model.beginCropping() }
    }

    private func exitCrop() {
        clearInspectorFocus()
        withAnimation(.snappy(duration: 0.22)) { model.cancelCrop() }
    }

    private func applyCropAction() {
        clearInspectorFocus()
        withAnimation(.snappy(duration: 0.22)) { model.applyCrop() }
    }

    private var mainContent: some View {
        ZStack {
            AnnotationEditorWorkspaceBackground()

            if let previewImage = model.previewImage, model.imageSize != .zero {
                AnnotationCanvas(
                    model: model,
                    image: previewImage,
                    onEditorInteraction: clearInspectorFocus
                )
            } else if let errorMessage = model.errorMessage {
                // A load failure (missing/unreadable source file, e.g. a stale
                // URL replayed by macOS window restoration) should never sit
                // behind an unexplained spinner with no way out.
                AnnotationLoadFailureView(message: errorMessage, onClose: closeAfterLoadFailure)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .frame(minWidth: 760, minHeight: 580)
        .clipped()
        .overlay(alignment: .top) {
            if model.previewImage != nil, model.imageSize != .zero {
                AnnotationToolDock(
                    model: model,
                    probe: probe,
                    isDisabled: model.isCropping || isBusy,
                    onSelectTool: { tool in
                        clearInspectorFocus()
                        probe.isPicking = false
                        probe.isMeasuringTool = false
                        model.selectTool(tool)
                    },
                    onCrop: enterCrop
                )
                .padding(.top, AnnotationToolDock.topPadding)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if model.previewImage != nil, model.imageSize != .zero {
                HStack(spacing: 8) {
                    AnnotationZoomControl(model: model)

                    if model.isPreviewDownscaled {
                        LowResolutionPreviewNotice()
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.isCropping, model.imageSize != .zero {
                CropResolutionBadge(size: model.cropPixelSize)
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)))
            }
        }
        .overlay(alignment: .bottomLeading) {
            // Only inline saves/uploads (which fail with an image already on
            // screen) land here; a load failure shows the full-canvas state
            // above instead of stacking a second copy of the same message.
            if let errorMessage = model.errorMessage, model.previewImage != nil {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
        }
    }

    /// The capture's Library title, following a rename made there: its name,
    /// else when it was taken. A file outside History shows its file name.
    private var windowTitle: String {
        guard let url else { return "" }
        guard let item = historyItem else {
            return url.deletingPathExtension().lastPathComponent
        }
        return item.displayName ?? CaptureLibraryItem.dateTitle(item.createdAt)
    }

    private var historyItem: ScreenshotHistoryItem? {
        ScreenshotHistoryStore.shared.items.first(where: { $0.id == historyID })
    }

    private func closeAfterLoadFailure() {
        model.releaseEditorResources()
        dismissWindow()
    }

    private func saveAs() {
        clearInspectorFocus()
        guard !isBusy, let sourceURL = model.sourceURL else { return }
        do { try model.validateEditDocument() } catch {
            model.errorMessage = error.localizedDescription
            return
        }
        let baseURL = model.baseImageURL ?? sourceURL

        let panel = NSSavePanel()
        panel.allowedContentTypes = [ScreenshotFileActions.exportContentType]
        panel.nameFieldStringValue = ScreenshotFileActions.exportFileName(for: sourceURL)
        panel.canCreateDirectories = true
        panel.title = "Save Annotated Screenshot"

        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }

            Task {
                do {
                    try await AnnotationRenderer.renderInBackground(
                        sourceURL: baseURL,
                        shapes: model.shapes,
                        bindings: model.bindings,
                        images: model.engine.images,
                        backgroundSettings: model.backgroundSettings,
                        destinationURL: destinationURL,
                        contentType: ScreenshotFileActions.exportContentType
                    )
                } catch {
                    model.errorMessage = "Failed to save annotation: \(error.localizedDescription)"
                }
            }
        }
    }

    private func pickCustomWallpaper() {
        clearInspectorFocus()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose Background Wallpaper"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let wallpaper = AnnotationCustomWallpaper(url: url)
            wallpaperStore.addRecentWallpaper(url)
            model.backgroundSettings.customWallpaper = wallpaper
            model.backgroundSettings.style = .customWallpaper(wallpaper)
        }
    }

    private func uploadAnnotation(options: CloudUploadOptions) {
        clearInspectorFocus()
        guard model.sourceURL != nil, !isBusy else { return }

        isUploading = true
        Task {
            defer { isUploading = false }
            do {
                // Persist the current annotations first so the uploaded file
                // matches what's saved in history, then upload that file. The
                // editor stays open.
                guard let sourceURL = model.sourceURL else { return }
                let resultURL = try await model.commitEdits() ?? sourceURL

                _ = await ScreenshotPreviewStack.shared.applyAnnotation(
                    originalURL: sourceURL,
                    historyURL: resultURL
                )

                let result = try await CloudUploader.shared.upload(
                    itemID: UUID(),
                    fileURL: resultURL,
                    title: options.trimmedTitleOrNil,
                    socialEnabled: options.socialEnabled,
                    expiresAt: options.expiry.date(),
                    allowAnonymousComments: options.allowAnonymousComments,
                    password: options.password
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.url, forType: .string)
                ScreenshotHistoryStore.shared.setCloudURL(for: resultURL, cloudURL: result.url)
                withAnimation(.snappy(duration: 0.2)) { didCopyLink = true }
            } catch {
                model.errorMessage = "Upload failed: \(error.localizedDescription)"
            }
        }
    }

    /// ⌘S and File › Save: saves now rather than at the next pause.
    private func saveEdits() {
        clearInspectorFocus()
        save()
    }

    /// Leaves focus alone; composition, unfinished interactions and sheets
    /// defer the background snapshot. Closing still saves.
    private func saveAtPause(in window: NSWindow) {
        guard model.canSaveInBackground, window.attachedSheet == nil else { return }
        save(idle: true)
    }

    /// Focus can return to a field editor even when nobody is typing.
    static func allowsIdleSave(in window: NSWindow, keyWindow: NSWindow?) -> Bool {
        let isComposing = (window.firstResponder as? NSTextView)?.hasMarkedText() == true
        let popoverIsComposing = keyWindow?.parent == window
            && (keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
        return !isComposing && !popoverIsComposing && window.attachedSheet == nil
    }

    private func save(idle: Bool = false) {
        // Committing re-renders the composite, so a save with nothing
        // changed should cost nothing.
        guard model.sourceURL != nil, model.hasUnsavedChanges || model.isCommitting, !isBusy else { return }

        if !idle { isSaving = true }
        Task {
            defer { if !idle { isSaving = false } }
            do {
                guard let sourceURL = model.sourceURL,
                      let resultURL = try await model.commitEdits(idle: idle) else { return }
                _ = await ScreenshotPreviewStack.shared.applyAnnotation(
                    originalURL: sourceURL,
                    historyURL: resultURL,
                    updatesClipboard: !idle
                )
            } catch {
                model.errorMessage = "Failed to save annotation: \(error.localizedDescription)"
            }
        }
    }

    /// Cmd-C: saves and closes, then puts the finished image - annotations
    /// included - on the clipboard whatever the auto-copy setting, for a
    /// capture, mark up, paste loop that never touches the mouse.
    private func copyAndFinishEditing() {
        clearInspectorFocus()
        guard let sourceURL = model.sourceURL else {
            model.releaseEditorResources()
            dismissWindow()
            return
        }

        guard !isBusy else { return }

        isFinishing = true
        Task {
            do {
                let resultURL = try await model.commitEdits()
                if let resultURL {
                    _ = await ScreenshotPreviewStack.shared.applyAnnotation(
                        originalURL: sourceURL,
                        historyURL: resultURL
                    )
                }
                // No result means nothing was drawn: the original is the image.
                try await ScreenshotFileActions.copyImageToClipboard(from: resultURL ?? sourceURL)
                guard !model.hasUnsavedChanges else {
                    isFinishing = false
                    return
                }
                model.releaseEditorResources()
                dismissWindow()
            } catch {
                isFinishing = false
                model.errorMessage = "Failed to finish annotation: \(error.localizedDescription)"
            }
        }
    }

    private func configureCloseGuard() {
        closeGuard.savesWithoutAsking = { true }
        closeGuard.hasUnsavedChanges = { [weak model] in
            guard let model else { return false }
            return model.hasUnsavedChanges || model.isCommitting || model.isBlockingCommit
        }
        closeGuard.projectName = { [weak model] in model?.sourceURL?.lastPathComponent ?? "this screenshot" }
        // Capture only the model, not this view and its @State close guard.
        closeGuard.onDecision = { [weak model] decision, done in
            guard let model else { return done(true) }
            switch decision {
            case .save:
                Task {
                    do {
                        if let sourceURL = model.sourceURL,
                           let resultURL = try await model.commitEdits() {
                            _ = await ScreenshotPreviewStack.shared.applyAnnotation(
                                originalURL: sourceURL,
                                historyURL: resultURL
                            )
                        }
                        guard !model.hasUnsavedChanges else { return done(false) }
                        model.releaseEditorResources()
                        done(true)
                    } catch {
                        model.errorMessage = "Failed to save annotation: \(error.localizedDescription)"
                        done(false)
                    }
                }
            case .discard:
                model.releaseEditorResources()
                done(true)
            case .cancel:
                done(false)
            }
        }
    }

    private func clearInspectorFocus() {
        focusedField = nil
    }
}

private struct AnnotationLoadFailureView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
    }
}

extension FocusedValues {
    /// The key editor window's model, for menu commands.
    @Entry var annotationEditor: AnnotationEditorModel?
}

/// File › Save for the key editor window, disabled when clean. The editor's
/// key monitor takes ⌘S before the menu sees it, so one press saves once;
/// a second call would find the first save running anyway. Only there while
/// an editor is focused: a disabled item still consumes its ⌘S, which would
/// take the keystroke from Studio's own Save.
struct AnnotationEditorSaveCommand: View {
    @FocusedValue(\.annotationEditor) private var editor

    var body: some View {
        if let editor {
            Button("Save") { editor.requestSave() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!editor.hasUnsavedChanges)
        }
    }
}

/// File › Save As… for the key editor window. Only there while an editor
/// is focused, like Save: Studio has no Save As, and a disabled one sat
/// above Studio's Save.
struct AnnotationEditorSaveAsCommand: View {
    @FocusedValue(\.annotationEditor) private var editor

    var body: some View {
        if let editor {
            Button("Save As…") { editor.requestSaveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

/// File › Revert To for the key editor window, as document apps have it.
/// Each is one step Undo takes back; the next save writes it.
struct AnnotationEditorRevertCommand: View {
    @FocusedValue(\.annotationEditor) private var editor

    var body: some View {
        if let editor {
            Menu("Revert To") {
                Button("Original") { editor.revertToOriginal() }
                    .disabled(!editor.canRevertToOriginal)
                Button("Last Opened") { editor.revertToLastOpened() }
                    .disabled(!editor.canRevertToLastOpened)
            }
        }
    }
}
