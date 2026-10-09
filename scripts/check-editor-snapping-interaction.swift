import AppKit

// Compile with Engine/*.swift and the sources listed in check-editor-fill.swift; no app launch.
@main
struct EditorSnappingInteractionChecks {
    static func pointer(_ point: Vec, scale: Double = 1, command: Bool = false, shift: Bool = false) -> PointerInfo {
        PointerInfo(screenPoint: Vec.mul(point, scale), pagePoint: point, shift: shift, command: command)
    }

    static func geo(_ x: Double, _ y: Double, _ w: Double = 100, _ h: Double = 80) -> AnnoShape {
        var props = GeoProps(); props.w = w; props.h = h
        return AnnoShape(x: x, y: y, kind: .geo(props))
    }

    static func editor(_ shapes: [AnnoShape], scale: Double = 1) -> AnnoEditor {
        let editor = AnnoEditor()
        editor.viewport = AnnoViewport(imageFrame: CGRect(x: 0, y: 0, width: 800 * scale, height: 600 * scale),
                                       imageSize: CGSize(width: 800, height: 600))
        editor.replaceDocument(shapes: shapes)
        return editor
    }

    static func main() {
        let shape = geo(100, 100)
        let isolated = editor([shape])
        let before = isolated.document.snapshot()
        let excluded = isolated.snapMovement(moving: AnnoSnapping.anchors(Vec(195, 175)), excluding: [shape.id],
                                             delta: .zero, pointer: pointer(Vec(195, 175)))
        precondition(excluded.delta == .zero && excluded.guides.isEmpty, "The active shape cannot snap to itself")
        precondition(isolated.document.snapshot().shapes == before.shapes)

        var rotated = geo(200, 100, 60, 40); rotated.rotation = .pi / 4
        let rotation = editor([rotated])
        let edge = rotation.document.pageBounds(rotated.id)!.maxX
        let aligned = rotation.snapMovement(moving: AnnoSnapping.anchors(Vec(edge - 5, 510)), excluding: [],
                                             delta: .zero, pointer: pointer(Vec(edge - 5, 510)))
        precondition(abs(aligned.delta.x - 5) < 0.0001)

        var props = ArrowProps(); props.start = .zero; props.end = Vec(50, 200)
        let arrow = AnnoShape(x: 500, y: 250, kind: .arrow(props))
        let tips = editor([arrow])
        let atTip = tips.snapMovement(moving: AnnoSnapping.anchors(Vec(545, 445)), excluding: [],
                                      delta: .zero, pointer: pointer(Vec(545, 445)))
        precondition(atTip.delta == Vec(5, 5))

        var attachedProps = ArrowProps(); attachedProps.start = .zero; attachedProps.end = Vec(150, 160)
        let attached = AnnoShape(x: 150, y: 140, kind: .arrow(attachedProps))
        let binding = editor([shape, attached])
        binding.document.setBinding(ArrowBinding(arrowId: attached.id, toId: shape.id, terminal: .start,
                                                normalizedAnchor: Vec(0.5, 0.5), isPrecise: false, isExact: false))
        let notAnAnchor = binding.snapMovement(moving: AnnoSnapping.anchors(Vec(295, 295)), excluding: [shape.id],
                                              delta: .zero, pointer: pointer(Vec(295, 295)))
        precondition(notAnAnchor.delta.x == 0, "An attached arrow cannot snap its parent back to itself")
        print("PASS: actual document bounds and arrow tips; self and attached-arrow exclusions; adapter does not mutate the document")
    }
}
