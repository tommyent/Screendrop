import CoreGraphics
import Foundation

/// Builds a path once and renders it solid or dashed. Hand-drawn shapes draw `MarkerPaths`
/// instead (sd-drv).
///
/// Ported from `packages/old-apps/src/lib/shapes/shared/PathBuilder.tsx`, keeping the parts that
/// matter for geo shapes and arrows (move / line / cubic / arc).
final class PathBuilder {
    enum Kind {
        case move
        case line
        case cubic(cp1: Vec, cp2: Vec)
    }

    struct Command {
        var kind: Kind
        var point: Vec
        var isClose: Bool = false
    }

    private(set) var commands: [Command] = []
    private var lastMoveToIdx: Int?

    init() {}

    /// Keep hit geometry on the same native squircle path as the renderer.
    init(cgPath: CGPath) {
        cgPath.applyWithBlock { element in
            let e = element.pointee
            func point(_ index: Int) -> Vec { Vec(e.points[index].x, e.points[index].y) }
            switch e.type {
            case .moveToPoint: self.move(to: point(0))
            case .addLineToPoint: self.line(to: point(0))
            case .addCurveToPoint: self.cubic(to: point(2), cp1: point(0), cp2: point(1))
            case .addQuadCurveToPoint:
                guard let start = self.commands.last?.point else { return }
                let control = point(0), end = point(1)
                self.cubic(to: end, cp1: Vec.lrp(start, control, 2 / 3), cp2: Vec.lrp(end, control, 2 / 3))
            case .closeSubpath: self.close()
            @unknown default: break
            }
        }
    }

    @discardableResult
    func move(to p: Vec) -> PathBuilder {
        commands.append(Command(kind: .move, point: p))
        lastMoveToIdx = commands.count - 1
        return self
    }

    @discardableResult
    func line(to p: Vec) -> PathBuilder {
        commands.append(Command(kind: .line, point: p))
        return self
    }

    @discardableResult
    func cubic(to p: Vec, cp1: Vec, cp2: Vec) -> PathBuilder {
        commands.append(Command(kind: .cubic(cp1: cp1, cp2: cp2), point: p))
        return self
    }

    @discardableResult
    func close() -> PathBuilder {
        guard let moveIdx = lastMoveToIdx, let last = commands.last else { return self }
        let movePoint = commands[moveIdx].point
        if approximately(movePoint.x, last.point.x) && approximately(movePoint.y, last.point.y) {
            commands[commands.count - 1].isClose = true
        } else {
            commands.append(Command(kind: .line, point: movePoint, isClose: true))
        }
        return self
    }

    @discardableResult
    func circularArc(radius: Double, largeArc: Bool, sweep: Bool, to p: Vec) -> PathBuilder {
        arc(rx: radius, ry: radius, largeArc: largeArc, sweep: sweep, xAxisRotation: 0, to: p)
    }

    /// Approximate an SVG elliptical arc with up to four cubic segments, one per quadrant.
    @discardableResult
    func arc(rx: Double, ry: Double, largeArc: Bool, sweep: Bool, xAxisRotation: Double, to p2: Vec) -> PathBuilder {
        guard let last = commands.last else { return self }
        let p1 = last.point
        if p1.x == p2.x && p1.y == p2.y { return self }
        if rx == 0 || ry == 0 { return line(to: p2) }

        let phi = xAxisRotation
        let sinPhi = sin(phi)
        let cosPhi = cos(phi)
        var rx1 = abs(rx)
        var ry1 = abs(ry)

        let dx = (p1.x - p2.x) / 2
        let dy = (p1.y - p2.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx1 * rx1) + (y1p * y1p) / (ry1 * ry1)
        if lambda > 1 {
            let sqrtLambda = lambda.squareRoot()
            rx1 *= sqrtLambda
            ry1 *= sqrtLambda
        }

        let sign: Double = largeArc != sweep ? 1 : -1
        let term = rx1 * rx1 * ry1 * ry1 - rx1 * rx1 * y1p * y1p - ry1 * ry1 * x1p * x1p
        let numerator = rx1 * rx1 * y1p * y1p + ry1 * ry1 * x1p * x1p
        var radicand = numerator == 0 ? 0 : term / numerator
        if radicand < 0 { radicand = 0 }
        let coef = sign * radicand.squareRoot()

        let cxp = coef * ((rx1 * y1p) / ry1)
        let cyp = coef * (-(ry1 * x1p) / rx1)
        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2

        let ux = (x1p - cxp) / rx1
        let uy = (y1p - cyp) / ry1
        let vx = (-x1p - cxp) / rx1
        let vy = (-y1p - cyp) / ry1

        let startAngle = atan2(uy, ux)
        var endAngle = atan2(vy, vx)
        if !sweep && endAngle > startAngle {
            endAngle -= PI2
        } else if sweep && endAngle < startAngle {
            endAngle += PI2
        }
        let sweepAngle = endAngle - startAngle

        func ellipsePoint(_ angle: Double) -> Vec {
            Vec(
                cx + rx1 * cos(angle) * cosPhi - ry1 * sin(angle) * sinPhi,
                cy + rx1 * cos(angle) * sinPhi + ry1 * sin(angle) * cosPhi
            )
        }
        func ellipseDerivative(_ angle: Double) -> Vec {
            Vec(
                -rx1 * sin(angle) * cosPhi - ry1 * cos(angle) * sinPhi,
                -rx1 * sin(angle) * sinPhi + ry1 * cos(angle) * cosPhi
            )
        }

        let numSegments = Swift.max(1, Swift.min(4, Int(ceil(abs(sweepAngle) / HALF_PI))))
        let anglePerSegment = sweepAngle / Double(numSegments)

        for i in 0..<numSegments {
            let theta1 = startAngle + Double(i) * anglePerSegment
            let theta2 = startAngle + Double(i + 1) * anglePerSegment
            let start = ellipsePoint(theta1)
            let end = ellipsePoint(theta2)
            let d1 = ellipseDerivative(theta1)
            let d2 = ellipseDerivative(theta2)
            // For a 90° arc the handle length is 4/3 * tan(π/8) * r; smaller arcs scale by angle.
            let handleScale = (4.0 / 3.0) * tan((theta2 - theta1) / 4)
            let cp1 = Vec(start.x + handleScale * d1.x, start.y + handleScale * d1.y)
            let cp2 = Vec(end.x - handleScale * d2.x, end.y - handleScale * d2.y)
            cubic(to: end, cp1: cp1, cp2: cp2)
        }
        return self
    }

    // MARK: - Length

    private static func cubicLength(_ p0: Vec, _ p1: Vec, _ p2: Vec, _ p3: Vec, samples: Int = 16) -> Double {
        var length = 0.0
        var prev = p0
        for i in 1...samples {
            let t = Double(i) / Double(samples)
            let mt = 1 - t
            let a = mt * mt * mt
            let b = 3 * mt * mt * t
            let c = 3 * mt * t * t
            let d = t * t * t
            let point = Vec(
                a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                a * p0.y + b * p1.y + c * p2.y + d * p3.y
            )
            length += Vec.dist(prev, point)
            prev = point
        }
        return length
    }

    // MARK: - Rendering

    /// The path exactly as built.
    func solidPath() -> CGPath {
        let path = CGMutablePath()
        for command in commands {
            switch command.kind {
            case .move:
                path.move(to: command.point.cgPoint)
            case .line:
                path.addLine(to: command.point.cgPoint)
            case let .cubic(cp1, cp2):
                path.addCurve(to: command.point.cgPoint, control1: cp1.cgPoint, control2: cp2.cgPoint)
            }
            if command.isClose { path.closeSubpath() }
        }
        return path
    }

    /// The path flattened to a point list, with curves sampled. This is what the geo shapes use as
    /// their geometry, so hit-testing follows whatever the path actually draws.
    func vertices(curveResolution: Int = 12) -> [Vec] {
        var points: [Vec] = []
        var current = Vec(0, 0)
        for command in commands {
            switch command.kind {
            case .move:
                points.append(command.point)
            case .line:
                points.append(command.point)
            case let .cubic(cp1, cp2):
                for i in 1...curveResolution {
                    let t = Double(i) / Double(curveResolution)
                    let mt = 1 - t
                    let a = mt * mt * mt
                    let b = 3 * mt * mt * t
                    let c = 3 * mt * t * t
                    let d = t * t * t
                    points.append(Vec(
                        a * current.x + b * cp1.x + c * cp2.x + d * command.point.x,
                        a * current.y + b * cp1.y + c * cp2.y + d * command.point.y
                    ))
                }
            }
            current = command.point
        }
        return points
    }

    /// One subpath per segment, each with its own dash pattern.
    ///
    /// old-apps dashes every segment separately rather than dashing the path as a whole, which is
    /// what makes dashes meet cleanly at a rectangle's corners instead of wrapping around them.
    struct DashedSegment {
        var path: CGPath
        var dashes: [CGFloat]
        var phase: CGFloat
    }

    func dashedSegments(strokeWidth: Double, style: DashStyle) -> [DashedSegment] {
        var segments: [DashedSegment] = []
        var current: Vec?

        for command in commands {
            defer { current = command.point }
            guard let from = current else { continue }
            if case .move = command.kind { continue }

            let path = CGMutablePath()
            path.move(to: from.cgPoint)
            let length: Double
            switch command.kind {
            case .move:
                continue
            case .line:
                path.addLine(to: command.point.cgPoint)
                length = Vec.dist(from, command.point)
            case let .cubic(cp1, cp2):
                path.addCurve(to: command.point.cgPoint, control1: cp1.cgPoint, control2: cp2.cgPoint)
                length = Self.cubicLength(from, cp1, cp2, command.point)
            }

            guard length > 0 else { continue }
            let props = perfectDashProps(totalLength: length, strokeWidth: strokeWidth, style: style)
            segments.append(DashedSegment(path: path, dashes: props.dashes, phase: props.phase))
        }
        return segments
    }

}
