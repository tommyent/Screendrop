import CoreGraphics
import Foundation

/// The path for each geo shape, ported from the drawing-app's `Paths/GeoPaths.swift`.
///
/// Screendrop only draws rectangles and ellipses, so the polygon/star/cloud family is left behind;
/// what matters is that the path is built once here and used for stroking, filling and flattening
/// to hit-test vertices, so those three can never disagree about where an edge is.
enum GeoPaths {
    static func path(for props: GeoProps) -> PathBuilder {
        let w = Swift.max(1, props.w)
        let h = Swift.max(1, props.h)

        switch props.geo {
        case .rectangle:
            let radius = Swift.min(props.cornerRadius, Swift.min(w, h) / 2)
            guard radius > 0.5 else {
                return PathBuilder()
                    .move(to: Vec(0, 0))
                    .line(to: Vec(w, 0))
                    .line(to: Vec(w, h))
                    .line(to: Vec(0, h))
                    .close()
            }
            let path = PathBuilder().move(to: Vec(radius, 0))
            path.line(to: Vec(w - radius, 0))
            path.circularArc(radius: radius, largeArc: false, sweep: true, to: Vec(w, radius))
            path.line(to: Vec(w, h - radius))
            path.circularArc(radius: radius, largeArc: false, sweep: true, to: Vec(w - radius, h))
            path.line(to: Vec(radius, h))
            path.circularArc(radius: radius, largeArc: false, sweep: true, to: Vec(0, h - radius))
            path.line(to: Vec(0, radius))
            path.circularArc(radius: radius, largeArc: false, sweep: true, to: Vec(radius, 0))
            return path.close()

        case .ellipse:
            // Two half-turns, which PathBuilder turns into cubics so the flattened vertices and the
            // drawn curve describe the same ellipse.
            let cx = w / 2, cy = h / 2
            let path = PathBuilder().move(to: Vec(0, cy))
            path.arc(rx: cx, ry: cy, largeArc: false, sweep: true, xAxisRotation: 0, to: Vec(w, cy))
            path.arc(rx: cx, ry: cy, largeArc: false, sweep: true, xAxisRotation: 0, to: Vec(0, cy))
            return path.close()
        }
    }

    /// A plain box path, for the shapes whose outline is always a rectangle (redactions, the
    /// spotlight highlight, a text box's frame).
    static func box(width: Double, height: Double) -> PathBuilder {
        PathBuilder()
            .move(to: Vec(0, 0))
            .line(to: Vec(width, 0))
            .line(to: Vec(width, height))
            .line(to: Vec(0, height))
            .close()
    }

    /// Leave the two jittered ends apart, with a short tail, as in a sketched oval.
    static func handDrawnEllipse(_ props: GeoProps) -> PathBuilder {
        let w = Swift.max(1, props.w), h = Swift.max(1, props.h)
        let start = -PI / 4, end = start + PI2 - 0.28
        let arc = CGMutablePath()
        arc.addArc(center: .zero, radius: 1, startAngle: start, endAngle: end, clockwise: false)
        var transform = CGAffineTransform(translationX: w / 2, y: h / 2).scaledBy(x: w / 2, y: h / 2)
        guard let ellipse = arc.copy(using: &transform) else { return path(for: props) }
        let result = PathBuilder(cgPath: ellipse)
        let tail = Swift.min(props.strokeWidth, Swift.min(w, h) * 0.02)
        return result.line(to: Vec(w / 2 + (w / 2 + tail) * cos(end), h / 2 + (h / 2 + tail) * sin(end)))
    }
}
