import Foundation

extension AnnoEditor {
    func beginMagnifier(_ pointer: PointerInfo) {
        markUndo()
        var props = MagnifierProps()
        props.ringSize = Swift.max(24, Double(Swift.max(viewport.imageSize.width, viewport.imageSize.height)) * 0.06)
        props.loupeSize = props.ringSize * currentMagnifierZoom
        props.loupe = Vec((props.ringSize + props.loupeSize) / 2 + props.ringSize * 0.5, 0)
        props.swatch = currentSwatch
        props.strokeWidth = pageStrokeWidth(currentStrokeWidth)
        let shape = AnnoShape(x: pointer.pagePoint.x, y: pointer.pagePoint.y, kind: .magnifier(props))
        document.add(shape)
        setInteraction(.creatingMagnifier(id: shape.id, origin: pointer.pagePoint))
    }

    func updateMagnifierCreation(id: AnnoShapeID, origin: Vec, pointer: PointerInfo) {
        let dx = pointer.pagePoint.x - origin.x, dy = pointer.pagePoint.y - origin.y
        guard abs(dx) + abs(dy) > 2 else { return }
        document.update(id) { shape in
            guard case var .magnifier(props) = shape.kind else { return }
            props.ringSize = Swift.max(8, Swift.max(abs(dx), abs(dy)))
            props.ring = Vec(dx / 2, dy / 2)
            props.loupeSize = props.ringSize * currentMagnifierZoom
            props.loupe = Vec(props.ring.x + (props.ringSize + props.loupeSize) / 2 + props.ringSize * 0.5, props.ring.y)
            shape.kind = .magnifier(props)
        }
        guard let shape = document.shape(id), case let .magnifier(props) = shape.kind else { return }
        let result = snapMovement(moving: snapAnchors(for: shape, rect: props.ringRect), excluding: [id],
                                  delta: .zero, pointer: pointer)
        let local = Vec.rot(result.delta, -shape.rotation)
        document.update(id) { shape in
            guard case var .magnifier(props) = shape.kind else { return }
            props.ring = Vec.add(props.ring, local)
            props.loupe = Vec.add(props.loupe, local)
            shape.kind = .magnifier(props)
        }
        setSnapGuides(result.guides)
    }

    func beginMagnifierDrag(_ shape: AnnoShape, handle: AnnoSelectionHandle, pointer: PointerInfo) {
        guard case let .magnifier(props) = shape.kind else { return }
        markUndo()
        setInteraction(.draggingMagnifier(id: shape.id, handle: handle,
            origin: document.pointInShapeSpace(shape, pointer.pagePoint), initial: props))
    }

    func dragMagnifier(id: AnnoShapeID, handle: AnnoSelectionHandle, origin: Vec,
        initial: MagnifierProps, pointer: PointerInfo) {
        guard let shape = document.shape(id) else { return }
        let local = document.pointInShapeSpace(shape, pointer.pagePoint)
        var props = initial
        switch handle {
        case .magnifierRing, .magnifierLoupe:
            let rect = handle == .magnifierRing ? initial.ringRect : initial.loupeRect
            let delta = Vec.rot(Vec.sub(local, origin), shape.rotation)
            let result = snapMovement(moving: snapAnchors(for: shape, rect: rect), excluding: [id],
                                      delta: delta, pointer: pointer)
            let snapped = Vec.rot(result.delta, -shape.rotation)
            if handle == .magnifierRing { props.ring = Vec.add(initial.ring, snapped) }
            else { props.loupe = Vec.add(initial.loupe, snapped) }
            setSnapGuides(result.guides)
        case .magnifierRingResize, .magnifierLoupeResize:
            let center = handle == .magnifierRingResize ? props.ring : props.loupe
            let size = Swift.max(8, 2 * Swift.max(abs(local.x - center.x), abs(local.y - center.y)))
            let direction = Vec(local.x < center.x ? -1 : 1, local.y < center.y ? -1 : 1)
            let corner = Vec.add(center, Vec.mul(direction, size / 2))
            let point = snapPoint(shape.pageTransform.applyToPoint(corner), excluding: [id],
                                  pointer: pointer, direction: Vec.rot(direction, shape.rotation))
            let snapped = document.pointInShapeSpace(shape, point)
            let snappedSize = Swift.max(8, 2 * Swift.max(abs(snapped.x - center.x), abs(snapped.y - center.y)))
            if handle == .magnifierRingResize { props.ringSize = snappedSize }
            else { props.loupeSize = snappedSize }
        default: return
        }
        guard props.isValid else { return }
        document.update(id) { $0.kind = .magnifier(props) }
        let rect = handle == .magnifierRing || handle == .magnifierRingResize ? props.ringRect : props.loupeRect
        var anchors = snapAnchors(for: shape, rect: rect)
        if handle == .magnifierRingResize || handle == .magnifierLoupeResize {
            let center = handle == .magnifierRingResize ? props.ring : props.loupe
            let size = handle == .magnifierRingResize ? props.ringSize : props.loupeSize
            let corner = Vec(center.x + (local.x < center.x ? -size : size) / 2,
                             center.y + (local.y < center.y ? -size : size) / 2)
            anchors += AnnoSnapping.anchors(shape.pageTransform.applyToPoint(corner))
        }
        retainSnapGuides(alignedWith: anchors)
    }
}
