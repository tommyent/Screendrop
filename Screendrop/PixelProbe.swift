import AppKit
import Observation

/// The screenshot's pixels under the editor's pointer (sd-t4k, sd-p31): the
/// colour the inspector shows and Tab copies, and which way a held arrow key
/// is measuring. Each editor window owns one, apart from
/// `AnnotationEditorModel`, since it's about the source pixels rather than
/// the annotations.
@Observable
final class PixelProbe {
    /// The base image at full resolution; nil until it's decoded.
    private(set) var buffer: PixelBuffer?
    /// Pixels per point, from the image's DPI.
    private(set) var pixelsPerPoint: CGFloat = 1
    /// The colour under the pointer; nil off the image.
    private(set) var hovered: PixelColor?
    /// The hex Tab copied, for a moment, so the inspector can confirm it.
    private(set) var copiedHex: String?
    /// Set while an arrow key is held over the image.
    private(set) var measuring: PixelMeasureAxis?

    @ObservationIgnored private var previewID: ObjectIdentifier?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var decodeTask: Task<PixelBuffer?, Never>?
    @ObservationIgnored private var clearCopied: Task<Void, Never>?

    func image(for preview: CGImage?) -> CGImage? {
        previewID == preview.map(ObjectIdentifier.init) ? buffer?.image : nil
    }

    /// Reads the base image at full resolution, off the main thread. Run
    /// whenever the base image changes: on open, and after a crop or its undo.
    func load(_ url: URL?, preview: CGImage?) async {
        let previous = decodeTask
        release()
        previewID = preview.map(ObjectIdentifier.init)
        let expectedGeneration = generation
        guard let url, preview != nil else { return }
        pixelsPerPoint = CGImageSourceCreateWithURL(url as CFURL, nil)
            .map(AnnotationCanvasExpansion.pixelsPerPoint(of:)) ?? 1
        let task = Task.detached(priority: .userInitiated) {
            // ImageIO cannot interrupt a draw. Don't overlap it with a crop/undo reload.
            _ = await previous?.value
            guard !Task.isCancelled else { return nil as PixelBuffer? }
            return autoreleasepool {
                ScreenshotImageLoader.uprightImage(at: url).flatMap(PixelBuffer.init(image:))
            }
        }
        decodeTask = task
        let decoded = await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        guard !Task.isCancelled, generation == expectedGeneration else { return }
        decodeTask = nil
        buffer = decoded
    }

    func release() {
        generation = UUID()
        decodeTask?.cancel()
        decodeTask = nil
        clearCopied?.cancel()
        clearCopied = nil
        copiedHex = nil
        previewID = nil
        buffer = nil
        hovered = nil
        measuring = nil
    }

    /// Follows the pointer, in canvas points after the camera's unproject;
    /// nil once it leaves the canvas.
    func hover(_ location: CGPoint?, imageFrame: CGRect) {
        let color = location
            .flatMap { buffer?.pixel(at: $0, imageFrame: imageFrame) }
            .flatMap { buffer?.color(x: $0.x, y: $0.y) }
        if color != hovered { hovered = color }
        // Leaving the canvas ends a measurement; the held key's repeats
        // start it again on the way back.
        if location == nil { measuring = nil }
    }

    /// An arrow key went down (an axis) or up (nil). A measurement starts
    /// only over the image, so elsewhere the arrows reach the focused
    /// control. Returns whether the key was used.
    func measure(_ axis: PixelMeasureAxis?) -> Bool {
        guard let axis else {
            measuring = nil
            return false
        }
        guard hovered != nil || measuring != nil else { return false }
        if measuring != axis { measuring = axis }
        return true
    }

    /// Tab: puts the hovered colour's hex on the pasteboard. Only over the
    /// image, so elsewhere Tab still moves the keyboard focus.
    func copyHovered() -> Bool {
        guard let hex = hovered?.hex else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        copiedHex = hex
        clearCopied?.cancel()
        clearCopied = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copiedHex = nil
        }
        return true
    }
}
