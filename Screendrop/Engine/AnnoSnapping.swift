enum AnnoSnapAxis { case x, y }

/// An alignment coordinate and its extent along the other axis, in page space.
struct AnnoSnapAnchor {
    var axis: AnnoSnapAxis
    var position: Double
    var lower: Double
    var upper: Double
}

struct AnnoSnapGuide: Equatable {
    var start: Vec
    var end: Vec
}

struct AnnoSnapResult {
    var delta: Vec
    var guides: [AnnoSnapGuide]
}

enum AnnoSnapping {
    static func anchors(_ box: Box) -> [AnnoSnapAnchor] {
        [box.minX, box.midX, box.maxX].map {
            AnnoSnapAnchor(axis: .x, position: $0, lower: box.minY, upper: box.maxY)
        } + [box.minY, box.midY, box.maxY].map {
            AnnoSnapAnchor(axis: .y, position: $0, lower: box.minX, upper: box.maxX)
        }
    }

    static func anchors(_ point: Vec) -> [AnnoSnapAnchor] {
        [AnnoSnapAnchor(axis: .x, position: point.x, lower: point.y, upper: point.y),
         AnnoSnapAnchor(axis: .y, position: point.y, lower: point.x, upper: point.x)]
    }

    /// The caller converts the six-screen-point tolerance to page units before solving.
    static func snap(
        moving: [AnnoSnapAnchor], targets: [AnnoSnapAnchor], delta: Vec,
        tolerance: Double, bypass: Bool = false, direction: Vec? = nil
    ) -> AnnoSnapResult {
        guard !bypass, delta.isFinite, tolerance.isFinite, tolerance >= 0 else {
            return AnnoSnapResult(delta: delta, guides: [])
        }
        var result = delta
        var snappedAxes: [AnnoSnapAxis] = []
        let unit = direction?.uni
        var constrainedCorrection: Double?
        for axis in [AnnoSnapAxis.x, .y] {
            let movement = axis == .x ? delta.x : delta.y
            let component = unit.map { axis == .x ? $0.x : $0.y } ?? 1
            guard abs(component) > 0.0001 else { continue }
            var correction: Double?
            for source in moving where source.axis == axis {
                for target in targets where target.axis == axis {
                    let offset = (target.position - source.position - movement) / component
                    guard abs(offset) <= tolerance else { continue }
                    if correction == nil || abs(offset) < abs(correction!) {
                        correction = offset
                    }
                }
            }
            if let correction {
                if unit != nil {
                    if constrainedCorrection == nil || abs(correction) < abs(constrainedCorrection!) {
                        constrainedCorrection = correction
                    }
                } else {
                    if axis == .x { result.x += correction } else { result.y += correction }
                    snappedAxes.append(axis)
                }
            }
        }
        if let unit, let correction = constrainedCorrection {
            result = Vec.add(delta, Vec.mul(unit, correction))
            snappedAxes = [AnnoSnapAxis.x, .y].filter { abs($0 == .x ? unit.x : unit.y) > 0.0001 }
        }

        var guides: [AnnoSnapGuide] = []
        for axis in snappedAxes {
            let movement = axis == .x ? result.x : result.y
            let crossMovement = axis == .x ? result.y : result.x
            for source in moving where source.axis == axis {
                for target in targets where target.axis == axis {
                    guard abs(source.position + movement - target.position) < 0.0001 else { continue }
                    let lower = min(source.lower + crossMovement, target.lower)
                    let upper = max(source.upper + crossMovement, target.upper)
                    let guide = axis == .x
                        ? AnnoSnapGuide(start: Vec(target.position, lower), end: Vec(target.position, upper))
                        : AnnoSnapGuide(start: Vec(lower, target.position), end: Vec(upper, target.position))
                    if !guides.contains(guide) { guides.append(guide) }
                }
            }
        }
        return AnnoSnapResult(delta: result, guides: guides)
    }
}
