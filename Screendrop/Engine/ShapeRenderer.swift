import AppKit
import CoreGraphics
import Foundation

/// A single drawable piece of a shape, in the shape's own local space.
///
/// Everything the canvas and the exporter draw comes through this list, which `AnnoDocument` caches
/// per shape. Rebuilding it per frame meant panning re-ran the whole freehand pipeline for strokes
/// whose pixels hadn't moved.
///
/// Screendrop's non-vector tools ride the same list: a redaction, a spotlight hole and a numbered
/// callout are `Content` cases rather than paths, so one draw loop covers every tool and they all
/// inherit the same transform, z-order and caching.
struct RenderElement {
    enum Content {
        /// A vector path: filled, stroked, or both.
        case path(CGPath)
        /// A rectangle of the underlying screenshot, blurred or pixelated in place.
        case redaction(RedactionProps)
        /// A hole punched in the spotlight dimming layer.
        case spotlight(CGSize)
        /// A numbered callout: filled disc, outline, and centred digits.
        case numbered(NumberedProps)
        case magnifier(MagnifierProps)
        /// A pasted picture, drawn into its box from the target's images.
        case image(ImageProps)
        /// Glyph outlines, already positioned in the shape's local space.
        case glyphs(CGPath)
    }

    var content: Content
    var fill: NSColor?
    var stroke: NSColor?
    var strokeWidth: Double = 1
    /// Fill rule for self-overlapping ink outlines and glyph counters.
    var usesEvenOddFill = false
    /// Dash pattern and phase for the stroke, empty for a solid line.
    var dashes: [CGFloat] = []
    var dashPhase: CGFloat = 0

    /// Whether this element transforms the screenshot underneath it rather than painting over it.
    /// Those are drawn in a first pass, below the spotlight.
    var isRedaction: Bool {
        if case .redaction = content { return true }
        return false
    }
}

/// Turns shapes into render elements, in the shape's own local space.
enum AnnoShapeRenderer {
    static func elements(for shape: AnnoShape, in document: AnnoDocument) -> [RenderElement] {
        switch shape.kind {
        case let .geo(props):
            geoElements(props, seed: shape.id.raw)
        case let .draw(props):
            drawElements(props)
        case .arrow:
            arrowElements(shape, in: document)
        case let .text(props):
            textElements(props)
        case let .redaction(props):
            [RenderElement(content: .redaction(props))]
        case let .highlight(props):
            [RenderElement(content: .spotlight(CGSize(width: props.w, height: props.h)))]
        case let .numbered(props):
            [RenderElement(content: .numbered(props))]
        case let .magnifier(props):
            props.isValid ? [RenderElement(content: .magnifier(props))] : []
        case let .image(props):
            [RenderElement(content: .image(props))]
        }
    }

    // MARK: - Text

    private static func textElements(_ props: TextProps) -> [RenderElement] {
        guard !props.text.isEmpty else { return [] }
        var elements: [RenderElement] = []
        if props.hasBox {
            let radius = TextMeasure.boxCornerRadius(props)
            elements.append(RenderElement(
                content: .path(CGPath(
                    roundedRect: TextMeasure.outerRect(props),
                    cornerWidth: radius,
                    cornerHeight: radius,
                    transform: nil
                )),
                fill: props.swatch.nsColor,
                stroke: nil
            ))
        }
        elements.append(RenderElement(
            content: .glyphs(TextMeasure.glyphPath(props)),
            fill: TextMeasure.ink(props).nsColor,
            stroke: nil,
            // Non-zero, not even-odd. OpenType contours are wound so that counters (the hole in an
            // "o") come out hollow under non-zero anyway, and even-odd additionally punches a hole
            // wherever two glyphs overlap - which at bold weights is most of a sentence.
            usesEvenOddFill: false
        ))
        return elements
    }

    // MARK: - Draw

    private static func drawElements(_ props: DrawProps) -> [RenderElement] {
        guard !props.points.isEmpty else { return [] }

        let options = FreehandSettings.forDrawShape(
            isPen: props.isPen && props.isHighlighter != true,
            isComplete: props.isComplete,
            strokeWidth: props.strokeWidth,
            forceComplete: false,
            forceSolid: props.isHighlighter == true
        )
        let ink = SvgInk.render(props.points, options)
        return [RenderElement(
            content: .path(ink.path),
            fill: props.swatch.nsColor,
            stroke: nil,
            // The outline can double back on itself at tight corners; non-zero winding keeps those
            // overlaps solid instead of punching holes in the stroke.
            usesEvenOddFill: false
        )]
    }

    // MARK: - Geo

    private static func geoElements(_ props: GeoProps, seed: String) -> [RenderElement] {
        let path = GeoPaths.path(for: props)
        var elements: [RenderElement] = []
        if props.fill != .none {
            elements.append(RenderElement(
                content: .path(path.solidPath()),
                fill: props.swatch.nsColor,
                stroke: nil
            ))
            if props.dash != .draw { return elements }
        }
        if props.dash == .draw {
            elements.append(RenderElement(
                content: .path(props.geo == .ellipse
                    ? MarkerPaths.ellipse(props, seed: seed)
                    : MarkerPaths.rectangle(props, seed: seed)),
                fill: nil,
                stroke: props.swatch.nsColor,
                strokeWidth: props.strokeWidth
            ))
        } else {
            elements.append(strokeElement(
                path: path,
                dash: props.dash,
                strokeWidth: props.strokeWidth,
                color: props.swatch.nsColor
            ))
        }
        return elements
    }

    /// Stroke a path in whichever dash style is asked for. Hand-drawn (`.draw`) shapes take their
    /// own marker paths (`MarkerPaths`) before they get here.
    private static func strokeElement(
        path: PathBuilder,
        dash: DashStyle,
        strokeWidth: Double,
        color: NSColor
    ) -> RenderElement {
        switch dash {
        case .solid, .draw:
            return RenderElement(
                content: .path(path.solidPath()),
                fill: nil,
                stroke: color,
                strokeWidth: strokeWidth
            )
        case .dashed, .dotted:
            // Each segment carries its own pattern, so dashes meet cleanly at a rectangle's corners
            // instead of wrapping around them.
            let segments = path.dashedSegments(strokeWidth: strokeWidth, style: dash)
            let combined = CGMutablePath()
            for segment in segments { combined.addPath(segment.path) }
            let first = segments.first
            return RenderElement(
                content: .path(combined),
                fill: nil,
                stroke: color,
                strokeWidth: strokeWidth,
                dashes: first?.dashes ?? [],
                dashPhase: first?.phase ?? 0
            )
        }
    }

    // MARK: - Arrow

    private static func headElements(_ props: ArrowProps, info: ArrowInfo,
                                     sides: [ArrowTerminal] = [.start, .end]) -> [RenderElement] {
        sides.compactMap { side in
            guard let head = Arrowheads.path(info, side, props.strokeWidth) else { return nil }
            return RenderElement(
                content: .path(head.path.solidPath()),
                fill: head.isFilled ? props.swatch.nsColor : nil,
                stroke: props.swatch.nsColor,
                strokeWidth: props.strokeWidth
            )
        }
    }

    /// A hand-drawn arrow as a marker draws it (sd-drv): one stroke with a gentle seeded bow, and
    /// open two-stroke heads, a touch larger, that follow the bow at the tip. A bent arrow keeps
    /// its arc. Heads other than the arrow and the triangle stay as they are.
    private static func markerArrowElements(_ props: ArrowProps, info: ArrowInfo, seed: String) -> [RenderElement] {
        let sw = props.strokeWidth, color = props.swatch.nsColor
        let body: CGPath
        var back: [ArrowTerminal: Vec] = [:]
        switch info.body {
        case let .straight(start, end):
            let marker = MarkerPaths.bowedLine(from: start, to: end, strokeWidth: sw, seed: seed)
            body = marker.path
            back = [.start: marker.startBack, .end: marker.endBack]
        case .arc:
            body = ArrowPath.body(info).solidPath()
            for side in [ArrowTerminal.start, .end] {
                let points = Arrowheads.arrowPoints(info, side, sw)
                back[side] = Vec.sub(points.int, points.point).uni
            }
        }
        var elements = [RenderElement(content: .path(body), fill: nil, stroke: color, strokeWidth: sw)]
        let length = clamp(Vec.dist(info.start.point, info.end.point) / 4, sw * 2, sw * 4.5)
        for side in [ArrowTerminal.start, .end] {
            let type = side == .end ? info.end.arrowhead : info.start.arrowhead
            switch type {
            case .none:
                continue
            case .arrow, .triangle:
                let tip = side == .end ? info.end.point : info.start.point
                guard let direction = back[side], !direction.isNaN else { continue }
                elements.append(RenderElement(content: .path(MarkerPaths.openHead(tip: tip, back: direction, length: length)),
                                              fill: nil, stroke: color, strokeWidth: sw))
            default:
                elements += headElements(props, info: info, sides: [side])
            }
        }
        return elements
    }

    private static func arrowElements(_ shape: AnnoShape, in document: AnnoDocument) -> [RenderElement] {
        guard let props = shape.arrowProps,
              let info = document.arrowInfo(shape.id),
              info.isValid else { return [] }

        var elements = props.dash == .draw
            ? markerArrowElements(props, info: info, seed: shape.id.raw)
            : [strokeElement(path: ArrowPath.body(info), dash: props.dash,
                             strokeWidth: props.strokeWidth, color: props.swatch.nsColor)]
                + headElements(props, info: info)

        if let label = ArrowLabel.layout(props, midpoint: info.middle, rotation: shape.rotation) {
            var transform = label.transform.cgAffineTransform
            for var element in textElements(label.text) {
                switch element.content {
                case let .path(path):
                    guard let positioned = path.copy(using: &transform) else { continue }
                    element.content = .path(positioned)
                case let .glyphs(path):
                    guard let positioned = path.copy(using: &transform) else { continue }
                    element.content = .glyphs(positioned)
                default: continue
                }
                elements.append(element)
            }
        }

        return elements
    }
}
