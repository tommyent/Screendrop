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
        case .magnifierRing: props.ring = Vec.add(initial.ring, Vec.sub(local, origin))
        case .magnifierLoupe: props.loupe = Vec.add(initial.loupe, Vec.sub(local, origin))
        case .magnifierRingResize:
            props.ringSize = Swift.max(8, 2 * Swift.max(abs(local.x - props.ring.x), abs(local.y - props.ring.y)))
        case .magnifierLoupeResize:
            props.loupeSize = Swift.max(8, 2 * Swift.max(abs(local.x - props.loupe.x), abs(local.y - props.loupe.y)))
        default: return
        }
        guard props.isValid else { return }
        document.update(id) { $0.kind = .magnifier(props) }
    }
}
