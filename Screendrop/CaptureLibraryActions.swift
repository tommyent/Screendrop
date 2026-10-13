import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension CaptureLibraryModel {
    func perform(_ action: CaptureLibraryAction) {
        guard !isBusy else { return }
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        switch action {
        case .preview:
            guard selected.count == 1, let item = selected.first else { return }
            if QuickLookPreviewPresenter.isShown, let current = QuickLookPreviewPresenter.currentURL {
                let isSameCapture = current.standardizedFileURL == item.fileURL.standardizedFileURL
                    || (item.session != nil && current.deletingLastPathComponent().standardizedFileURL.path == item.ownedURL.standardizedFileURL.path)
                if isSameCapture { QuickLookPreviewPresenter.dismiss(); return }
            }
            run("Preparing preview…") {
                StudioProjectRegistry.shared.flushDrafts()
                let url = item.isVideo ? try await RecordingDeliverable.resolve(for: item.fileURL) : item.fileURL
                QuickLookPreviewPresenter.show(url: url)
            }
        case .edit:
            guard selected.count == 1, let item = selected.first else { return }
            QuickLookPreviewPresenter.dismiss()
            if item.isVideo { PreviewPanelPresenter.shared.onEditVideo?(item.session?.directoryURL ?? item.fileURL) }
            else { PreviewPanelPresenter.shared.onAnnotate?(item.fileURL) }
        case .rename:
            guard selected.count == 1, let item = selected.first else { return }
            beginRename(item, at: .card)
        case .copy:
            run("Copying \(selected.count == 1 ? "capture" : "captures")…") {
                StudioProjectRegistry.shared.flushDrafts()
                if selected.count == 1, let item = selected.first, !item.isVideo {
                    try await ScreenshotFileActions.copyImageToClipboard(from: item.fileURL)
                } else {
                    var urls: [URL] = []
                    for item in selected {
                        let url = item.isVideo ? try await RecordingDeliverable.resolve(for: item.fileURL) : item.fileURL
                        urls.append(url)
                    }
                    try VideoFileActions.copyFilesToClipboard(from: urls)
                }
            }
        case .export:
            export(selected)
        case .share:
            LibrarySharing.show(selected.map(\.fileURL))
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(selected.map(\.ownedURL))
        case .trash:
            pendingTrash = selected
        }
    }

    /// Adds a tag to every selected capture, or removes it from every one.
    /// A tag matching an existing one apart from case takes that spelling,
    /// so "Bug" and "bug" stay one tag. Recordings keep their tags in their
    /// own project, screenshots in the Library history.
    func setTag(_ tag: String, applied: Bool) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        let name = tags.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
        var historyIDs = Set<UUID>()
        for item in selectedItems {
            if let session = item.session {
                session.updateProjectMetadata { metadata in
                    var tags = (metadata.tags ?? []).filter { $0.caseInsensitiveCompare(name) != .orderedSame }
                    if applied { tags.append(name) }
                    metadata.tags = tags.isEmpty ? nil : tags
                }
            } else {
                historyIDs.formUnion(item.historyIDs)
            }
        }
        ScreenshotHistoryStore.shared.setTag(name, applied: applied, ids: historyIDs)
        refresh()
    }

    func beginRename(_ item: CaptureLibraryItem, at location: CaptureRenameSession.Location) {
        guard !isBusy else { return }
        if let edit = renameSession {
            guard edit.id != item.id else {
                // Moving between the card and the inspector keeps what was typed.
                renameSession?.location = location
                return
            }
            commitRename(edit.id, at: edit.location)
        }
        // Starts from the custom name; an unnamed capture starts empty, its date as the placeholder.
        renameSession = CaptureRenameSession(id: item.id, location: location, draft: savedNames[item.id] ?? item.customName ?? "")
    }

    /// Saves the draft for the capture the session was opened on, whatever
    /// that field is showing by now. Only the field that owns the session can
    /// end it, so a field going away can't end an edit that has moved to the
    /// other field or to another capture.
    func commitRename(_ id: String, at location: CaptureRenameSession.Location) {
        guard let edit = renameSession, edit.id == id, edit.location == location else { return }
        renameSession = nil
        let name = edit.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = items.first(where: { $0.id == id }),
              name != (savedNames[id] ?? item.customName ?? "") else { return }
        // An empty name clears the custom one, and the date shows again.
        if let session = item.session {
            RecordingProjectStore.shared.rename(session, to: name)
        } else if let historyID = item.historyIDs.first {
            ScreenshotHistoryStore.shared.rename(id: historyID, to: name)
        }
        savedNames[id] = name
        refresh()
    }

    func cancelRename(_ id: String, at location: CaptureRenameSession.Location) {
        guard renameSession?.id == id, renameSession?.location == location else { return }
        renameSession = nil
    }

    func movePendingItemsToTrash() {
        let targets = pendingTrash
        pendingTrash = []
        guard !targets.isEmpty else { return }
        run("Moving to Trash…") {
            QuickLookPreviewPresenter.dismiss()
            var removedIDs: Set<UUID> = []
            var removedEntries: Set<String> = []
            var failures: [String] = []
            for item in targets {
                guard !CaptureLibraryOpenEditors.isEditing(item.ownedURL) else {
                    failures.append("\(item.title): close its editor before moving it to Trash.")
                    continue
                }
                do {
                    try await Task.detached(priority: .userInitiated) { try CaptureLibraryFiles.trash(item) }.value
                    removedIDs.formUnion(item.historyIDs)
                    removedEntries.insert(item.id)
                    if let session = item.session {
                        ScreenshotPreviewStack.shared.dismissRecordingSession(session.directoryURL)
                    } else {
                        let cards = ScreenshotPreviewStack.shared.items.filter { $0.url.standardizedFileURL == item.fileURL.standardizedFileURL }
                        for card in cards { ScreenshotPreviewStack.shared.dismiss(id: card.id) }
                    }
                } catch { failures.append("\(item.title): \(error.localizedDescription)") }
            }
            await CaptureLibraryThumbnails.shared.remove(for: targets.filter { removedEntries.contains($0.id) }.map(\.ownedURL))
            ScreenshotHistoryStore.shared.removeTrashedItems(ids: removedIDs)
            self.selection.subtract(removedEntries)
            RecordingProjectStore.shared.reload()
            self.refresh()
            if !failures.isEmpty { self.errorMessage = failures.joined(separator: "\n\n") }
        }
    }

    /// A right-click between the cards, on any Library page: Sort By, as the
    /// toolbar's sort menu offered it, then Refresh.
    func backgroundMenuItems(refresh: @escaping () -> Void) -> [LibraryMenuItem] {
        CaptureLibrarySort.allCases.map { order in
            LibraryMenuItem(title: order.title, isChecked: sortOrder == order) { self.sortOrder = order }
        } + [LibraryMenuItem(title: "Refresh", startsGroup: true, perform: refresh)]
    }

    /// The captures' right-click menu: the shared actions, then the
    /// selected capture's cloud actions, which moved here from the
    /// inspector's bar, then Move to Trash.
    func menuItems(selected count: Int) -> [LibraryMenuItem] {
        var items = CaptureLibraryAction.menu(selected: count, perform: perform)
        if count == 1, let item = selectedItems.first, item.isVideo,
           let export = items.firstIndex(where: { $0.title == CaptureLibraryAction.export.rawValue }) {
            items.insert(LibraryMenuItem(title: "Export as GIF…", isEnabled: !isBusy) { self.exportGIF(item) }, at: export + 1)
        }
        let trash = items.removeLast()
        items += cloudMenuItems()
        items.append(trash)
        return items
    }

    private func cloudMenuItems() -> [LibraryMenuItem] {
        guard selectedItems.count == 1, let item = selectedItems.first else { return [] }
        if let link = item.cloudURL {
            return [
                LibraryMenuItem(title: "Copy Cloud Link", startsGroup: true) { self.copyLink(item) },
                LibraryMenuItem(title: "Open Shared Capture", isEnabled: URL(string: link) != nil) {
                    if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                },
                LibraryMenuItem(title: "Delete from Cloud…", isEnabled: !isBusy) { self.pendingCloudDelete = item },
            ]
        }
        guard CloudUploader.shared.isConfigured else { return [] }
        return [
            LibraryMenuItem(title: "Share to Cloud…", isEnabled: !isBusy, startsGroup: true) {
                self.pendingCloudUpload = item
            },
        ]
    }

    func copyLink(_ item: CaptureLibraryItem) {
        guard let link = item.cloudURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    func upload(_ item: CaptureLibraryItem, options: CloudUploadOptions) {
        guard !isBusy else { return }
        run("Uploading…") {
            StudioProjectRegistry.shared.flushDrafts()
            if let session = item.session, item.historyIDs.isEmpty {
                _ = await ScreenshotHistoryStore.shared.importRecordingSession(session)
            }
            let id = item.historyIDs.first ?? ScreenshotHistoryStore.shared.items.first {
                $0.recordingSessionPath == item.session?.directoryURL.standardizedFileURL.path
            }?.id ?? UUID()
            let result = try await CloudUploader.shared.upload(itemID: id, fileURL: item.fileURL,
                title: options.trimmedTitleOrNil, socialEnabled: options.socialEnabled,
                expiresAt: options.expiry.date(), allowAnonymousComments: options.allowAnonymousComments,
                password: options.password)
            ScreenshotHistoryStore.shared.setLibraryCloudURL(id: id, cloudURL: result.url)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.url, forType: .string)
            if item.isVideo { ScreenshotPreviewStack.shared.dismissVideo(for: item.ownedURL) }
            self.refresh()
        }
    }

    func deleteCloudCopy(_ item: CaptureLibraryItem) {
        guard let link = item.cloudURL, let uploadID = URL(string: link)?.lastPathComponent, !isBusy else { return }
        run("Deleting cloud copy…") {
            try await CloudUploader.shared.deleteFromCloud(uploadID: uploadID)
            for id in item.historyIDs { ScreenshotHistoryStore.shared.setLibraryCloudURL(id: id, cloudURL: nil) }
            CloudLibraryModel.shared.refreshUsage()
            self.refresh()
        }
    }

    private func export(_ items: [CaptureLibraryItem]) {
        let panel = NSOpenPanel()
        panel.title = "Export Captures"
        panel.message = "Choose a folder for \(items.count == 1 ? "this capture" : "these \(items.count) captures")."
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let directory = panel.url else { return }
            self.run("Exporting…") {
                StudioProjectRegistry.shared.flushDrafts()
                var exported: [URL] = []
                var failures: [String] = []
                for item in items {
                    do {
                        let source = item.isVideo ? try await RecordingDeliverable.resolve(for: item.fileURL) : item.fileURL
                        let destination = try await Task.detached(priority: .userInitiated) {
                            try CaptureLibraryFiles.export(source, name: item.name, to: directory)
                        }.value
                        exported.append(destination)
                        if item.isVideo { ScreenshotPreviewStack.shared.dismissVideo(for: item.ownedURL) }
                    } catch { failures.append("\(item.title): \(error.localizedDescription)") }
                }
                if !exported.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(exported) }
                if !failures.isEmpty { self.errorMessage = failures.joined(separator: "\n\n") }
                self.refresh()
            }
        }
    }

    /// A recording as a GIF, with the GIF settings last confirmed in the
    /// Studio's export options (sd-ahk).
    private func exportGIF(_ item: CaptureLibraryItem) {
        let panel = NSSavePanel()
        panel.title = "Export as GIF"
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = (item.name as NSString).deletingPathExtension + ".gif"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            self.run("Exporting GIF…") {
                StudioProjectRegistry.shared.flushDrafts()
                let movie = try await RecordingDeliverable.resolve(for: item.fileURL)
                let settings = RecordingExportPreferences.lastSettings
                // Written beside the destination, then renamed over it, so a failure leaves no half GIF.
                let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).gif")
                defer { try? FileManager.default.removeItem(at: staging) }
                try await RecordingGIFExport.write(movie: movie, to: staging, frameRate: settings.effectiveGIFFrameRate,
                                                   width: settings.effectiveGIFWidth)
                try ScreenshotFileActions.installExport(from: staging, at: destination)
                ScreenshotPreviewStack.shared.dismissVideo(for: item.ownedURL)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
    }

    private func run(_ title: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        operationTitle = title
        Task {
            defer { operationTitle = nil }
            do { try await operation() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

nonisolated enum CaptureLibraryFiles {
    static func export(_ source: URL, name: String, to directory: URL) throws -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let ext = source.pathExtension
        let stem = (safe as NSString).pathExtension.lowercased() == ext.lowercased()
            ? (safe as NSString).deletingPathExtension : safe
        let base = stem.isEmpty ? "Capture" : stem
        for suffix in 0..<10_000 {
            let name = suffix == 0 ? base : "\(base) \(suffix)"
            let destination = directory.appendingPathComponent(name).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }
        throw CocoaError(.fileWriteFileExists)
    }

    static func trash(_ item: CaptureLibraryItem) throws {
        var urls = [item.ownedURL]
        if item.session == nil && !item.isVideo {
            let url = item.fileURL
            let baseName = url.deletingPathExtension().lastPathComponent + ".base." + url.pathExtension
            urls += [url.appendingPathExtension("screendrop"), url.deletingLastPathComponent().appendingPathComponent(baseName)]
        }
        // Roll back earlier moves if any sidecar can't be moved. Keep the row
        // until every existing part of the capture is safely in Trash.
        var moved: [(URL, URL)] = []
        do {
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                var destination: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
                if let destination { moved.append((url, destination as URL)) }
            }
        } catch {
            for (original, trashed) in moved.reversed() { try? FileManager.default.moveItem(at: trashed, to: original) }
            throw error
        }
    }
}

/// A Library action must not move a package out from under an editor that can
/// autosave into it. Reference counts also cover multiple windows for one file.
@MainActor
enum CaptureLibraryOpenEditors {
    private static var urls: [URL: Int] = [:]
    static func add(_ url: URL) { urls[url.standardizedFileURL, default: 0] += 1 }
    static func remove(_ url: URL) {
        let key = url.standardizedFileURL
        let count = (urls[key] ?? 0) - 1
        if count <= 0 { urls.removeValue(forKey: key) } else { urls[key] = count }
    }
    static func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return urls.keys.contains { $0.path == path || $0.path.hasPrefix(path + "/") }
    }

    /// Whether an editor has this file open, or the package it lives in: a
    /// recording's card points at a file inside the package Studio opened.
    static func isEditing(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return contains(url) || urls.keys.contains { path.hasPrefix($0.path + "/") }
    }
}

struct CaptureLibraryEditorRegistration: ViewModifier {
    let url: URL?
    @State private var registered: URL?
    func body(content: Content) -> some View {
        content
            .onAppear { update(url) }
            .onChange(of: url) { _, new in update(new) }
            .onDisappear { update(nil) }
    }
    private func update(_ new: URL?) {
        guard registered != new else { return }
        if let registered { CaptureLibraryOpenEditors.remove(registered) }
        registered = new
        if let new { CaptureLibraryOpenEditors.add(new) }
    }
}

/// An in-place edit of one capture's name, on its card or in the inspector.
struct CaptureRenameSession: Equatable {
    enum Location { case card, inspector }
    let id: String
    var location: Location
    var draft: String
}

/// Edits a capture's name in place while the model's rename session is on
/// this field. Return or clicking away saves; Esc cancels.
struct CaptureNameField: View {
    let id: String
    let location: CaptureRenameSession.Location
    let font: Font
    /// Shown while the field is empty: the date the capture falls back to.
    let placeholder: String
    @FocusState private var isFocused: Bool

    private var model: CaptureLibraryModel { .shared }

    var body: some View {
        TextField("Name", text: Binding(
            get: { ownsSession ? model.renameSession?.draft ?? "" : "" },
            set: { if ownsSession { model.renameSession?.draft = $0 } }
        ), prompt: Text(placeholder))
        .textFieldStyle(.plain)
        .font(font)
        .focused($isFocused)
        .onSubmit { model.commitRename(id, at: location) }
        .onExitCommand { model.cancelRename(id, at: location) }
        .onChange(of: isFocused) { _, focused in
            if !focused { model.commitRename(id, at: location) }
        }
        .onAppear {
            // Only while this field still owns the session: Esc or a reused
            // card can end it before focus arrives.
            DispatchQueue.main.async {
                if ownsSession { isFocused = true }
            }
        }
    }

    private var ownsSession: Bool {
        model.renameSession?.id == id && model.renameSession?.location == location
    }
}

/// The system Share sheet for Library items, opened from a right-click
/// menu, so it appears beside the pointer.
enum LibrarySharing {
    static func show(_ items: [URL]) {
        guard !items.isEmpty, let window = NSApp.keyWindow, let view = window.contentView else { return }
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        NSSharingServicePicker(items: items)
            .show(relativeTo: NSRect(origin: point, size: .zero), of: view, preferredEdge: .minY)
    }
}
