import CoreGraphics
import Foundation

/// Pixels and editable content must come from the same point in time.
struct AnnotationSaveSnapshot {
    let baseURL: URL
    let document: AnnotationDocument
    let images: [String: CGImage]
    let background: AnnotationBackgroundSettings

    func render() async throws -> URL {
        try await AnnotationRenderer.renderToTemporaryFileInBackground(
            sourceURL: baseURL,
            shapes: document.shapes,
            bindings: document.bindings,
            images: images,
            backgroundSettings: background
        )
    }
}
