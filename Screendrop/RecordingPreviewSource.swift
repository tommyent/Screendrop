import Foundation

/// Resolve posters without encoding a whole movie, but never sample a stale flatten.
nonisolated struct RecordingPreviewSource: Sendable {
    let url: URL
    let redactions: [RecordingRedaction]
    let revision: String

    @MainActor init(_ mediaURL: URL) throws {
        if let session = RecordingDeliverable.session(for: mediaURL) {
            let document = try session.editDocumentForRendering()
            let fresh = session.freshFinalURL(matching: document)
            url = fresh ?? session.screenURL
            redactions = fresh == nil ? document?.redactions ?? [] : []
        } else {
            url = mediaURL
            redactions = []
        }
        revision = try JSONEncoder().encode(redactions).base64EncodedString()
    }
}
