import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Draws a document's shapes into a `CGContext`.
///
/// The canvas and the exporter both come through here, differing only in the transform they pass
/// and the resolution of the screenshot they hand over - which is what makes the preview a true
/// reduction of the export rather than a second implementation that happens to agree.
///
/// Three passes, in this order:
///  1. Redactions, which transform screenshot pixels and so must sit under everything.
///  2. The spotlight: one dimming layer over the image with a hole punched per highlight shape.
///  3. Every other shape, in z-order.
enum AnnoShapeDrawing {
    /// Everything a draw needs to know about where the page sits and what it is drawn over.
    struct Target {
        /// Page space -> context space.
        var transform: CGAffineTransform
        /// The image's extent in page units.
        var pageSize: CGSize
        /// The pixels currently under a context-space rect, for redactions to process.
        ///
        /// A closure rather than an image because the two callers sample different things: the
        /// canvas hands back a crop of the screenshot, while the exporter snapshots the composed
        /// context so a blur picks up the background behind a transparent screenshot too.
        var sample: ((CGRect) -> CGImage?)?
        /// Clip applied to the spotlight layer, so it follows a rounded screenshot frame.
        var spotlightClip: CGPath?
        /// True for the canvas, whose `NSView` is flipped, false for the export bitmap. Core
        /// Graphics lays an image into the rect it is given the same way up either way, so the
        /// flipped case has to invert it back.
        var isFlippedContext = false
        var redactionPreviewCache: AnnoRedactionPreviewCache? = nil
        /// Pixels `sample` returns per page pixel. Redaction strength is measured in page pixels,
        /// so a canvas sampling a downscaled preview blurs and pixelates by proportionally less
        /// and shows what the full-resolution export will produce. A pixelate block can't be
        /// smaller than one sampled pixel, so on extremely downscaled previews (1200x57600 at a
        /// 0.05 scale) the canvas shows coarser blocks than the export.
        var sampleScale: CGFloat = 1
        /// Decoded base pixels, never the composed canvas or another annotation.
        var fullResolutionSource: CGImage? = nil
        var magnifierPreviewCache: AnnoMagnifierPreviewCache? = nil

        var pageRect: CGRect { CGRect(origin: .zero, size: pageSize) }
    }

    nonisolated(unsafe) private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    nonisolated static func clearCaches() { ciContext.clearCaches() }

    static func draw(
        _ document: AnnoDocument,
        in context: CGContext,
        target: Target,
        skipping skipped: Set<AnnoShapeID> = []
    ) {
        let shapes = document.shapes.filter { !skipped.contains($0.id) }
        let magnifierSource = shapes.contains { if case .magnifier = $0.kind { return true }; return false }
            ? redactedMagnifierSource(document, target: target) : nil

        for shape in shapes where shape.isRedaction {
            drawRedaction(shape, document: document, in: context, target: target)
        }

        drawSpotlight(shapes.filter { $0.isHighlight }, in: context, target: target)

        for shape in shapes where !shape.isRedaction && !shape.isHighlight {
            drawShape(shape, document: document, in: context, target: target, magnifierSource: magnifierSource)
        }
    }

    // MARK: - One shape

    static func drawShape(
        _ shape: AnnoShape,
        document: AnnoDocument,
        in context: CGContext,
        target: Target,
        magnifierSource: CGImage? = nil
    ) {
        let elements = document.renderElements(shape.id)
        guard !elements.isEmpty else { return }

        context.saveGState()
        context.concatenate(shape.pageTransform.cgAffineTransform.concatenating(target.transform))
        if shape.opacity < 1 { context.setAlpha(shape.opacity) }

        for element in elements {
            switch element.content {
            case let .path(path), let .glyphs(path):
                if let fill = element.fill {
                    context.addPath(path)
                    context.setFillColor(fill.cgColor)
                    context.fillPath(using: element.usesEvenOddFill ? .evenOdd : .winding)
                }
                if let stroke = element.stroke {
                    context.addPath(path)
                    context.setStrokeColor(stroke.cgColor)
                    context.setLineWidth(element.strokeWidth)
                    context.setLineCap(.round)
                    context.setLineJoin(.round)
                    if element.dashes.isEmpty {
                        context.setLineDash(phase: 0, lengths: [])
                    } else {
                        context.setLineDash(phase: element.dashPhase, lengths: element.dashes)
                    }
                    context.strokePath()
                    context.setLineDash(phase: 0, lengths: [])
                }
            case let .numbered(props):
                drawNumbered(props, in: context)
            case let .magnifier(props):
                drawMagnifier(props, shape: shape, source: magnifierSource, in: context, pageSize: target.pageSize)
            case .redaction, .spotlight:
                // Handled by their own passes, which need the screenshot underneath.
                break
            }
        }
        context.restoreGState()
    }

    // MARK: - Numbered callout

    /// Use the existing redaction pass on the base alone, before any vector marks or loupes.
    private static func redactedMagnifierSource(_ document: AnnoDocument, target: Target) -> CGImage? {
        guard let source = target.fullResolutionSource,
              CGFloat(source.width) == target.pageSize.width,
              CGFloat(source.height) == target.pageSize.height else { return nil }
        let redactions = document.shapes.filter { $0.isRedaction }
        guard !redactions.isEmpty else { return source }
        let render = { () -> CGImage? in
            let space = source.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
            guard let clean = CGContext(data: nil, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            clean.draw(source, in: target.pageRect)
            let cleanTarget = Target(
                transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: target.pageSize.height),
                pageSize: target.pageSize,
                sample: { rect in
                    clean.makeImage()?.cropping(to: CGRect(x: rect.minX, y: target.pageSize.height - rect.maxY,
                        width: rect.width, height: rect.height).integral)
                }, spotlightClip: nil
            )
            for shape in redactions { drawRedaction(shape, document: document, in: clean, target: cleanTarget) }
            return clean.makeImage()
        }
        if let cache = target.magnifierPreviewCache { return cache.image(source: source, redactions: redactions, render: render) }
        return render()
    }

    private static func drawMagnifier(_ props: MagnifierProps, shape: AnnoShape, source: CGImage?,
        in context: CGContext, pageSize: CGSize) {
        guard props.isValid else { return }
        let ring = MagnifierProps.path(props.ringRect), loupe = MagnifierProps.path(props.loupeRect)
        context.setStrokeColor(props.swatch.nsColor.cgColor)
        context.setLineWidth(props.strokeWidth)
        context.setLineCap(.round)
        context.saveGState()
        let outside = CGMutablePath()
        outside.addRect(props.ringRect.union(props.loupeRect).insetBy(dx: -props.strokeWidth, dy: -props.strokeWidth))
        outside.addPath(ring); outside.addPath(loupe)
        context.addPath(outside); context.clip(using: .evenOdd)
        context.move(to: props.ring.cgPoint); context.addLine(to: props.loupe.cgPoint); context.strokePath()
        context.restoreGState()

        context.saveGState()
        context.addPath(loupe); context.clip()
        // Missing pixels, including a source being reloaded after crop/undo, fail closed.
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(props.loupeRect)
        if let source {
            let mapping = CGAffineTransform(translationX: props.loupe.x, y: props.loupe.y)
                .scaledBy(x: props.zoom, y: props.zoom).translatedBy(x: -props.ring.x, y: -props.ring.y)
            context.concatenate(mapping)
            context.concatenate(shape.pageTransform.inverse.cgAffineTransform)
            context.translateBy(x: 0, y: pageSize.height); context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            context.draw(source, in: CGRect(origin: .zero, size: pageSize))
        }
        context.restoreGState()
        context.addPath(ring); context.strokePath()
        context.addPath(loupe); context.strokePath()
    }

    private static func drawNumbered(_ props: NumberedProps, in context: CGContext) {
        let rect = CGRect(x: 0, y: 0, width: props.diameter, height: props.diameter)
        let outlineWidth = Swift.max(1, props.diameter * 0.055)

        context.setFillColor(props.swatch.nsColor.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(props.swatch.numberedCircleOutlineNSColor.cgColor)
        context.setLineWidth(outlineWidth)
        context.strokeEllipse(in: rect.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2))

        // The digits go through the same glyph-outline path text uses, so a rotated callout's
        // number rotates with it and needs no flipped graphics context.
        let text = String(props.value)
        var textProps = TextProps()
        textProps.text = text
        textProps.swatch = props.swatch
        textProps.fontSize = props.diameter * numberedFontScale(digits: text.count)
        textProps.fontFamily = .pro
        textProps.isBold = true
        textProps.align = .start

        let path = TextMeasure.glyphPath(textProps)
        let glyphBounds = path.boundingBoxOfPath
        var transform = CGAffineTransform(
            // Centre the visible outlines rather than their TextKit line box. The line box carries
            // asymmetric ascent/descent padding, which makes digits appear slightly low.
            translationX: props.diameter / 2 - glyphBounds.midX,
            y: props.diameter / 2 - glyphBounds.midY
        )
        guard let positioned = path.copy(using: &transform) else { return }
        context.addPath(positioned)
        context.setFillColor(props.swatch.numberedCircleTextNSColor.cgColor)
        context.fillPath(using: .winding)
    }

    private static func numberedFontScale(digits: Int) -> Double {
        if digits <= 2 { return 0.54 }
        if digits == 3 { return 0.44 }
        return 0.34
    }

    // MARK: - Spotlight

    private static func drawSpotlight(_ shapes: [AnnoShape], in context: CGContext, target: Target) {
        guard !shapes.isEmpty else { return }

        context.saveGState()
        if let clip = target.spotlightClip {
            context.addPath(clip)
            context.clip()
        } else {
            context.clip(to: target.pageRect.applying(target.transform))
        }

        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setBlendMode(.normal)
        context.setFillColor(
            NSColor.black.withAlphaComponent(AnnotationHighlightMetrics.overlayOpacity).cgColor
        )
        context.fill(target.pageRect.applying(target.transform))

        context.saveGState()
        context.setBlendMode(.clear)
        for shape in shapes {
            guard case let .highlight(props) = shape.kind else { continue }
            var transform = shape.pageTransform.cgAffineTransform.concatenating(target.transform)
            // Built with the transform baked in, so a rotated highlight punches a rotated hole.
            context.addPath(CGPath(
                rect: CGRect(x: 0, y: 0, width: props.w, height: props.h),
                transform: &transform
            ))
            context.fillPath()
        }
        context.restoreGState()

        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: - Redaction

    private static func drawRedaction(
        _ shape: AnnoShape,
        document: AnnoDocument,
        in context: CGContext,
        target: Target
    ) {
        guard case let .redaction(props) = shape.kind, let sample = target.sample else { return }

        // Sample the axis-aligned bounding box in context space, process it upright, then lay it
        // back down clipped to the shape's own rotated rect. A rotated blur then blurs the pixels
        // it actually covers rather than smearing along the screen axes.
        let localRect = CGRect(x: 0, y: 0, width: props.w, height: props.h)
        let full = shape.pageTransform.cgAffineTransform.concatenating(target.transform)
        let contextBounds = localRect.applying(full).integral
        guard contextBounds.width >= 1, contextBounds.height >= 1 else { return }

        let render = {
            guard let sampled = sample(contextBounds) else { return nil as CGImage? }
            return autoreleasepool {
                switch props.kind {
                case .blur: blurred(sampled, density: props.density, scale: target.sampleScale)
                case .pixelate: pixelated(sampled, density: props.density, scale: target.sampleScale)
                }
            }
        }
        let processed: CGImage?
        if let cache = target.redactionPreviewCache {
            processed = cache.image(kind: props.kind.rawValue, density: props.density, bounds: contextBounds, render: render)
        } else {
            processed = render()
        }
        context.saveGState()
        context.concatenate(full)
        context.clip(to: localRect)
        // Back to context space, where the sampled rect is axis-aligned.
        context.concatenate(full.inverted())
        // Fail closed: cover the screenshot under the redaction - inside its frame, as the
        // spotlight clips it - before laying the tile down. A tile that couldn't be sampled or
        // processed then leaves the cover, and one whose blocks averaged the screenshot with
        // transparent margin past its edge can't let the original show through. Off the
        // screenshot, and outside a rounded frame's corners, there is nothing to hide.
        context.saveGState()
        if let frame = target.spotlightClip {
            context.addPath(frame)
            context.clip()
        } else {
            context.clip(to: target.pageRect.applying(target.transform))
        }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(contextBounds)
        context.restoreGState()
        guard let processed else {
            context.restoreGState()
            return
        }
        context.interpolationQuality = props.kind == .pixelate ? .none : .high
        if target.isFlippedContext {
            context.translateBy(x: 0, y: contextBounds.midY)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -contextBounds.midY)
        }
        context.draw(processed, in: contextBounds)
        context.restoreGState()
    }

    private static func blurred(_ image: CGImage, density: Double, scale: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(RedactionImageProcessor.blurRadius(for: CGFloat(density)) * scale)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }

    private static func pixelated(_ image: CGImage, density: Double, scale: CGFloat) -> CGImage? {
        let block = Swift.max(1, RedactionImageProcessor.pixelBlockSize(for: CGFloat(density)) * scale)
        let lowWidth = Swift.max(1, Int(CGFloat(image.width) / block))
        let lowHeight = Swift.max(1, Int(CGFloat(image.height) / block))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let low = CGContext(
            data: nil,
            width: lowWidth,
            height: lowHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        low.interpolationQuality = .medium
        low.draw(image, in: CGRect(x: 0, y: 0, width: lowWidth, height: lowHeight))
        return low.makeImage()
    }
}
