//
//  RecordingProjectStore.swift
//  Screendrop
//
//  The recent-recordings menu's model. Recording packages on disk are the source
//  of truth - not history.json - so a project whose History row was deleted
//  is still reachable, and a package deleted in Finder disappears here.
//

import AppKit
import AVFoundation
import Observation

nonisolated struct RecordingProjectSummary: Identifiable, Equatable, Sendable {
    let session: RecordingSession
    var displayName: String
    var createdAt: Date
    var duration: TimeInterval
    var pixelSize: CGSize
    /// Committed with an explicit save at least once.
    var isSaved: Bool
    /// Autosaved edits sitting on top of the saved state.
    var hasUnsavedDraft: Bool
    var sizeOnDisk: Int64
    var lastOpenedAt: Date?

    var id: URL { session.directoryURL }

    /// Orders both the Recordings menu and the browser's default sort:
    /// what you touched last, falling back to when it was recorded.
    var lastActivityAt: Date { lastOpenedAt ?? createdAt }
}

@MainActor
@Observable
final class RecordingProjectStore {
    static let shared = RecordingProjectStore()

    private(set) var projects: [RecordingProjectSummary] = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    /// Deliberately empty until something asks. Summarizing every package
    /// walks the Recordings folder, which is not worth doing at launch when
    /// most sessions never open the Recordings menu.
    private init() {}

    /// The Recordings menu shows only a handful; the rest live in Library.
    var recentProjects: [RecordingProjectSummary] {
        Array(projects.prefix(8))
    }

    func reload() {
        reloadTask?.cancel()
        reloadTask = Task {
            let scan = Task.detached(priority: .utility) {
                RecordingSessionStore.allSessions()
                    .compactMap { Task.isCancelled ? nil : Self.summarize($0) }
                    .sorted { $0.lastActivityAt > $1.lastActivityAt }
            }
            let result = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard !Task.isCancelled else { return }
            projects = result
        }
    }

    /// Drop references only after the entire package has safely reached the Trash.
    func delete(_ session: RecordingSession) throws {
        try RecordingSessionStore.deleteSession(session)
        ScreenshotPreviewStack.shared.dismissRecordingSession(session.directoryURL)
        ScreenshotHistoryStore.shared.deleteRecordingSession(session)
        reload()
    }

    // MARK: - Summaries

    nonisolated private static func summarize(_ session: RecordingSession) -> RecordingProjectSummary {
        let manifest = session.loadCaptureManifest()
        let metadata = session.loadProjectMetadata()
        let folderCreatedAt = try? session.directoryURL
            .resourceValues(forKeys: [.creationDateKey])
            .creationDate
        let createdAt = manifest?.createdAt ?? folderCreatedAt ?? Date.distantPast

        return RecordingProjectSummary(
            session: session,
            displayName: session.displayName,
            createdAt: createdAt,
            duration: manifest?.duration ?? 0,
            pixelSize: CGSize(
                width: manifest?.pixelWidth ?? 0,
                height: manifest?.pixelHeight ?? 0
            ),
            isSaved: session.hasSavedProject,
            hasUnsavedDraft: session.hasUnsavedDraft,
            sizeOnDisk: sizeOnDisk(of: session.directoryURL),
            lastOpenedAt: metadata?.lastOpenedAt
        )
    }

    nonisolated private static func sizeOnDisk(of directoryURL: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: keys
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { return total }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }
}

/// Opening a project has to reach the `VIDEO_EDITOR` scene from AppKit-hosted
/// surfaces such as the menu bar extra, which have no scene
/// environment of their own. `ScreendropApp` installs the opener, mirroring
/// what `PreviewPanelPresenter.onEditVideo` already does.
@MainActor
final class RecordingProjectOpener {
    static let shared = RecordingProjectOpener()

    var openHandler: ((URL) -> Void)?

    private init() {}

    func open(_ session: RecordingSession) {
        RecordingProjectStore.shared.reload()
        openHandler?(session.directoryURL)
    }
}

/// Knows which Studio windows are currently holding uncommitted edits, so
/// quitting can say so.
@MainActor
final class StudioProjectRegistry {
    static let shared = StudioProjectRegistry()

    private var models: [ObjectIdentifier: WeakModel] = [:]

    private struct WeakModel {
        weak var model: RecordingStudioModel?
    }

    private init() {}

    func register(_ model: RecordingStudioModel) {
        models[ObjectIdentifier(model)] = WeakModel(model: model)
    }

    func unregister(_ model: RecordingStudioModel) {
        models.removeValue(forKey: ObjectIdentifier(model))
    }

    func hasLoadedEditor(for url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return models.values.contains {
            guard let model = $0.model, model.isLoaded else { return false }
            return model.sessionURL.standardizedFileURL.path == path
        }
    }

    /// Edits to a bare movie have no draft, so a quit loses them.
    var hasUnsavedMovieEdits: Bool {
        models.values.compactMap(\.model).contains { !$0.isProject && $0.hasUnsavedChanges }
    }

    var unsavedProjectCount: Int {
        // Bare movies have no draft to restore, so they aren't counted here.
        models.values.compactMap(\.model).filter { $0.isProject && $0.hasUnsavedChanges }.count
    }

    var hasRunningWork: Bool {
        models.values.contains { $0.model?.hasRunningWork == true }
    }

    /// Called before the app goes away. The autosave is debounced, so without
    /// this a quit can drop the last fraction of a second of edits.
    func flushDrafts() {
        for model in models.values.compactMap(\.model) {
            model.flushDraft()
        }
    }
}
