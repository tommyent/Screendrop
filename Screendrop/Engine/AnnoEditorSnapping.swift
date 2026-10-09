import CoreGraphics
import Foundation

extension AnnoEditor {
    func snapAnchors(for shapes: [AnnoShape]) -> [AnnoSnapAnchor] {
        let boxes = shapes.compactMap { document.pageBounds($0.id) }
        var anchors = boxes.isEmpty ? [] : AnnoSnapping.anchors(Box.common(boxes))
        for shape in shapes {
            if let arrow = document.arrowInfo(shape.id) {
                anchors += AnnoSnapping.anchors(shape.pageTransform.applyToPoint(arrow.start.point))
                anchors += AnnoSnapping.anchors(shape.pageTransform.applyToPoint(arrow.end.point))
            }
            if case let .magnifier(props) = shape.kind {
                anchors += snapAnchors(for: shape, rect: props.ringRect)
                anchors += snapAnchors(for: shape, rect: props.loupeRect)
            }
        }
        return anchors
    }

    func snapAnchors(for shape: AnnoShape, rect: CGRect) -> [AnnoSnapAnchor] {
        let box = Box(Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height))
        return AnnoSnapping.anchors(Box.fromPoints(shape.pageTransform.applyToPoints(box.corners)))
    }

    func snapMovement(
        moving: [AnnoSnapAnchor], excluding ids: Set<AnnoShapeID>, delta: Vec,
        pointer: PointerInfo, direction: Vec? = nil
    ) -> AnnoSnapResult {
        var targets = AnnoSnapping.anchors(Box(0, 0, Double(viewport.imageSize.width), Double(viewport.imageSize.height)))
        // An arrow attached to the moving selection moves too; it cannot be an alignment target.
        let attached = Set(document.bindings.filter { ids.contains($0.toId) }.map(\.arrowId))
        for shape in document.shapes where !ids.contains(shape.id) && !attached.contains(shape.id) {
            targets += snapAnchors(for: [shape])
        }
        return AnnoSnapping.snap(moving: moving, targets: targets, delta: delta,
                                 tolerance: pageDistance(forScreen: 6), bypass: pointer.command, direction: direction)
    }

    func snapPoint(_ point: Vec, excluding ids: Set<AnnoShapeID>, pointer: PointerInfo, direction: Vec? = nil) -> Vec {
        let result = snapMovement(moving: AnnoSnapping.anchors(point), excluding: ids, delta: .zero,
                                  pointer: pointer, direction: direction)
        setSnapGuides(result.guides)
        return Vec.add(point, result.delta)
    }

    /// Binding and minimum-size constraints can move a shape after snapping; show only actual alignments.
    func retainSnapGuides(alignedWith anchors: [AnnoSnapAnchor]) {
        setSnapGuides(snapGuides.filter { guide in
            if guide.start == guide.end {
                return anchors.contains { $0.axis == .x && abs($0.position - guide.start.x) < 0.0001 }
                    && anchors.contains { $0.axis == .y && abs($0.position - guide.start.y) < 0.0001 }
            }
            let axis: AnnoSnapAxis = guide.start.x == guide.end.x ? .x : .y
            let position = axis == .x ? guide.start.x : guide.start.y
            return anchors.contains { $0.axis == axis && abs($0.position - position) < 0.0001 }
        })
    }
}
