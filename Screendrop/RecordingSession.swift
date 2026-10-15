//
//  RecordingSession.swift
//  Screendrop
//
//  A recording is a folder ("session") rather than a bare .mov so the studio
//  editor can keep the screen video, the separately captured camera video,
//  and the timestamped pointer-capture sidecar together. Sessions live in
//  Application Support (not the temp dir) so a crash mid-recording never
//  hands the footage to the OS temp purger.
//

import CoreGraphics
import Foundation

nonisolated struct RecordingSession: Sendable, Equatable {
    static let directoryExtension = "screendroprec"
    static let screenFileName = "screen.mov"
    static let cameraFileName = "camera.mov"
    static let pointerCaptureFileName = "input.json"
    static let captureManifestFileName = "capture.json"
    static let editDocumentFileName = "edit.json"
    /// The working copy the editor writes while you type. `edit.json` is
    /// only rewritten by a save (at a pause, on leaving or closing the
    /// window, on quit or ⌘S), so a crash between saves costs nothing.
    static let draftDocumentFileName = "edit.draft.json"
    static let projectMetadataFileName = "project.json"
    /// The document that produced the current flattened deliverable, so a
    /// cached render can be proven fresh instead of assumed fresh.
    static let renderStampFileName = "render.json"
    /// Base name for an imported soundtrack. The picked file is copied in
    /// beside the footage (keeping its own extension) so the project keeps
    /// playing after the original is moved or deleted.
    static let replacementAudioBaseName = "audio-replacement"

    let directoryURL: URL

    var sessionSnapshotsURL: URL { directoryURL.appendingPathComponent("sessions", isDirectory: true) }

    var screenURL: URL { directoryURL.appendingPathComponent(Self.screenFileName) }
    var cameraURL: URL { directoryURL.appendingPathComponent(Self.cameraFileName) }
    /// The default flattened deliverable. The source screen/camera movies stay
    /// untouched so Studio can always re-render the project non-destructively.
    var finalURL: URL {
        finalURL(for: .default)
    }

    func finalURL(for container: VideoExportContainer) -> URL {
        let fileName = directoryURL
            .deletingPathExtension()
            .lastPathComponent
            .appending(".\(container.fileExtension)")
        return directoryURL.appendingPathComponent(fileName)
    }
    var pointerCaptureURL: URL { directoryURL.appendingPathComponent(Self.pointerCaptureFileName) }
    var captureManifestURL: URL { directoryURL.appendingPathComponent(Self.captureManifestFileName) }
    var editDocumentURL: URL { directoryURL.appendingPathComponent(Self.editDocumentFileName) }
    var draftDocumentURL: URL { directoryURL.appendingPathComponent(Self.draftDocumentFileName) }
    var projectMetadataURL: URL { directoryURL.appendingPathComponent(Self.projectMetadataFileName) }
    var renderStampURL: URL { directoryURL.appendingPathComponent(Self.renderStampFileName) }

    /// True once the project has been committed to `edit.json`. Every
    /// package written by older builds has an `edit.json` from the previous
    /// silent autosave, so those open as already-saved - no migration.
    var hasSavedProject: Bool {
        FileManager.default.fileExists(atPath: editDocumentURL.path)
    }

    /// The name shown wherever the project is listed.
    var displayName: String {
        customName ?? directoryURL.deletingPathExtension().lastPathComponent
    }

    /// The name given in the Library or Studio's title bar, if any.
    var customName: String? {
        let stored = loadProjectMetadata()?.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    var hasCamera: Bool {
        FileManager.default.fileExists(atPath: cameraURL.path)
    }

    /// The flattened cache on disk, whichever container it was rendered into.
    /// Nil when the project has never been rendered. Probing every container
    /// keeps an existing render valid after the export format is changed -
    /// switching the picker converts on save rather than forcing a re-render.
    var existingFinalURL: URL? {
        for container in VideoExportContainer.allCases {
            let candidate = finalURL(for: container)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Uses an existing flattened cache when one is available; otherwise
    /// history previews the screen master so the project can appear without
    /// turning Stop into an implicit export.
    var deliverableURL: URL {
        existingFinalURL ?? screenURL
    }

    /// Drops every cached deliverable, whichever container it was rendered
    /// into. Targeting a single container would leave a render in the other
    /// one behind, and `existingFinalURL` would then hand out stale footage.
    func removeFinalVideos() {
        for container in VideoExportContainer.allCases {
            try? FileManager.default.removeItem(at: finalURL(for: container))
        }
        try? FileManager.default.removeItem(at: renderStampURL)
    }

    /// Adopts a freshly rendered file as this session's deliverable, taking the
    /// container from the render itself. Deliverables in other containers are
    /// cleared so a stale render can never win the `existingFinalURL` lookup.
    @discardableResult
    func installFinalVideo(
        movingFrom temporaryURL: URL,
        renderedFrom document: RecordingEditDocument? = nil
    ) throws -> URL {
        let container = VideoExportContainer(fileExtension: temporaryURL.pathExtension) ?? .default
        let destinationURL = finalURL(for: container)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }

        for stale in VideoExportContainer.allCases where stale != container {
            try? FileManager.default.removeItem(at: finalURL(for: stale))
        }
        writeRenderStamp(document)
        return destinationURL
    }

    /// True when two documents would render identical media and differ only in
    /// the container they get wrapped in, or the GIF made from them.
    static func differsOnlyByExportContainer(
        _ document: RecordingEditDocument,
        _ other: RecordingEditDocument?
    ) -> Bool {
        guard let other else { return false }
        var normalized = document
        normalized.exportSettings?.container = other.exportSettings?.container
        normalized.exportSettings?.exportsGIF = other.exportSettings?.exportsGIF
        normalized.exportSettings?.gifFrameRate = other.exportSettings?.gifFrameRate
        normalized.exportSettings?.gifWidth = other.exportSettings?.gifWidth
        return normalized == other
    }

    static func isSessionDirectory(_ url: URL) -> Bool {
        url.pathExtension == directoryExtension
            && FileManager.default.fileExists(atPath: url.appendingPathComponent(screenFileName).path)
    }

    func loadCaptureManifest() -> CaptureManifest? {
        guard let data = try? Data(contentsOf: captureManifestURL) else { return nil }
        return try? CaptureManifest.decoder.decode(CaptureManifest.self, from: data)
    }

    func loadPointerCapture() -> PointerCaptureFile? {
        guard let data = try? Data(contentsOf: pointerCaptureURL) else { return nil }
        return try? CaptureManifest.decoder.decode(PointerCaptureFile.self, from: data)
    }

    func writeCaptureManifest(_ manifest: CaptureManifest) throws {
        let data = try CaptureManifest.encoder.encode(manifest)
        try data.write(to: captureManifestURL, options: .atomic)
    }

    func writePointerCapture(_ capture: PointerCaptureFile) throws {
        let data = try CaptureManifest.encoder.encode(capture)
        do {
            try data.write(to: pointerCaptureURL, options: .atomic)
        } catch {
            // Atomic replacement needs a sibling temporary file. If that
            // narrow operation fails, make one direct attempt before treating
            // the pointer sidecar as lost and surfacing the failure to users.
            try data.write(to: pointerCaptureURL)
        }
    }

    func loadEditDocument() -> RecordingEditDocument? {
        guard let data = try? Data(contentsOf: editDocumentURL) else { return nil }
        return try? CaptureManifest.decoder.decode(RecordingEditDocument.self, from: data)
    }

    func writeEditDocument(_ document: RecordingEditDocument) throws {
        let data = try CaptureManifest.encoder.encode(document)
        try data.write(to: editDocumentURL, options: .atomic)
    }

    // MARK: - Working draft

    func loadDraftDocument() -> RecordingEditDocument? {
        guard let data = try? Data(contentsOf: draftDocumentURL) else { return nil }
        return try? CaptureManifest.decoder.decode(RecordingEditDocument.self, from: data)
    }

    func writeDraftDocument(_ document: RecordingEditDocument) throws {
        let data = try CaptureManifest.encoder.encode(document)
        try data.write(to: draftDocumentURL, options: .atomic)
    }

    func removeDraftDocument() {
        try? FileManager.default.removeItem(at: draftDocumentURL)
    }

    /// Revert to Original: the project's saved edits, its draft and any
    /// render of them, so it opens as a new recording does. The name and
    /// tags stay.
    func removeEdits() throws {
        if FileManager.default.fileExists(atPath: editDocumentURL.path) {
            try FileManager.default.removeItem(at: editDocumentURL)
        }
        removeDraftDocument()
        removeFinalVideos()
    }

    /// What the editor should actually open: the autosaved draft when one
    /// survived, otherwise the last save. Every consumer outside the
    /// editor (flattening, uploads) uses this too, so a deliverable always
    /// reflects the edits the user can see.
    func effectiveEditDocument() -> RecordingEditDocument? {
        loadDraftDocument() ?? loadEditDocument()
    }

    /// Missing legacy edits are fine; existing unreadable edits must never expose the master.
    func editDocumentForRendering() throws -> RecordingEditDocument? {
        let url = FileManager.default.fileExists(atPath: draftDocumentURL.path)
            ? draftDocumentURL : editDocumentURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try CaptureManifest.decoder.decode(RecordingEditDocument.self, from: Data(contentsOf: url))
    }

    /// True when unsaved edits are sitting in the draft. A draft identical to
    /// the saved document is just a leftover and doesn't count.
    var hasUnsavedDraft: Bool {
        guard let draft = loadDraftDocument() else { return false }
        return draft != loadEditDocument()
    }

    // MARK: - Project metadata

    func loadProjectMetadata() -> RecordingProjectMetadata? {
        guard let data = try? Data(contentsOf: projectMetadataURL) else { return nil }
        return try? CaptureManifest.decoder.decode(RecordingProjectMetadata.self, from: data)
    }

    func writeProjectMetadata(_ metadata: RecordingProjectMetadata) throws {
        let data = try CaptureManifest.encoder.encode(metadata)
        try data.write(to: projectMetadataURL, options: .atomic)
    }

    /// Read-modify-write so touching one field never drops the others.
    func updateProjectMetadata(_ mutate: (inout RecordingProjectMetadata) -> Void) throws {
        var metadata = RecordingProjectMetadata()
        if FileManager.default.fileExists(atPath: projectMetadataURL.path) {
            metadata = try CaptureManifest.decoder.decode(RecordingProjectMetadata.self, from: Data(contentsOf: projectMetadataURL))
        }
        metadata.version = RecordingProjectMetadata.currentVersion
        mutate(&metadata)
        try writeProjectMetadata(metadata)
    }

    // MARK: - Render stamp

    private struct RenderStamp: Codable {
        static let currentLayoutVersion = 3
        var layoutVersion = currentLayoutVersion
        var document: RecordingEditDocument?
    }

    func loadRenderStamp() -> RecordingEditDocument? {
        guard let data = try? Data(contentsOf: renderStampURL) else { return nil }
        if let stamp = try? CaptureManifest.decoder.decode(RenderStamp.self, from: data) {
            return stamp.document
        }
        // Older builds stored the edit document directly.
        return try? CaptureManifest.decoder.decode(RecordingEditDocument.self, from: data)
    }

    func writeRenderStamp(_ document: RecordingEditDocument?) {
        guard let data = try? CaptureManifest.encoder.encode(RenderStamp(document: document)) else { return }
        try? data.write(to: renderStampURL, options: .atomic)
    }

    /// The flattened deliverable only when it provably matches `document`.
    /// Export and Share can then skip the render instead of trusting that
    /// nothing has changed since it was made.
    func freshFinalURL(matching document: RecordingEditDocument?) -> URL? {
        // Older renders could include cut caption wording or omit replacement audio.
        guard let existing = existingFinalURL,
              let data = try? Data(contentsOf: renderStampURL),
              let renderStamp = try? CaptureManifest.decoder.decode(RenderStamp.self, from: data),
              renderStamp.layoutVersion == RenderStamp.currentLayoutVersion else { return nil }
        let stamp = renderStamp.document
        if stamp == document { return existing }
        // Swapping only the container leaves every encoded sample intact, so
        // the render survives and export converts it on the way out.
        if let document, Self.differsOnlyByExportContainer(document, stamp) { return existing }
        return nil
    }
}

nonisolated struct CaptureManifest: Codable, Sendable, Equatable {
    var version = 1
    var createdAt = Date()
    /// Duration of the finished screen movie, in seconds.
    var duration: TimeInterval = 0
    var pixelWidth = 0
    var pixelHeight = 0
    /// Points→pixels scale of the captured source (Retina factor).
    var pixelScale: Double = 1
    var sourceDisplayID: UInt32?
    var includesSystemAudio = false
    var includesMicrophone = false
    /// Where the camera movie's t=0 falls on the screen movie's timeline.
    /// Positive means the camera started after the screen recording.
    var cameraLeadIn: TimeInterval?
    var cameraWidth: Int?
    var cameraHeight: Int?
    /// True when the capture excluded the OS cursor, so playback and export
    /// must draw the synthetic pointer from the capture sidecar. Optional so
    /// manifests written before this field decode as nil (cursor in pixels).
    var pointerSynthesized: Bool?
    /// New sessions keep press feedback out of the lossless screen master and
    /// reconstruct it from the pointer capture. Nil means a legacy session
    /// whose pixels may already contain the configured mouse indicators.
    var pressEffectsBaked: Bool?
    var pressEffectsEnabled: Bool?

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

nonisolated enum RecordingSessionStore {
    static var recordingsDirectory: URL {
        return ScreendropStorage.applicationSupportDirectory
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    static func createSession() throws -> RecordingSession {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let name = "Screendrop_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(6))"
        let directory = recordingsDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(RecordingSession.directoryExtension)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return RecordingSession(directoryURL: directory)
    }

    static func allSessions() -> [RecordingSession] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { RecordingSession.isSessionDirectory($0) }
            .map { RecordingSession(directoryURL: $0) }
    }

    static func deleteSession(_ session: RecordingSession) throws {
        try FileManager.default.trashItem(at: session.directoryURL, resultingItemURL: nil)
        Task { await CaptureLibraryThumbnails.shared.remove(for: [session.directoryURL]) }
    }
}
