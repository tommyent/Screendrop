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
        interactionChecks()
        print("PASS: actual document bounds and arrow tips; self and attached-arrow exclusions; adapter does not mutate the document")
    }

    static func interactionChecks() {
        // Run the exact 5/7-screen-point gate first, through actual pointer events at three zooms.
        for scale in [0.5, 1.0, 2.0] {
            let source = geo(100, 100)
            let target = geo(400, 200)
            for distance in [5.0, 7.0] {
                let engine = editor([source, target], scale: scale)
                let end = Vec(300 - distance / scale, 180)
                engine.pointerDown(pointer(Vec(100, 135), scale: scale))
                engine.pointerMove(pointer(end, scale: scale))
                let expected = distance == 5 ? 300 : end.x
                precondition(abs(engine.document.shape(source.id)!.x - expected) < 0.0001, "\(distance) pt at \(scale)x")
                precondition(engine.snapGuides.contains { $0.start.x == 400 && $0.end.x == 400 } == (distance == 5))
                engine.pointerUp(pointer(end, scale: scale))
                precondition(engine.snapGuides.isEmpty && engine.shapes.count == 2)
                engine.undo()
                precondition(engine.document.shape(source.id) == source, "One undo must restore the whole drag")
            }
        }

        let source = geo(100, 100), target = geo(400, 200)
        let move = editor([source, target])
        move.pointerDown(pointer(Vec(100, 135)))
        move.pointerMove(pointer(Vec(295, 190)))
        precondition(move.document.shape(source.id)!.x == 300 && !move.snapGuides.isEmpty)
        move.pointerMove(pointer(Vec(295, 190), command: true))
        guard case .translating = move.interaction else { preconditionFailure("Command changed a latched move into a draw") }
        precondition(move.document.shape(source.id)!.x == 295 && move.snapGuides.isEmpty)
        move.pointerMove(pointer(Vec(295, 190)))
        precondition(move.document.shape(source.id)!.x == 300, "No correction may accumulate between samples")
        move.pointerUp(pointer(Vec(295, 190)))
        move.undo(); move.redo()
        precondition(move.document.shape(source.id)!.x == 300 && move.snapGuides.isEmpty)

        let lock = editor([source, target])
        lock.pointerDown(pointer(Vec(100, 135)))
        lock.pointerMove(pointer(Vec(295, 150), shift: true))
        precondition(lock.document.shape(source.id)!.x == 300 && lock.document.shape(source.id)!.y == 100)

        let resize = editor([source, target])
        resize.selectedIds = [source.id]
        resize.pointerDown(pointer(Vec(200, 180)))
        resize.pointerMove(pointer(Vec(395, 195)))
        let sized = resize.document.shape(source.id)!.geoProps!
        precondition(sized.w == 300 && sized.h == 100 && !resize.snapGuides.isEmpty)
        resize.pointerUp(pointer(Vec(395, 195)))

        var rotated = source; rotated.rotation = .pi / 4
        let transform = rotated.pageTransform
        let desired = transform.applyToPoint(Vec(160, 40))
        let rotation = editor([rotated, geo(desired.x, 500)])
        rotation.selectedIds = [rotated.id]
        rotation.pointerDown(pointer(transform.applyToPoint(Vec(100, 40))))
        rotation.pointerMove(pointer(Vec.sub(desired, Vec.rot(Vec(5, 0), rotated.rotation))))
        let rotatedSize = rotation.document.shape(rotated.id)!.geoProps!
        precondition(abs(rotatedSize.w - 160) < 0.0001 && abs(rotatedSize.h - 80) < 0.0001,
                     "A rotated side handle must snap without changing its other dimension")
        precondition(!rotation.snapGuides.isEmpty)

        var number = NumberedProps(); number.diameter = 100
        let callout = AnnoShape(x: 100, y: 100, kind: .numbered(number))
        let calloutResize = editor([callout, geo(300, 500)])
        calloutResize.selectedIds = [callout.id]
        calloutResize.pointerDown(pointer(Vec(200, 150)))
        calloutResize.pointerMove(pointer(Vec(395, 150)))
        precondition(abs(calloutResize.shapes[0].numberedProps!.diameter - 200) < 0.0001)
        precondition(calloutResize.snapGuides.contains { $0.start.x == 300 && $0.end.x == 300 },
                     "Callout snapping must use its painted handle, not the virtual rectangular handle")

        var textProps = TextProps(); textProps.text = "Snapping"; textProps.w = 120
        textProps.fontSize = 20; textProps.autoSize = false
        let text = AnnoShape(x: 100, y: 100, kind: .text(textProps))
        let textResize = editor([text, geo(385, 500)])
        textResize.selectedIds = [text.id]
        let textHandle = textResize.selectionBounds!.pagePoint(Vec(1, 1))
        textResize.pointerDown(pointer(textHandle))
        textResize.pointerMove(pointer(Vec(350, 170), command: true))
        precondition(textResize.document.pageBounds(text.id)!.maxX == 380 && textResize.snapGuides.isEmpty)
        textResize.pointerMove(pointer(Vec(350, 170)))
        precondition(textResize.document.pageBounds(text.id)!.maxX == 385 && !textResize.snapGuides.isEmpty,
                     "Text resize must snap its uniformly sized text, not the rectangular pointer handle")

        let group = editor([source, geo(100, 280), geo(500, 450)])
        group.selectedIds = [source.id, group.shapes[1].id]
        group.pointerDown(pointer(Vec(100, 135)))
        group.pointerMove(pointer(Vec(395, 165)))
        precondition(group.shapes[0].x == 400 && group.shapes[1].x == 400,
                     "A selection moves as one box without changing its internal spacing")
        group.pointerUp(pointer(Vec(395, 165)))
        group.undo()
        precondition(group.shapes[0] == source && group.shapes[1].x == 100)

        for tool in [AnnotationTool.rectangle, .ellipse, .highlight, .blur, .pixelate] {
            let draw = editor([target])
            draw.tool = tool; draw.currentDash = .draw
            draw.pointerDown(pointer(Vec(110, 100)))
            draw.pointerMove(pointer(Vec(395, 195)))
            let created = draw.shapes.last!
            precondition(abs(draw.document.pageBounds(created.id)!.maxX - 400) < 0.0001)
            precondition(!draw.snapGuides.isEmpty)
            if let props = created.geoProps { precondition(props.dash == .draw) }
            draw.pointerUp(pointer(Vec(395, 195)))
            precondition(draw.snapGuides.isEmpty && draw.tool == tool)
        }
        let square = editor([])
        square.pointerDown(pointer(Vec(100, 100)))
        square.pointerMove(pointer(Vec(396, 220), shift: true))
        precondition(square.shapes[0].geoProps!.w == 300 && square.shapes[0].geoProps!.h == 300)

        var arrowProps = ArrowProps(); arrowProps.end = Vec(60, 80)
        let otherArrow = AnnoShape(x: 500, y: 350, kind: .arrow(arrowProps))
        for tool in [AnnotationTool.arrow, .line, .freehand] {
            let draw = editor([otherArrow]); draw.tool = tool; draw.currentDash = .draw
            draw.pointerDown(pointer(Vec(250, 120)))
            draw.pointerMove(pointer(Vec(555, 425)))
            let created = draw.shapes.last!
            if let arrow = draw.document.arrowInfo(created.id) {
                let tip = created.pageTransform.applyToPoint(arrow.end.point)
                precondition(Vec.dist(tip, Vec(560, 430)) < 0.0001)
                precondition(created.arrowProps!.dash == .draw)
            } else {
                let tip = created.pageTransform.applyToPoint(created.drawProps!.points.last!)
                precondition(Vec.dist(tip, Vec(560, 430)) < 0.0001)
            }
            precondition(!draw.snapGuides.isEmpty)
            draw.pointerUp(pointer(Vec(555, 425)))
            precondition(draw.snapGuides.isEmpty)
        }
        let arrowResize = editor([otherArrow, geo(650, 500)])
        arrowResize.selectedIds = [otherArrow.id]
        arrowResize.pointerDown(pointer(Vec(560, 430)))
        arrowResize.pointerMove(pointer(Vec(645, 450)))
        let movedTip = arrowResize.shapes[0].pageTransform.applyToPoint(arrowResize.document.arrowInfo(otherArrow.id)!.end.point)
        precondition(movedTip == Vec(650, 450) && !arrowResize.snapGuides.isEmpty)
        arrowResize.pointerMove(pointer(Vec(645, 450), command: true))
        precondition(arrowResize.shapes[0].pageTransform.applyToPoint(arrowResize.document.arrowInfo(otherArrow.id)!.end.point) == Vec(645, 450)
                     && arrowResize.snapGuides.isEmpty)
        magnifierChecks()
        print("PASS: pointer-driven 5/7 pt at three zooms, Command latch/bypass/resume, undo/redo, Shift, rotated/callout/text resize, group move, five box tools, lines/arrows/freehand/arrow handles and hand-drawn style")
    }

    static func magnifierChecks() {
        var props = MagnifierProps(); props.ringSize = 60; props.loupeSize = 120; props.loupe = Vec(180, 0)
        let magnifier = AnnoShape(x: 150, y: 150, kind: .magnifier(props))
        let target = geo(500, 400)
        for handle in [AnnoSelectionHandle.magnifierRing, .magnifierLoupe] {
            let engine = editor([magnifier, target])
            engine.selectedIds = [magnifier.id]
            let origin = magnifier.pageTransform.applyToPoint(handle == .magnifierRing ? props.ring : props.loupe)
            engine.pointerDown(pointer(origin))
            guard case .draggingMagnifier = engine.interaction else { preconditionFailure("Magnifier part did not grab") }
            let half = (handle == .magnifierRing ? props.ringSize : props.loupeSize) / 2
            let destination = Vec(500 - half - 5, 350)
            engine.pointerMove(pointer(destination))
            guard case let .magnifier(after) = engine.shapes[0].kind else { preconditionFailure() }
            let moved = handle == .magnifierRing ? after.ring : after.loupe
            precondition(abs(magnifier.x + moved.x + half - 500) < 0.0001)
            precondition(handle == .magnifierRing ? after.loupe == props.loupe : after.ring == props.ring)
            precondition(!engine.snapGuides.isEmpty)
            engine.pointerMove(pointer(destination, command: true))
            guard case let .magnifier(bypassed) = engine.shapes[0].kind else { preconditionFailure() }
            let freelyMoved = handle == .magnifierRing ? bypassed.ring : bypassed.loupe
            precondition(abs(magnifier.x + freelyMoved.x + half - 495) < 0.0001 && engine.snapGuides.isEmpty)
            engine.pointerUp(pointer(destination))
            engine.undo()
            precondition(engine.shapes[0] == magnifier)
        }
        for handle in [AnnoSelectionHandle.magnifierRingResize, .magnifierLoupeResize] {
            let engine = editor([magnifier, target]); engine.selectedIds = [magnifier.id]
            let origin = magnifier.pageTransform.applyToPoint(props.handles.first { $0.0 == handle }!.1)
            engine.pointerDown(pointer(origin))
            let center = magnifier.pageTransform.applyToPoint(handle == .magnifierRingResize ? props.ring : props.loupe)
            let half = 400 - center.y
            let end = Vec(center.x + half - 4, center.y + half - 4)
            engine.pointerMove(pointer(end))
            guard case let .magnifier(after) = engine.shapes[0].kind else { preconditionFailure() }
            let size = handle == .magnifierRingResize ? after.ringSize : after.loupeSize
            precondition(abs(size / 2 + center.y - 400) < 0.0001)
            precondition(handle == .magnifierRingResize ? after.loupeSize == props.loupeSize : after.ringSize == props.ringSize)
            precondition(!engine.snapGuides.isEmpty)
        }
        var rotated = magnifier; rotated.rotation = .pi / 6
        let desired = rotated.pageTransform.applyToPoint(Vec(80, 80))
        let rotatedResize = editor([rotated, geo(desired.x, 500)])
        rotatedResize.selectedIds = [rotated.id]
        rotatedResize.pointerDown(pointer(rotated.pageTransform.applyToPoint(Vec(30, 30))))
        rotatedResize.pointerMove(pointer(Vec.sub(desired, Vec.mul(Vec.rot(Vec(1, 1).uni, rotated.rotation), 5))))
        guard case let .magnifier(resized) = rotatedResize.shapes[0].kind else { preconditionFailure() }
        precondition(abs(resized.ringSize - 160) < 0.0001 && !rotatedResize.snapGuides.isEmpty)

        let creation = editor([geo(500, 400)]); creation.tool = .magnifier
        creation.pointerDown(pointer(Vec(100, 100)))
        creation.pointerMove(pointer(Vec(495, 355)))
        guard case let .magnifier(created) = creation.shapes.last!.kind else { preconditionFailure() }
        precondition(abs(creation.shapes.last!.x + created.ringRect.maxX - 500) < 0.0001)
        precondition(abs(created.zoom - 3) < 0.0001 && !creation.snapGuides.isEmpty)
        print("PASS: independent ring/loupe moves and square resizes, Command bypass, guides and one-step undo")
    }
}
