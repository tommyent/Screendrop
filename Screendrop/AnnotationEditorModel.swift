//
//  AnnotationEditorModel.swift
//  Screendrop
//

import AppKit
import ImageIO
import Observation
import SwiftUI

/// The editor window's model.
///
/// Annotations themselves live in `engine` - the ported drawing-app editor - which owns the
/// document, the selection and the pointer state machine. This type keeps the things that are
/// Screendrop's rather than the engine's: the image being edited, the background recipe, crop, zoom
/// and the inspector's current style.
@MainActor
@Observable
final class AnnotationEditorModel {
    @ObservationIgnored private let annotationEngine = AnnoEditor()
    /// Engine-backed getters must observe the revision even when their view
    /// never reads it directly (for example, the inspector's style controls).
    var engine: AnnoEditor {
        _ = revision
        return annotationEngine
    }
    /// Bumped on every engine change. Views read this to pick up edits the engine made.
    private(set) var revision = 0

    /// The display/history image being edited. Used to match the preview item
    /// and to locate the sidecar document.
    var sourceURL: URL?
    /// The untouched image the annotations are rendered on top of. When
    /// re-editing an existing document this is the preserved base image;
    /// otherwise it is the same as `sourceURL`.
    var baseImageURL: URL? {
        didSet {
            imagePixelsPerPoint = baseImageURL
                .flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
                .map(AnnotationCanvasExpansion.pixelsPerPoint(of:)) ?? 1
        }
    }
    /// The sidecar predates v2. Its marks exist only in the display image the
    /// editor loaded as its base, so restoring `.base.png` would erase them.
    private var isLegacyDocument = false
    private var unreadableEditDocument = false
    var previewImage: NSImage?
    /// The preview image's pixels, for the canvas's redaction passes to sample.
    @ObservationIgnored private(set) var previewCGImage: CGImage? {
        didSet { cachedGrowthFill = nil }
    }

    /// How far annotations past the screenshot's edge grow the canvas, in
    /// image pixels, worked out as the export does. It only changes while
    /// nothing is being drawn, dragged or typed, so the canvas doesn't
    /// rescale under the pointer.
    private(set) var canvasExpansion = AnnotationCanvasExpansion()
    @ObservationIgnored private var imagePixelsPerPoint: CGFloat = 1
    /// Set for a whole press, from before mouse-down can commit a text
    /// edit (the engine is still idle then) until mouse-up.
    @ObservationIgnored private var isPointerDown = false
    @ObservationIgnored private var expansionInputs: (shapes: [AnnoShape], imageSize: CGSize, pixelsPerPoint: CGFloat)?
    @ObservationIgnored private var cachedGrowthFill: CGColor?
    /// Whether the currently displayed `previewImage` is a downscaled copy of
    /// the source (low-resolution preview preference). Exports are unaffected.
    var isPreviewDownscaled = false
    var imageSize: CGSize = .zero

    var selectedTool: AnnotationTool = .select
    var selectedSwatch: AnnotationSwatch = .red
    var strokeWidth: CGFloat = 4
    var geoFill: AnnoFillStyle = .none
    var handDrawn = false
    var magnifierZoom: CGFloat = 3
    var redactionDensity: CGFloat = 0.55
    var backgroundSettings = AnnotationBackgroundSettings() {
        willSet {
            if !isRestoringHistory, !isInspectorEditing, !isPointerDown,
               newValue != backgroundSettings { commitTextEditing() }
        }
        didSet {
            // Wallpaper pickers set the remembered asset before selecting its style.
            var previous = oldValue
            previous.customWallpaper = backgroundSettings.customWallpaper
            guard previous != backgroundSettings else { return }
            if !isInspectorEditing, !isPointerDown { recordHistoryChange(force: true) }
        }
    }
    var appliedBackgroundPresetID: AnnotationBackgroundPreset.ID?
    var errorMessage: String?
    var isSmartRedacting = false
    var smartRedactionMessage: String?

    // MARK: Crop
    /// Whether the modal crop overlay is currently active.
    var isCropping = false
    /// The working crop rectangle, normalized to the image (0...1, top-left
    /// origin). Only meaningful while `isCropping` is true.
    var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The aspect-ratio constraint applied while cropping.
    var cropAspect: CropAspectRatio = .freeform

    // MARK: Zoom & pan
    /// The rendered camera and active gesture are committed as one value.
    var canvasViewport = AnnotationCanvasViewport()
    /// While cropping, the image is fit with this much breathing room (in
    /// points) on every side so the crop resize handles - which are centered on
    /// the crop edges - never spill outside the interactive canvas bounds.
    static let cropHandleMargin: CGFloat = 26

    // Text style defaults (applied to new text, updated when selecting existing text)
    var textFontFamily: AnnoFontFamily = .pro
    /// A face outside the SF families, by PostScript name; nil is the family.
    var textFontFace: String?
    var textFontSize: CGFloat = 48
    var textIsBold = true
    var textIsItalic = false
    var textIsUnderline = false
    var textAlignment: NSTextAlignment = .left
    var textBoxStyle: TextBoxStyle = .plain

    private var history: [EditSnapshot] = []
    private var historyIndex = 0
    private var isRestoringHistory = false
    private var inspectorEditingDepth = 0
    private var isInspectorEditing: Bool { inspectorEditingDepth > 0 }
    private var croppedInSession = false
    private var ownedCropURLs: Set<URL> = []

    /// Smallest crop dimension, in normalized units, derived from a pixel floor.
    private let minimumCropPixels: CGFloat = 24

    /// Longest-edge cap (in pixels) for the downscaled editing preview.
    private let previewImageMaxPixelSize: CGFloat = 2880
    @ObservationIgnored private var wallpaperCacheLease: BoundedCGImageCache.Lease?
    @ObservationIgnored private var smartRedactionTask: Task<Void, Never>?
    private var smartRedactionGeneration = UUID()

    init() {
        engine.tool = selectedTool
        engine.onChange = { [weak self] in
            guard let self else { return }
            recordHistoryChange()
            revision &+= 1
            updateCanvasExpansion()
        }
    }

    // MARK: - Canvas growth

    /// The growth on show. None with a background, camera or bleeding blur,
    /// which give annotations a stage already, matching the export.
    var displayedCanvasExpansion: AnnotationCanvasExpansion {
        backgroundSettings.usesCanvasLayout ? AnnotationCanvasExpansion() : canvasExpansion
    }

    /// The screenshot's edge color, which fills the grown area.
    var canvasGrowthFill: CGColor {
        if let cachedGrowthFill { return cachedGrowthFill }
        guard let previewCGImage else { return CGColor(gray: 1, alpha: 1) }
        let fill = AnnotationCanvasExpansion.edgeColor(
            of: previewCGImage,
            colorSpace: AnnotationRenderer.exportColorSpace(for: previewCGImage)
        )
        cachedGrowthFill = fill
        return fill
    }

    private func updateCanvasExpansion() {
        guard !isPointerDown, case .idle = engine.interaction, editingTextID == nil else { return }
        let shapes = shapes
        if let inputs = expansionInputs, inputs.shapes == shapes,
           inputs.imageSize == imageSize, inputs.pixelsPerPoint == imagePixelsPerPoint {
            return
        }
        expansionInputs = (shapes, imageSize, imagePixelsPerPoint)
        let expansion = AnnotationCanvasExpansion(shapes: shapes, imageSize: imageSize, pixelsPerPoint: imagePixelsPerPoint)
        if expansion != canvasExpansion { canvasExpansion = expansion }
    }

    // MARK: - Engine surface

    var shapes: [AnnoShape] { engine.shapes }
    var bindings: [ArrowBinding] { engine.document.bindings }
    var hasAnnotations: Bool { !engine.shapes.isEmpty }
    var selectionCount: Int { engine.selectedIds.count }
    var editingTextID: AnnoShapeID? { engine.editingTextId }

    var isTransformingExistingAnnotation: Bool {
        switch engine.interaction {
        case .translating, .resizing, .rotating, .draggingArrowHandle, .draggingMagnifier: true
        default: false
        }
    }

    private var selectedShape: AnnoShape? {
        engine.selectedIds.count == 1 ? engine.selectedShapes.first : nil
    }

    var inspectedTool: AnnotationTool? {
        selectedShape?.tool.paletteTool
            ?? engine.selectedShapes.first?.tool.paletteTool
            ?? (selectedTool.createsAnnotation ? selectedTool : nil)
    }

    var isColorStyleAvailable: Bool { isStyleAvailable { $0.supportsColorStyle } }
    var isStrokeStyleAvailable: Bool { isStyleAvailable { $0.supportsStrokeStyle } }
    var isHandDrawnStyleAvailable: Bool { isStyleAvailable { $0.supportsHandDrawnStyle } }
    var isRedactionStyleAvailable: Bool { isStyleAvailable { $0.supportsRedactionDensityStyle } }
    var isFillStyleAvailable: Bool {
        isStyleAvailable { $0.paletteTool == .rectangle || $0 == .ellipse }
    }

    var hasInspectorStyleControls: Bool {
        isTextStyleAvailable || isColorStyleAvailable || isStrokeStyleAvailable || isRedactionStyleAvailable || isFillStyleAvailable
    }

    private func isStyleAvailable(_ supportsStyle: (AnnotationTool) -> Bool) -> Bool {
        let selected = engine.selectedShapes
        if selected.isEmpty {
            return inspectedTool.map(supportsStyle) ?? false
        }
        return selected.contains { supportsStyle($0.tool) }
    }

    // MARK: - Loading

    func load(url: URL?, dismiss: DismissAction) {
        cancelSmartRedaction()
        guard let url else {
            dismiss()
            return
        }

        isRestoringHistory = true
        defer { isRestoringHistory = false }
        history.removeAll()
        historyIndex = 0
        inspectorEditingDepth = 0
        croppedInSession = false

        wallpaperCacheLease = AnnotationBackgroundRenderer.beginWallpaperUse()
        removeOwnedCropFiles()
        applyAnnotationPreset()
        resetZoom()
        sourceURL = url

        let document: AnnotationDocument?
        do {
            document = try ScreenshotHistoryStore.shared.loadEditDocument(for: url)
            unreadableEditDocument = false
        } catch {
            document = nil
            unreadableEditDocument = true
        }
        isLegacyDocument = document.map { $0.version < 2 } ?? false
        let candidateBaseURL = ScreenshotHistoryStore.baseImageURL(for: url)
        let renderSourceURL: URL
        // Background-only and crop-only edits still have a preserved base.
        // Reopening their composite would bake the previous styling into the
        // image and apply it again. Legacy v1 shapes remain raster-only.
        if let document, document.version >= 2,
           FileManager.default.fileExists(atPath: candidateBaseURL.path) {
            renderSourceURL = candidateBaseURL
            backgroundSettings = document.backgroundSettings
            appliedBackgroundPresetID = nil
        } else {
            renderSourceURL = url
            let presetStore = AnnotationBackgroundPresetStore.shared
            let activePreset = presetStore.activePreset
            backgroundSettings = document?.backgroundSettings ?? activePreset?.settings ?? AnnotationBackgroundSettings()
            appliedBackgroundPresetID = document == nil ? activePreset?.id : nil
        }

        baseImageURL = renderSourceURL
        imageSize = ScreenshotImageLoader.imageSize(at: renderSourceURL) ?? .zero
        previewImage = makePreviewImage(from: renderSourceURL)
        previewCGImage = previewImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)

        engine.viewport = AnnoViewport(imageFrame: .zero, imageSize: imageSize)
        var snapshot = AnnoDocument.Snapshot(shapes: document?.shapes ?? [], bindings: document?.bindings ?? [])
        // Before version 3, shapes were placed on the raw pixel grid, while the page is now the
        // upright image. Move them so a mask still covers what it covered in the saved export.
        if let document, document.version < 3 {
            let orientation = ScreenshotImageLoader.orientation(at: renderSourceURL)
            snapshot = snapshot.uprighted(exifOrientation: orientation, uprightSize: imageSize)
        }
        engine.replaceDocument(
            shapes: snapshot.shapes,
            bindings: snapshot.bindings
        )
        engine.tool = selectedTool

        isCropping = false
        cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        cropAspect = .freeform
        RedactionImageProcessor.removeAllCachedPreviewImages()
        errorMessage = unreadableEditDocument ? AnnotationDocumentReadError.unreadable.localizedDescription : nil
        smartRedactionMessage = nil

        if previewImage == nil || imageSize == .zero {
            errorMessage = "Unable to load screenshot."
        }

        markSaved()
    }

    private func makePreviewImage(from url: URL) -> NSImage? {
        if ScreendropPreferences.lowResolutionEditorPreview {
            isPreviewDownscaled = max(imageSize.width, imageSize.height) > previewImageMaxPixelSize
            return ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: previewImageMaxPixelSize)
        } else {
            isPreviewDownscaled = false
            return ScreenshotImageLoader.fullResolutionImage(at: url)
        }
    }

    func releaseEditorResources() {
        isRestoringHistory = true
        defer { isRestoringHistory = false }
        cancelSmartRedaction()
        wallpaperCacheLease = nil
        // A closed SwiftUI scene can outlive its window. Release decoded
        // pixels and edit history now instead of waiting for model deinit.
        savedSnapshot = nil
        sourceURL = nil
        baseImageURL = nil
        previewImage = nil
        previewCGImage = nil
        imageSize = .zero
        isPreviewDownscaled = false
        isCropping = false
        history.removeAll()
        historyIndex = 0
        inspectorEditingDepth = 0
        croppedInSession = false
        engine.replaceDocument(shapes: [])
        removeOwnedCropFiles()
        RedactionImageProcessor.removeAllCachedPreviewImages()
    }

    /// Renders the composite, writes the `.screendrop` sidecar, and repoints
    /// the editor at the preserved base image so continued edits don't re-bake
    /// annotations onto an already-composited picture. Returns nil when there
    /// is nothing to persist.
    ///
    /// This is the only thing that puts annotations on disk, so every route
    /// out of the editor - Done, Save, Upload, the close prompt - goes
    /// through it.
    private(set) var isCommitting = false

    func validateEditDocument() throws {
        guard !unreadableEditDocument else { throw AnnotationDocumentReadError.unreadable }
        if let sourceURL { _ = try ScreenshotHistoryStore.shared.loadEditDocument(for: sourceURL) }
    }

    @discardableResult
    func commitEdits() async throws -> URL? {
        guard !isCommitting else { throw CocoaError(.userCancelled) }
        guard let sourceURL = self.sourceURL else { return nil }
        try validateEditDocument()
        isCommitting = true
        defer { isCommitting = false }
        commitTextEditing()
        inspectorEditingDepth = 0
        recordHistoryChange(force: true)
        var committedSnapshot = currentSnapshot()

        let baseURL = self.baseImageURL ?? sourceURL
        let shapes = self.shapes
        let bindings = self.bindings
        let backgroundSettings = self.backgroundSettings
        let hasContent = !shapes.isEmpty || backgroundSettings.hasRenderableContent || self.isCropped
            || committedSnapshot.baseImageURL != savedSnapshot?.baseImageURL
        // A pre-v2 sidecar has nothing the editor can remove: its marks are the image.
        let hadDocument = !isLegacyDocument && ScreenshotHistoryStore.shared.hasEditDocument(for: sourceURL)

        // Nothing drawn and nothing previously saved: there is no work to lose.
        guard hasContent || hadDocument else {
            self.markSaved()
            return nil
        }

        guard preserveHistoryImage() else {
            throw CocoaError(.fileWriteUnknown)
        }
        let historyBaseURL = self.baseImageURL

        let resultURL: URL
        if hasContent {
            let annotatedURL = try await AnnotationRenderer.renderToTemporaryFileInBackground(
                sourceURL: baseURL,
                shapes: shapes,
                bindings: bindings,
                backgroundSettings: backgroundSettings
            )
            defer { try? FileManager.default.removeItem(at: annotatedURL) }
            let document = AnnotationDocument(
                shapes: shapes,
                bindings: bindings,
                background: backgroundSettings
            )
            resultURL = try ScreenshotHistoryStore.shared.commitAnnotations(
                displayURL: sourceURL,
                baseURL: baseURL,
                renderedURL: annotatedURL,
                document: document
            )
            self.baseImageURL = ScreenshotHistoryStore.baseImageURL(for: resultURL)
            // The sidecar is v2 now, and its base is the composite the old marks live in.
            self.isLegacyDocument = false
        } else {
            // All annotations were cleared on a previously-edited image:
            // restore the untouched original.
            resultURL = try ScreenshotHistoryStore.shared.removeAnnotations(displayURL: sourceURL)
            self.baseImageURL = resultURL
        }

        rebaseHistoryImage(from: historyBaseURL, to: self.baseImageURL)
        committedSnapshot.baseImageURL = self.baseImageURL
        savedSnapshot = committedSnapshot
        removeOwnedCropFiles(keepingHistory: true)
        return resultURL
    }

    // MARK: - Unsaved changes

    /// Everything a commit would persist. The crop rides along as the base
    /// image URL, since cropping replaces the image the annotations render on
    /// rather than adding anything to the document.
    private struct EditSnapshot: Equatable {
        var baseImageURL: URL?
        var imageSize: CGSize
        var isCropped: Bool
        var shapes: [AnnoShape]
        var bindings: [ArrowBinding]
        var background: StoredBackground
    }

    private var savedSnapshot: EditSnapshot?

    private func currentSnapshot() -> EditSnapshot {
        EditSnapshot(
            baseImageURL: baseImageURL,
            imageSize: imageSize,
            isCropped: croppedInSession,
            shapes: shapes,
            bindings: bindings,
            background: StoredBackground(backgroundSettings)
        )
    }

    /// Whether closing now would throw work away. The baseline is taken at the
    /// end of `load` rather than from an empty document, so a background
    /// preset applied automatically on open is not mistaken for a user edit.
    var hasUnsavedChanges: Bool {
        // The engine isn't observable; touching `revision` is what makes this
        // recompute when a shape is drawn, moved, or deleted.
        _ = revision
        guard sourceURL != nil, let savedSnapshot else { return false }
        return currentSnapshot() != savedSnapshot
    }

    /// Re-baselines after a successful commit, and at the end of a load.
    func markSaved() {
        savedSnapshot = currentSnapshot()
        if history.isEmpty {
            history = [currentSnapshot()]
            historyIndex = 0
        }
    }

    /// A continuous inspector drag is one document edit.
    func setInspectorEditing(_ editing: Bool) {
        if editing {
            recordHistoryChange(force: true)
            inspectorEditingDepth += 1
        } else if inspectorEditingDepth > 0 {
            inspectorEditingDepth -= 1
            if !isInspectorEditing { recordHistoryChange(force: true) }
        }
    }

    private func recordHistoryChange(force: Bool = false) {
        guard !isRestoringHistory, !history.isEmpty else { return }
        if !force {
            guard !isInspectorEditing, !isPointerDown, editingTextID == nil,
                  case .idle = engine.interaction else { return }
        }
        let snapshot = currentSnapshot()
        guard snapshot != history[historyIndex] else { return }
        history.removeSubrange((historyIndex + 1)..<history.count)
        history.append(snapshot)
        if history.count > 201 { history.removeFirst() }
        historyIndex = history.count - 1
        removeOwnedCropFiles(keepingHistory: true)
    }

    // MARK: - Pointer

    /// Keep the engine's camera in step with where the canvas is drawing the image.
    func updateViewport(imageFrame: CGRect) {
        engine.viewport = AnnoViewport(imageFrame: imageFrame, imageSize: imageSize)
    }

    private func pointer(at location: CGPoint) -> PointerInfo {
        let flags = NSEvent.modifierFlags
        let screenPoint = Vec(location)
        return PointerInfo(
            screenPoint: screenPoint,
            pagePoint: engine.screenToPage(screenPoint),
            shift: flags.contains(.shift),
            alt: flags.contains(.option),
            command: flags.contains(.command)
        )
    }

    func beginInteraction(at location: CGPoint, imageFrame: CGRect, boundaryFrame: CGRect) {
        guard !isCropping else { return }
        isPointerDown = true
        updateViewport(imageFrame: imageFrame)
        var info = pointer(at: location)
        // SwiftUI's drag gesture does not carry a click count. The mouse event
        // that opened it does, and a double-click is a second press with count 2.
        if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseDragged {
            info.clickCount = event.clickCount
        }
        engine.pointerDown(info)
        selectedTool = engine.tool
        syncStyleFromSelection()
    }

    func updateInteraction(to location: CGPoint, imageFrame: CGRect, boundaryFrame: CGRect) {
        guard !isCropping else { return }
        updateViewport(imageFrame: imageFrame)
        engine.pointerMove(pointer(at: location))
        selectedTool = engine.tool
    }

    func endInteraction(at location: CGPoint, imageFrame: CGRect, boundaryFrame: CGRect) {
        // pointerUp's closing notification, once the engine is idle, then
        // recomputes the growth.
        isPointerDown = false
        guard !isCropping else { return }
        updateViewport(imageFrame: imageFrame)
        engine.pointerUp(pointer(at: location))
        selectedTool = engine.tool
        syncStyleFromSelection()
    }

    func hoveredAnnotation(at location: CGPoint, imageFrame: CGRect, boundaryFrame: CGRect) -> AnnoShape? {
        guard !isCropping, boundaryFrame.contains(location) else { return nil }
        updateViewport(imageFrame: imageFrame)
        return engine.hitShape(at: engine.screenToPage(Vec(location)))
    }

    func updateHoveredAnnotation(at location: CGPoint?, imageFrame: CGRect, boundaryFrame: CGRect) {
        guard !isPointerDown, !NSEvent.modifierFlags.contains(.command), let location else {
            engine.setHoveredShape(nil)
            return
        }
        engine.setHoveredShape(hoveredAnnotation(at: location, imageFrame: imageFrame, boundaryFrame: boundaryFrame)?.id)
    }

    /// Whether a selection handle sits under the pointer, so the canvas can show a resize cursor.
    func hoveredHandle(at location: CGPoint, imageFrame: CGRect) -> AnnoSelectionHandle? {
        updateViewport(imageFrame: imageFrame)
        return engine.handle(at: Vec(location))
    }

    func containsInteractionPoint(_ location: CGPoint, imageFrame: CGRect, boundaryFrame: CGRect) -> Bool {
        boundaryFrame.contains(location)
    }

    // MARK: - Tools and style

    func selectTool(_ tool: AnnotationTool) {
        if tool == .filledRectangle { geoFill = .solid; engine.currentGeoFill = .solid }
        selectedTool = tool.paletteTool
        engine.tool = selectedTool
        saveAnnotationPreset()
    }

    func setGeoFill(_ fill: AnnoFillStyle) {
        geoFill = fill
        engine.currentGeoFill = fill
        saveAnnotationPreset()
        engine.applyStyleToSelection { shape in
            if case var .geo(props) = shape.kind {
                props.fill = fill
                shape.kind = .geo(props)
            }
        }
    }

    func setMagnifierZoom(_ zoom: CGFloat) {
        guard zoom.isFinite, (1...8).contains(zoom) else { return }
        magnifierZoom = zoom
        engine.currentMagnifierZoom = Double(zoom)
        engine.applyStyleToSelection { shape in
            if case var .magnifier(props) = shape.kind {
                props.loupeSize = props.ringSize * Double(zoom)
                shape.kind = .magnifier(props)
            }
        }
    }

    func setHandDrawn(_ enabled: Bool) {
        handDrawn = enabled
        engine.currentDash = enabled ? .draw : .solid
        saveAnnotationPreset()
        engine.applyStyleToSelection { shape in
            switch shape.kind {
            case var .geo(props): props.dash = enabled ? .draw : .solid; shape.kind = .geo(props)
            case var .arrow(props): props.dash = enabled ? .draw : .solid; shape.kind = .arrow(props)
            default: break
            }
        }
    }

    func setSwatch(_ swatch: AnnotationSwatch) {
        selectedSwatch = swatch
        engine.currentSwatch = swatch
        saveAnnotationPreset()

        engine.applyStyleToSelection { shape in
            switch shape.kind {
            case var .geo(p): p.swatch = swatch; shape.kind = .geo(p)
            case var .draw(p): p.swatch = swatch; shape.kind = .draw(p)
            case var .arrow(p): p.swatch = swatch; shape.kind = .arrow(p)
            case var .text(p): p.swatch = swatch; shape.kind = .text(p)
            case var .numbered(p): p.swatch = swatch; shape.kind = .numbered(p)
            case var .magnifier(p): p.swatch = swatch; shape.kind = .magnifier(p)
            case .redaction, .highlight: break
            }
        }
    }

    func setStrokeWidth(_ width: CGFloat) {
        strokeWidth = width
        engine.currentStrokeWidth = Double(width)
        saveAnnotationPreset()

        let pageWidth = engine.pageStrokeWidth(Double(width))
        engine.applyStyleToSelection { shape in
            switch shape.kind {
            case var .geo(p): p.strokeWidth = pageWidth; shape.kind = .geo(p)
            case var .draw(p): p.strokeWidth = pageWidth; shape.kind = .draw(p)
            case var .arrow(p): p.strokeWidth = pageWidth; shape.kind = .arrow(p)
            case var .magnifier(p): p.strokeWidth = pageWidth; shape.kind = .magnifier(p)
            default: break
            }
        }
    }

    func setRedactionDensity(_ density: CGFloat) {
        redactionDensity = density
        engine.currentRedactionDensity = Double(density)
        saveAnnotationPreset()

        engine.applyStyleToSelection { shape in
            if case var .redaction(p) = shape.kind {
                p.density = Double(density)
                shape.kind = .redaction(p)
            }
        }
    }

    /// Pull the inspector's values from whatever is selected, so selecting a shape shows its style.
    private func syncStyleFromSelection() {
        guard let shape = selectedShape else { return }
        if let dash = shape.geoProps?.dash ?? shape.arrowProps?.dash {
            handDrawn = dash == .draw
            engine.currentDash = dash
        }
        if case let .magnifier(props) = shape.kind {
            magnifierZoom = CGFloat(props.zoom)
            engine.currentMagnifierZoom = props.zoom
        }
        if case let .geo(props) = shape.kind {
            geoFill = props.fill
            engine.currentGeoFill = props.fill
        }
        if let swatch = shape.swatch, shape.tool.supportsColorStyle {
            selectedSwatch = swatch
            engine.currentSwatch = swatch
        }
        if shape.tool.supportsStrokeStyle, shape.strokeWidth > 0 {
            strokeWidth = CGFloat(engine.sliderStrokeWidth(shape.strokeWidth))
            engine.currentStrokeWidth = Double(strokeWidth)
        }
        if let props = shape.redactionProps {
            redactionDensity = CGFloat(props.density)
            engine.currentRedactionDensity = props.density
        }
        if let props = shape.textProps {
            textFontFamily = props.fontFamily
            textFontFace = props.fontFace
            textFontSize = CGFloat(props.fontSize)
            textIsBold = props.isBold
            textIsItalic = props.isItalic
            textIsUnderline = props.isUnderline
            textAlignment = props.align.nsTextAlignment
            textBoxStyle = props.boxStyle ?? .plain
        }
    }

    // MARK: - Editing commands

    func deleteSelectedAnnotation() {
        engine.deleteSelected()
    }

    func selectAllAnnotations() {
        engine.selectAll()
    }

    func escapeSelectionOrDisarm() {
        engine.escapeSelectionOrDisarm()
        selectedTool = engine.tool
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        engine.nudgeSelected(dx: Double(dx), dy: Double(dy))
    }

    func commitTextEditing() {
        engine.stopEditingText()
    }

    func setText(_ text: String, for id: AnnoShapeID) {
        engine.updateEditingText(id, to: text)
    }

    func undo() {
        guard !isCropping else { return }
        commitTextEditing()
        inspectorEditingDepth = 0
        recordHistoryChange(force: true)
        guard historyIndex > 0 else { return }
        guard history[historyIndex - 1].baseImageURL == baseImageURL || preserveHistoryImage() else {
            errorMessage = "Unable to preserve the image for redo."
            return
        }
        historyIndex -= 1
        restore(history[historyIndex])
    }

    func redo() {
        guard !isCropping else { return }
        commitTextEditing()
        inspectorEditingDepth = 0
        recordHistoryChange(force: true)
        guard historyIndex + 1 < history.count else { return }
        guard history[historyIndex + 1].baseImageURL == baseImageURL || preserveHistoryImage() else {
            errorMessage = "Unable to preserve the image for undo."
            return
        }
        historyIndex += 1
        restore(history[historyIndex])
    }

    // MARK: - Smart redaction

    func smartRedact(using tool: AnnotationTool) {
        guard tool.isRedactionTool,
              !isSmartRedacting,
              let recognitionURL = baseImageURL ?? sourceURL else {
            return
        }

        let loadedSourceURL = sourceURL
        isSmartRedacting = true
        smartRedactionMessage = nil

        let generation = UUID()
        smartRedactionGeneration = generation
        smartRedactionTask = Task { @MainActor [weak self] in
            let regions = await SmartRedactionRecognizer.sensitiveRegions(at: recognitionURL)

            guard !Task.isCancelled, let self, self.smartRedactionGeneration == generation else { return }
            self.smartRedactionTask = nil
            self.isSmartRedacting = false
            guard self.sourceURL == loadedSourceURL,
                  self.baseImageURL == recognitionURL || self.sourceURL == recognitionURL else { return }

            self.applySmartRedactionRegions(regions, tool: tool)
        }
    }

    private func cancelSmartRedaction() {
        smartRedactionGeneration = UUID()
        smartRedactionTask?.cancel()
        smartRedactionTask = nil
        isSmartRedacting = false
    }

    private func applySmartRedactionRegions(_ regions: [SmartRedactionRegion], tool: AnnotationTool) {
        // Recognition reports normalized rects; page space is image pixels.
        let renderable = regions.compactMap { region -> AnnoShape? in
            let rect = CGRect(
                x: region.bounds.minX * imageSize.width,
                y: region.bounds.minY * imageSize.height,
                width: region.bounds.width * imageSize.width,
                height: region.bounds.height * imageSize.height
            )
            guard rect.width >= 2, rect.height >= 2 else { return nil }
            var props = RedactionProps()
            props.kind = tool == .blur ? .blur : .pixelate
            props.density = Double(redactionDensity)
            props.w = Double(rect.width)
            props.h = Double(rect.height)
            return AnnoShape(x: Double(rect.minX), y: Double(rect.minY), kind: .redaction(props))
        }

        guard !renderable.isEmpty else {
            smartRedactionMessage = "No sensitive text found."
            return
        }

        engine.markUndo()
        for shape in renderable { engine.document.add(shape) }
        engine.selectedIds = Set(renderable.map(\.id))
        selectedTool = tool
        engine.tool = tool
        engine.notifyChanged()
        smartRedactionMessage = "Added \(renderable.count) redaction\(renderable.count == 1 ? "" : "s")."
    }

    // MARK: - Bounds

    func annotationBounds(for imageFrame: CGRect, boundaryFrame: CGRect) -> CGRect {
        guard imageFrame.width > 0, imageFrame.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(
            x: (boundaryFrame.minX - imageFrame.minX) / imageFrame.width,
            y: (boundaryFrame.minY - imageFrame.minY) / imageFrame.height,
            width: boundaryFrame.width / imageFrame.width,
            height: boundaryFrame.height / imageFrame.height
        )
    }

    // MARK: - Presets

    private func applyAnnotationPreset() {
        let preset = AnnotationPresetStore.load()
        selectedTool = .select
        selectedSwatch = preset.swatch
        strokeWidth = CGFloat(preset.strokeWidth)
        geoFill = preset.geoFill
        handDrawn = preset.handDrawn ?? false
        redactionDensity = CGFloat(preset.redactionDensity)
        textFontFamily = AnnoFontFamily(rawValue: preset.textFontName) ?? .pro
        textFontFace = preset.textFontFace
        // Clamped here too, so a preset saved out of range by an older build heals on open.
        textFontSize = AnnotationTextMetrics.clampedFontSize(CGFloat(preset.textFontSize))
        textIsBold = preset.textIsBold
        textIsItalic = preset.textIsItalic
        textIsUnderline = preset.textIsUnderline
        textAlignment = preset.textAlignment
        textBoxStyle = preset.textBoxStyle

        engine.tool = selectedTool
        engine.currentSwatch = selectedSwatch
        engine.currentStrokeWidth = Double(strokeWidth)
        engine.currentGeoFill = geoFill
        engine.currentDash = handDrawn ? .draw : .solid
        engine.currentRedactionDensity = Double(redactionDensity)
        engine.currentFontFamily = textFontFamily
        engine.currentFontFace = textFontFace
        engine.currentTextFontSize = Double(textFontSize)
        engine.currentTextIsBold = textIsBold
        engine.currentTextIsItalic = textIsItalic
        engine.currentTextIsUnderline = textIsUnderline
        engine.currentTextAlign = TextAlign(textAlignment)
        engine.currentTextBoxStyle = textBoxStyle
    }

    func saveAnnotationPreset() {
        let customSwatch = AnnotationSwatch.allCases.contains(selectedSwatch) ? nil : CodableSwatch(swatch: selectedSwatch)
        let preset = AnnotationStylePreset(
            selectedToolRawValue: selectedTool.rawValue,
            swatchID: selectedSwatch.id,
            customSwatch: customSwatch,
            strokeWidth: Double(strokeWidth),
            redactionDensity: Double(redactionDensity),
            textFontName: textFontFamily.rawValue,
            textFontFace: textFontFace,
            textFontSize: Double(textFontSize),
            textIsBold: textIsBold,
            textIsItalic: textIsItalic,
            textIsUnderline: textIsUnderline,
            textAlignmentRawValue: textAlignment.rawValue,
            textBoxStyleRawValue: textBoxStyle.rawValue,
            geoFillRawValue: geoFill.rawValue,
            handDrawn: handDrawn
        )
        AnnotationPresetStore.save(preset)
    }

    /// Applies the complete reusable background recipe to this editor.
    func applyBackgroundPreset(_ preset: AnnotationBackgroundPreset) {
        backgroundSettings = preset.settings
        appliedBackgroundPresetID = preset.id
    }
}

// MARK: - Crop

extension AnnotationEditorModel {
    /// Whether the image has been cropped in this editing session (and can be undone).
    var isCropped: Bool { croppedInSession }

    /// Pixel dimensions of the current crop selection.
    var cropPixelSize: CGSize {
        CGSize(
            width: (cropRect.width * imageSize.width).rounded(),
            height: (cropRect.height * imageSize.height).rounded()
        )
    }

    func beginCropping() {
        guard imageSize != .zero, !isCropping else { return }

        commitTextEditing()
        engine.selectedIds.removeAll()
        cropAspect = .freeform
        cropRect = CropRectEditor.unit
        fitCanvas()
        isCropping = true
    }

    func cancelCrop() {
        guard isCropping else { return }
        isCropping = false
        cropRect = CropRectEditor.unit
        cropAspect = .freeform
    }

    func toggleCropping() {
        isCropping ? cancelCrop() : beginCropping()
    }

    func resetCrop() {
        guard isCropping else { return }
        if let ratio = cropAspect.normalizedRatio(imageSize: imageSize) {
            cropRect = CropRectEditor.applyAspect(to: CropRectEditor.unit, aspect: ratio)
        } else {
            cropRect = CropRectEditor.unit
        }
    }

    func setCropAspect(_ aspect: CropAspectRatio) {
        cropAspect = aspect
        guard isCropping else { return }
        if let ratio = aspect.normalizedRatio(imageSize: imageSize) {
            cropRect = CropRectEditor.applyAspect(to: cropRect, aspect: ratio)
        }
    }

    func updateCrop(handle: CropHandle, toNormalized point: CGPoint) {
        guard isCropping else { return }
        let aspect = handle.isCorner ? cropAspect.normalizedRatio(imageSize: imageSize) : nil
        cropRect = CropRectEditor.resize(
            cropRect,
            handle: handle,
            to: point,
            aspect: aspect,
            minWidth: minimumCropWidth,
            minHeight: minimumCropHeight,
            fromCenter: isCropCenterResizeModifierPressed
        )
    }

    private var isCropCenterResizeModifierPressed: Bool {
        let flags = NSEvent.modifierFlags
        return flags.contains(.option) || (flags.contains(.command) && flags.contains(.shift))
    }

    func moveCrop(byNormalized delta: CGSize) {
        guard isCropping else { return }
        cropRect = CropRectEditor.move(cropRect, by: delta)
    }

    /// Bake the crop into a new full-resolution base image, move the shapes with it, and exit crop
    /// mode. Page space is image pixels, so a crop is a translation plus a scale on every shape.
    func applyCrop() {
        guard isCropping else { return }

        let crop = cropRect.standardized.intersection(CropRectEditor.unit)
        defer {
            isCropping = false
            cropRect = CropRectEditor.unit
            cropAspect = .freeform
        }

        guard crop.width > 0.0001, crop.height > 0.0001 else { return }
        if crop.minX < 0.0005, crop.minY < 0.0005, crop.width > 0.999, crop.height > 0.999 { return }

        guard let baseURL = baseImageURL,
              let result = AnnotationImageCropper.crop(url: baseURL, normalizedRect: crop) else {
            errorMessage = "Unable to crop the image."
            return
        }

        guard preserveHistoryImage() else {
            try? FileManager.default.removeItem(at: result.url)
            errorMessage = "Unable to preserve the image for crop undo."
            return
        }

        let oldImageSize = imageSize
        let usedCrop = result.normalizedRect
        let newImageSize = result.pixelSize

        let offsetX = Double(usedCrop.minX * oldImageSize.width)
        let offsetY = Double(usedCrop.minY * oldImageSize.height)
        let scaleX = usedCrop.width > 0 ? Double(newImageSize.width) / Double(usedCrop.width * oldImageSize.width) : 1
        let scaleY = usedCrop.height > 0 ? Double(newImageSize.height) / Double(usedCrop.height * oldImageSize.height) : 1
        let uniform = (scaleX + scaleY) / 2

        let moved = engine.shapes.map { shape -> AnnoShape in
            var shape = shape
            shape.x = (shape.x - offsetX) * scaleX
            shape.y = (shape.y - offsetY) * scaleY
            scaleShapeContents(&shape, sx: scaleX, sy: scaleY, uniform: uniform)
            return shape
        }

        // Annotations the crop leaves entirely outside the image go with the
        // part cut away; kept, they'd grow the canvas straight back out.
        // Undoing the crop brings them back.
        let cropped = AnnoDocument()
        cropped.restore(AnnoDocument.Snapshot(shapes: moved, bindings: engine.document.bindings))
        let image = Box(0, 0, Double(newImageSize.width), Double(newImageSize.height))
        cropped.delete(Set(moved.compactMap { shape in
            cropped.pageBounds(shape.id)?.collides(image) == false ? shape.id : nil
        }))

        croppedInSession = true
        baseImageURL = result.url
        ownedCropURLs.insert(result.url)
        imageSize = newImageSize
        previewImage = makePreviewImage(from: result.url)
        previewCGImage = previewImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        engine.viewport = AnnoViewport(imageFrame: engine.viewport.imageFrame, imageSize: imageSize)
        engine.replaceDocument(shapes: cropped.shapes, bindings: cropped.bindings)

        recordHistoryChange()

        resetZoom()
        errorMessage = nil
    }

    /// Scale a shape's own dimensions, so a crop that changes the image's resolution keeps
    /// annotations the same size relative to the picture.
    private func scaleShapeContents(_ shape: inout AnnoShape, sx: Double, sy: Double, uniform: Double) {
        switch shape.kind {
        case var .geo(p):
            p.w *= sx; p.h *= sy
            p.strokeWidth *= uniform
            p.cornerRadius *= uniform
            shape.kind = .geo(p)
        case var .redaction(p):
            p.w *= sx; p.h *= sy
            shape.kind = .redaction(p)
        case var .highlight(p):
            p.w *= sx; p.h *= sy
            shape.kind = .highlight(p)
        case var .numbered(p):
            p.diameter *= uniform
            shape.kind = .numbered(p)
        case var .magnifier(p):
            p.ring = Vec(p.ring.x * sx, p.ring.y * sy)
            p.loupe = Vec(p.loupe.x * sx, p.loupe.y * sy)
            p.ringSize *= uniform; p.loupeSize *= uniform; p.strokeWidth *= uniform
            shape.kind = .magnifier(p)
        case var .draw(p):
            p.points = p.points.map { Vec($0.x * sx, $0.y * sy, $0.z) }
            p.strokeWidth *= uniform
            shape.kind = .draw(p)
        case var .arrow(p):
            p.start = Vec(p.start.x * sx, p.start.y * sy)
            p.end = Vec(p.end.x * sx, p.end.y * sy)
            p.bend *= uniform
            p.strokeWidth *= uniform
            shape.kind = .arrow(p)
        case var .text(p):
            p.fontSize *= uniform
            p.w *= sx
            shape.kind = .text(p)
        }
    }

    private func preserveHistoryImage() -> Bool {
        guard let baseImageURL else { return true }
        guard let stableURL = stableCropSnapshotURL(for: baseImageURL) else { return false }
        rebaseHistoryImage(from: baseImageURL, to: stableURL)
        self.baseImageURL = stableURL
        return true
    }

    private func rebaseHistoryImage(from oldURL: URL?, to newURL: URL?) {
        for index in history.indices where history[index].baseImageURL == oldURL {
            history[index].baseImageURL = newURL
        }
        if savedSnapshot?.baseImageURL == oldURL { savedSnapshot?.baseImageURL = newURL }
    }

    /// History must never retain a mutable image URL, because annotation commits can
    /// replace that file while this editor stays open.
    private func stableCropSnapshotURL(for url: URL) -> URL? {
        if ownedCropURLs.contains(url) { return url }

        let fileExtension = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let destinationURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Screendrop_CropSnapshot_\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(fileExtension)

        do {
            try FileManager.default.copyItem(at: url, to: destinationURL)
            ownedCropURLs.insert(destinationURL)
            return destinationURL
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            return nil
        }
    }

    private func restore(_ snapshot: EditSnapshot) {
        isRestoringHistory = true
        defer { isRestoringHistory = false }
        let imageChanged = baseImageURL != snapshot.baseImageURL || imageSize != snapshot.imageSize
        if imageChanged {
            baseImageURL = snapshot.baseImageURL
            imageSize = snapshot.imageSize
            previewImage = snapshot.baseImageURL.flatMap(makePreviewImage(from:))
            previewCGImage = previewImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            engine.viewport = AnnoViewport(imageFrame: engine.viewport.imageFrame, imageSize: imageSize)
            resetZoom()
        }
        croppedInSession = snapshot.isCropped
        backgroundSettings = snapshot.background.settings
        let selection = engine.selectedIds
        engine.replaceDocument(shapes: snapshot.shapes, bindings: snapshot.bindings)
        engine.selectedIds = selection.filter { engine.document.shape($0) != nil }
    }

    private func removeOwnedCropFiles(keepingHistory: Bool = false) {
        var retainedURLs: Set<URL> = []
        if keepingHistory {
            retainedURLs = Set(history.compactMap(\.baseImageURL))
            if let baseImageURL { retainedURLs.insert(baseImageURL) }
            if let savedURL = savedSnapshot?.baseImageURL { retainedURLs.insert(savedURL) }
        }
        for url in ownedCropURLs.subtracting(retainedURLs) {
            do {
                try FileManager.default.removeItem(at: url)
                ownedCropURLs.remove(url)
            } catch {
                // Keep failed deletions owned so close can retry.
            }
        }
    }

    private var minimumCropWidth: CGFloat {
        guard imageSize.width > 0 else { return 0.05 }
        return min(0.5, max(0.01, minimumCropPixels / imageSize.width))
    }

    private var minimumCropHeight: CGFloat {
        guard imageSize.height > 0 else { return 0.05 }
        return min(0.5, max(0.01, minimumCropPixels / imageSize.height))
    }
}
