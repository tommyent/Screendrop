//
//  RecordingProject.swift
//  Screendrop
//
//  Per-project bookkeeping that lives beside the capture manifest: the name
//  shown in the Projects browser, when the project was last committed with
//  ⌘S, and when it was last opened (which orders the Recordings menu).
//  Every field is optional so a package recorded before projects existed -
//  or one whose sidecar was lost - still resolves to sensible defaults.
//

import Foundation

nonisolated struct RecordingProjectMetadata: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var version: Int?
    var displayName: String?
    /// Last save to `edit.json`. Nil for a project that has only ever
    /// written a draft.
    var savedAt: Date?
    var lastOpenedAt: Date?
    /// Library tags. Optional so project files without them still decode.
    var tags: [String]?
    var chapters: [RecordingChapter]?
    var narrationSummary: String?

    init(
        version: Int? = RecordingProjectMetadata.currentVersion,
        displayName: String? = nil,
        savedAt: Date? = nil,
        lastOpenedAt: Date? = nil
    ) {
        self.version = version
        self.displayName = displayName
        self.savedAt = savedAt
        self.lastOpenedAt = lastOpenedAt
    }
}
