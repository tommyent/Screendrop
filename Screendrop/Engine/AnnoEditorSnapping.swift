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
        }
        return anchors
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
}
