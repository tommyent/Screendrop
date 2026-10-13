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

/// Hand-drawn shapes drawn the way a marker draws them (sd-drv): one thick stroke that bows a
/// little, rounded where it turns, and overlapping where a loop closes. Every wobble is seeded
/// by the shape's ID, so a shape looks the same on every redraw and in the export, and nothing
/// is seeded by size, so dragging scales the wobble smoothly instead of reshuffling it.
enum MarkerPaths {
    /// A straight run bowed to one side by a few per cent of its length, capped by the stroke so
    /// a long thin line doesn't sag. `startBack` and `endBack` point from each end back along the
    /// curve, for arrowheads that follow it.
    static func bowedLine(from start: Vec, to end: Vec, strokeWidth: Double, seed: String)
        -> (path: CGPath, startBack: Vec, endBack: Vec) {
        let random = makeRng(seed + "bow")
        let r = random()
        let bow = (r < 0 ? -1.0 : 1.0) * (0.6 + 0.4 * abs(r))
            * Swift.min(Vec.dist(start, end) * 0.025, strokeWidth * 3)
        let control = bowControl(from: start, to: end, bow: bow)
        let path = CGMutablePath()
        path.move(to: start.cgPoint)
        addQuadratic(to: path, from: start, control: control, to: end)
        return (path, Vec.sub(control, start).uni, Vec.sub(control, end).uni)
    }

    /// An open arrowhead of two strokes meeting at the tip, `length` long along `back`.
    static func openHead(tip: Vec, back: Vec, length: Double) -> CGPath {
        let base = Vec.add(tip, Vec.mul(back, length))
        let path = CGMutablePath()
        path.move(to: Vec.rotWith(base, tip, PI / 6).cgPoint)
        path.addLine(to: tip.cgPoint)
        path.addLine(to: Vec.rotWith(base, tip, -PI / 6).cgPoint)
        return path
    }

    /// A rectangle in one stroke: corners placed a touch off, sides bowing, corners rounded (at
    /// least by the shape's own radius), and the end running a little past the start.
    static func rectangle(_ props: GeoProps, seed: String) -> CGPath {
        let w = Swift.max(1, props.w), h = Swift.max(1, props.h), sw = props.strokeWidth
        let short = Swift.min(w, h)
        let random = makeRng(seed + "rect")
        let jitter = Swift.min(sw * 0.6, short * 0.03)
        let corners = [Vec(0, 0), Vec(w, 0), Vec(w, h), Vec(0, h)]
            .map { Vec($0.x + random() * jitter, $0.y + random() * jitter) }
        let round = Swift.max(Swift.min(props.cornerRadius, short / 2), Swift.min(sw * 0.8, short / 6))

        func direction(_ i: Int) -> Vec { Vec.sub(corners[(i + 1) % 4], corners[i]).uni }
        let first = Vec.add(corners[0], Vec.mul(direction(0), round))
        let path = CGMutablePath()
        path.move(to: first.cgPoint)
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4], dir = direction(i)
            let sideStart = Vec.add(a, Vec.mul(dir, round)), sideEnd = Vec.sub(b, Vec.mul(dir, round))
            let bow = random() * Swift.min(Vec.dist(a, b) * 0.03, sw * 1.5)
            addQuadratic(to: path, from: sideStart, control: bowControl(from: sideStart, to: sideEnd, bow: bow), to: sideEnd)
            // Round through the true corner into the next side.
            path.addQuadCurve(to: Vec.add(b, Vec.mul(direction((i + 1) % 4), round)).cgPoint, control: b.cgPoint)
        }
        // A marker closing a box runs on past where it started, drifting a little outside the
        // line (`per` of the top side points up, out of the box), never into it.
        let overlap = Swift.min(sw * 3, w * 0.12)
        let drift = (0.5 + 0.5 * abs(random())) * Swift.min(sw * 0.7, short * 0.03)
        path.addLine(to: Vec.add(Vec.add(first, Vec.mul(direction(0), overlap)), Vec.mul(direction(0).per, drift)).cgPoint)
        return path
    }

    /// An ellipse in one stroke: its radius wavers slowly, and the loop runs past its start on a
    /// slightly wider or narrower line, so the ends overlap without meeting.
    static func ellipse(_ props: GeoProps, seed: String) -> CGPath {
        let w = Swift.max(1, props.w), h = Swift.max(1, props.h), sw = props.strokeWidth
        let rx = w / 2, ry = h / 2, minRadius = Swift.min(rx, ry)
        let random = makeRng(seed + "ellipse")
        let amplitude = Swift.min(sw * 0.9, minRadius * 0.06)
        let phase1 = random() * PI, phase2 = random() * PI
        let start = -PI / 4 + random() * 0.3
        let sweep = PI2 + 0.35
        let spiral = (random() < 0 ? -1.0 : 1.0) * Swift.min(sw * 1.2, minRadius * 0.08)
        let path = CGMutablePath()
        let samples = 96
        for step in 0...samples {
            let t = Double(step) / Double(samples)
            let angle = start + sweep * t
            let wave = 0.6 * sin(2 * angle + phase1) + 0.4 * sin(3 * angle + phase2)
            let k = amplitude * wave + spiral * (t - 0.5)
            let point = CGPoint(x: rx + (rx + k) * cos(angle), y: ry + (ry + k) * sin(angle))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// The control point of a quadratic that bows `bow` off the line from `start` to `end` at its
    /// middle: a quadratic peaks at half its control's offset.
    private static func bowControl(from start: Vec, to end: Vec, bow: Double) -> Vec {
        let normal = Vec.sub(end, start).uni.per
        return Vec.add(Vec.med(start, end), Vec.mul(normal, bow * 2))
    }

    private static func addQuadratic(to path: CGMutablePath, from start: Vec, control: Vec, to end: Vec) {
        path.addCurve(to: end.cgPoint,
                      control1: Vec.lrp(start, control, 2 / 3).cgPoint,
                      control2: Vec.lrp(end, control, 2 / 3).cgPoint)
    }
}
