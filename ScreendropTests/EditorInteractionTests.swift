// Ported from scripts/check-editor-interaction.swift; production model/cache code, no UI.
import AppKit
import Testing

@MainActor
@Suite
struct EditorInteractionTests {
    static func pointer(_ x: Double, _ y: Double, command: Bool = false) -> PointerInfo {
        PointerInfo(screenPoint: Vec(x, y), pagePoint: Vec(x, y), command: command)
    }

    static func editor(fill: AnnoFillStyle = .none) -> AnnoEditor {
        let editor = AnnoEditor()
        editor.viewport = AnnoViewport(imageFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                       imageSize: CGSize(width: 800, height: 600))
        var props = GeoProps()
        props.w = 200; props.h = 160; props.fill = fill
        editor.replaceDocument(shapes: [AnnoShape(x: 100, y: 100, kind: .geo(props))])
        return editor
    }

    @Test static func interaction() {
        regionGrabChecks()
        // Every armed tool can grab the stroke; pressing Command later cannot turn it into a draw.
        for tool in AnnotationTool.paletteTools {
            let engine = editor()
            let id = engine.shapes[0].id
            engine.tool = tool
            engine.pointerDown(pointer(100, 135))
            guard case .translating = engine.interaction else { Issue.record("\(tool) did not grab the stroke"); return }
            engine.pointerMove(pointer(120, 155, command: true))
            engine.pointerUp(pointer(120, 155, command: true))
            #expect(engine.shapes.count == 1 && engine.document.shape(id)?.x == 120 && engine.tool == tool)
        }
        let hollow = editor()
        hollow.selectedIds = [hollow.shapes[0].id]
        hollow.pointerDown(pointer(190, 165))
        guard case .creatingGeo = hollow.interaction else { Issue.record("Hollow interior did not draw"); return }
        hollow.pointerMove(pointer(240, 215, command: true))
        hollow.pointerUp(pointer(240, 215))
        #expect(hollow.shapes.count == 2 && hollow.tool == .select)

        let filled = editor(fill: .solid)
        filled.pointerDown(pointer(190, 165))
        guard case .translating = filled.interaction else { Issue.record("Filled body did not move"); return }
        filled.pointerUp(pointer(190, 165))

        let forced = editor()
        forced.selectedIds = [forced.shapes[0].id]
        // A selected corner would resize without Command; a forced draw wins even there.
        forced.pointerDown(pointer(100, 100, command: true))
        guard case .creatingGeo = forced.interaction else { Issue.record("Command did not force draw"); return }
        forced.pointerMove(pointer(165, 165))
        forced.pointerUp(pointer(165, 165))
        #expect(forced.shapes.count == 2 && forced.shapes[0].x == 100 && forced.tool == .select)
        forced.escapeSelectionOrDisarm()
        #expect(forced.selectedIds.isEmpty && forced.tool == .select)
        forced.escapeSelectionOrDisarm()
        #expect(forced.tool == .select && !AnnotationTool.paletteTools.contains(.select))
        forced.pointerDown(pointer(30, 30))
        guard case .brushing = forced.interaction else { Issue.record("Disarmed drag is not a marquee"); return }
        forced.pointerUp(pointer(400, 350))
        #expect(forced.selectedIds.count == 2)

        let handle = editor()
        handle.selectedIds = [handle.shapes[0].id]
        handle.tool = .arrow
        handle.selectedIds = [handle.shapes[0].id]
        handle.pointerDown(pointer(100, 100))
        guard case .resizing = handle.interaction else { Issue.record("Armed tool did not resize via handle"); return }
        handle.pointerUp(pointer(100, 100))
        #expect(handle.tool == .arrow)

        let text = editor()
        text.tool = .text
        text.pointerDown(pointer(500, 300))
        let textID = text.editingTextId!
        text.updateEditingText(textID, to: "Commit text and return to Select")
        text.stopEditingText()
        #expect(text.tool == .select && text.selectedIds == [textID])
        text.tool = .rectangle
        var double = pointer(text.document.shape(textID)!.x + 10, text.document.shape(textID)!.y + 10)
        double.clickCount = 2
        text.pointerDown(double)
        #expect(text.editingTextId == textID && text.tool == .rectangle)
        text.stopEditingText()
        text.pointerUp(double)

        var hoverChanges = 0
        text.onChange = { hoverChanges += 1 }
        text.setHoveredShape(textID)
        text.setHoveredShape(textID)
        #expect(text.hoveredShapeId == textID && hoverChanges == 1)
        text.setHoveredShape(nil)
        #expect(text.hoveredShapeId == nil && hoverChanges == 2)
        print("PASS: every tool grabs; hollow interiors draw; Command and intent latch; handles, two-stage Escape, marquee, committed text and hover updates")
    }

    @Test static func drawingCommitsSelectTheNewShapeAndFinishTheTool() {
        for tool in AnnotationTool.allCases where tool.createsAnnotation {
            let engine = editor()
            engine.replaceDocument(shapes: [])
            engine.tool = tool
            engine.pointerDown(pointer(100, 100))
            engine.pointerMove(pointer(140, 125))
            engine.pointerMove(pointer(180, 160))
            engine.pointerUp(pointer(180, 160))
            if let id = engine.editingTextId {
                #expect(engine.tool == .text, "Text stays editable until commit")
                engine.updateEditingText(id, to: "New text")
                engine.stopEditingText()
            }
            #expect(engine.shapes.count == 1, "\(tool) creates one shape")
            guard let shape = engine.shapes.first else { continue }
            let nextTool: AnnotationTool = [.freehand, .highlighter, .numberedCircle].contains(tool) ? tool : .select
            #expect(engine.tool == nextTool && engine.selectedIds == [shape.id], "\(tool) finishes with the newest shape selected")
            engine.undo()
            #expect(engine.shapes.isEmpty)
            engine.redo()
            #expect(engine.shapes.map(\.id) == [shape.id])
        }
    }

    @Test static func freehandHighlighterAndNumberedCirclesCanBeDrawnInRuns() {
        for tool in [AnnotationTool.freehand, .highlighter, .numberedCircle] {
            let engine = editor()
            engine.replaceDocument(shapes: [])
            engine.tool = tool
            for index in 1...3 {
                let x = Double(index) * 150
                engine.pointerDown(pointer(x, 100))
                engine.pointerMove(pointer(x + 40, 140))
                engine.pointerUp(pointer(x + 40, 140))
                #expect(engine.shapes.count == index && engine.tool == tool)
                #expect(engine.selectedIds == [engine.shapes[index - 1].id])
            }
            if tool == .numberedCircle {
                #expect(engine.shapes.compactMap { $0.numberedProps?.value } == [1, 2, 3])
            }
            engine.escapeSelectionOrDisarm()
            #expect(engine.selectedIds.isEmpty && engine.tool == tool)
            engine.escapeSelectionOrDisarm()
            #expect(engine.tool == .select)
        }
    }

    @Test static func uncommittedDrawsAndExplicitToolChanges() {
        for tool in [AnnotationTool.arrow, .line, .freehand, .highlighter] {
            let engine = editor()
            engine.replaceDocument(shapes: [])
            engine.tool = tool
            engine.pointerDown(pointer(100, 100))
            engine.pointerUp(pointer(100, 100))
            #expect(engine.shapes.isEmpty && engine.selectedIds.isEmpty && engine.tool == tool)
        }
        let text = editor()
        text.tool = .text
        text.pointerDown(pointer(500, 300))
        text.stopEditingText()
        #expect(text.shapes.count == 1 && text.selectedIds.isEmpty && text.tool == .select)
        text.tool = .text
        text.pointerDown(pointer(500, 300))
        if let id = text.editingTextId { text.updateEditingText(id, to: "Keep my next tool") }
        text.tool = .arrow
        #expect(text.editingTextId == nil && text.tool == .arrow)
    }

    @Test(arguments: [false, true])
    static func highlighterDrawsOneAxisLockedSegmentRegardlessOfShift(shift: Bool) throws {
        for destination in [Vec(400, 120), Vec(120, 400), Vec(20, 80), Vec(80, 20), Vec(200, 200)] {
            let engine = editor()
            engine.replaceDocument(shapes: [])
            engine.tool = .highlighter
            engine.viewport.imageSize = CGSize(width: 1800, height: 600)
            engine.currentStrokeWidth = 16
            engine.currentSwatch = AnnotationStylePreset.defaultHighlighterSwatch
            engine.currentDash = .draw
            var down = pointer(100, 100)
            down.shift = shift; down.isPen = true; down.pressure = 0.1
            engine.pointerDown(down)
            for point in [Vec(200, 140), Vec(130, 300), destination] {
                var move = pointer(point.x, point.y)
                move.shift = !shift; move.isPen = true; move.pressure = 0.9
                engine.pointerMove(move)
                let props = try #require(engine.shapes.first?.arrowProps)
                #expect(props.start.x == props.end.x || props.start.y == props.end.y)
                #expect(props.bend == 0 && props.dash == .solid)
            }
            engine.pointerUp(pointer(destination.x, destination.y))
            #expect(engine.shapes.count == 1)
            let shape = try #require(engine.shapes.first)
            let props = try #require(shape.arrowProps)
            let horizontal = abs(destination.x - 100) >= abs(destination.y - 100)
            #expect(shape.tool == .highlighter && props.isHighlighter == true)
            #expect(shape.drawProps == nil && props.start == .zero)
            #expect(props.end == (horizontal ? Vec(destination.x - 100, 0) : Vec(0, destination.y - 100)))
            #expect(props.arrowheadStart == .none && props.arrowheadEnd == .none)
            #expect(shape.swatch == AnnotationStylePreset.defaultHighlighterSwatch && shape.swatch?.alpha == 0.35)
            #expect(props.strokeWidth == 32)
            engine.undo(); #expect(engine.shapes.isEmpty)
            engine.redo(); #expect(engine.shapes == [shape])
        }
    }

    @Test static func commandForcesMarkerDrawingOverASelection() {
        let engine = editor()
        let original = engine.shapes[0]
        engine.tool = .highlighter; engine.selectedIds = [original.id]
        engine.pointerDown(pointer(100, 100, command: true))
        guard case .creatingArrow = engine.interaction else { Issue.record("Command did not force marker drawing"); return }
        engine.pointerMove(pointer(250, 100))
        engine.pointerUp(pointer(250, 100))
        #expect(engine.shapes.count == 2 && engine.shapes[0] == original)
        #expect(engine.shapes[1].tool == .highlighter && engine.tool == .highlighter)
    }

    @Test(arguments: [false, true])
    static func highlighterHasOnlyEndpointsAndItsBodyMoves(horizontal: Bool) throws {
        let engine = editor()
        let props = ArrowProps(end: horizontal ? Vec(300, 0) : Vec(0, 300), arrowheadEnd: .none,
                               swatch: AnnotationStylePreset.defaultHighlighterSwatch, strokeWidth: 16, isHighlighter: true)
        let marker = AnnoShape(x: 100, y: 100, kind: .arrow(props))
        engine.replaceDocument(shapes: [marker]); engine.tool = .highlighter
        let middle = marker.pageTransform.applyToPoint(Vec.med(props.start, props.end))
        engine.pointerDown(pointer(middle.x, middle.y))
        #expect(engine.selectedIds == [marker.id])
        engine.pointerUp(pointer(middle.x, middle.y))
        #expect(engine.handle(at: Vec(100, 100)) == .arrowStart)
        #expect(engine.handle(at: marker.pageTransform.applyToPoint(props.end)) == .arrowEnd)
        #expect(engine.handle(at: middle) == nil)
        #expect(engine.handle(at: Vec(86, 86)) == nil)
        engine.pointerDown(pointer(middle.x, middle.y))
        guard case .translating = engine.interaction else { Issue.record("Marker body did not move"); return }
        engine.pointerMove(pointer(middle.x + 40, middle.y + 30, command: true))
        engine.pointerUp(pointer(middle.x + 40, middle.y + 30))
        let moved = try #require(engine.shapes.first)
        #expect(moved.x == 140 && moved.y == 130 && moved.arrowProps == props)
        engine.undo(); #expect(engine.shapes == [marker])
        engine.redo(); #expect(engine.shapes == [moved])
    }

    @Test(arguments: [AnnoSelectionHandle.arrowStart, .arrowEnd])
    static func highlighterEndpointDragsStayOnAnAxis(handle: AnnoSelectionHandle) throws {
        let engine = editor()
        let props = ArrowProps(end: Vec(300, 0), arrowheadEnd: .none,
                               swatch: AnnotationStylePreset.defaultHighlighterSwatch, strokeWidth: 16, isHighlighter: true)
        let marker = AnnoShape(x: 100, y: 100, kind: .arrow(props))
        var targetProps = GeoProps(); targetProps.w = 100; targetProps.h = 100
        let target = AnnoShape(x: 600, y: 104, kind: .geo(targetProps))
        engine.replaceDocument(shapes: [marker, target]); engine.selectedIds = [marker.id]
        let anchor = handle == .arrowStart ? props.end : props.start
        let initialPoint = marker.pageTransform.applyToPoint(handle == .arrowStart ? props.start : props.end)
        engine.pointerDown(pointer(initialPoint.x, initialPoint.y))
        guard case let .draggingArrowHandle(_, grabbed) = engine.interaction else {
            Issue.record("Marker endpoint did not start an endpoint drag"); return
        }
        #expect(grabbed == handle)
        for offset in [Vec(200, 35), Vec(20, 200), Vec(-200, 35), Vec(20, -200), Vec(200, 200), Vec(0, 0)] {
            let point = marker.pageTransform.applyToPoint(Vec.add(anchor, offset))
            var move = pointer(point.x, point.y); move.shift = true
            engine.pointerMove(move)
            let actual = try #require(engine.document.shape(marker.id)?.arrowProps)
            let horizontal = abs(offset.x) >= abs(offset.y)
            let expected = Vec.add(anchor, horizontal ? Vec(offset.x, 0) : Vec(0, offset.y))
            #expect((handle == .arrowStart ? actual.start : actual.end) == expected)
            #expect((handle == .arrowStart ? actual.end : actual.start) == anchor)
            #expect(actual.bend == 0 && actual.strokeWidth == 16 && actual.swatch == props.swatch)
            #expect(engine.document.bindings.isEmpty)
        }
        engine.pointerUp(pointer(100, 100))
        engine.undo(); #expect(engine.shapes == [marker, target])
    }

    @Test static func highlighterNeverBindsToShapesDuringCreationOrEndpointDrags() throws {
        let engine = editor(fill: .solid)
        engine.tool = .highlighter
        engine.pointerDown(pointer(100, 100, command: true))
        engine.pointerMove(pointer(300, 104))
        engine.pointerUp(pointer(300, 104))
        let marker = try #require(engine.shapes.last)
        #expect(marker.arrowProps?.end == Vec(200, 0) && engine.document.bindings.isEmpty)
        engine.pointerDown(pointer(300, 100))
        engine.pointerMove(pointer(300, 258))
        engine.pointerUp(pointer(300, 258))
        #expect(engine.document.shape(marker.id)?.arrowProps?.end == Vec(200, 0))
        #expect(engine.document.bindings.isEmpty)
    }

    @Test(arguments: [false, true])
    static func legacyFreehandHighlighterCanStillBeSelectedResizedAndRotated(horizontal: Bool) throws {
        let engine = editor()
        let props = DrawProps(points: horizontal ? [Vec(0, 0), Vec(300, 0)] : [Vec(0, 0), Vec(200, 40), Vec(300, 100)],
                              isComplete: true, isHighlighter: true, strokeWidth: 16)
        let marker = AnnoShape(x: 100, y: 100, kind: .draw(props))
        engine.replaceDocument(shapes: [marker]); engine.tool = .select
        let hit = marker.pageTransform.applyToPoint(engine.document.geometry(marker).vertices[1])
        engine.pointerDown(pointer(hit.x, hit.y))
        #expect(engine.selectedIds == [marker.id])
        engine.pointerUp(pointer(hit.x, hit.y))
        let bounds = try #require(engine.selectionBounds)
        let corner = bounds.pagePoint(Vec(1, 1))
        engine.pointerDown(pointer(corner.x, corner.y))
        guard case .resizing = engine.interaction else { Issue.record("Marker handle did not resize"); return }
        engine.pointerMove(pointer(corner.x + 100, corner.y + 50, command: true))
        engine.pointerUp(pointer(corner.x + 100, corner.y + 50))
        let resized = try #require(engine.shapes.first)
        #expect(resized.drawProps?.points != props.points && resized.tool == .highlighter)
        #expect(resized.swatch == marker.swatch && resized.strokeWidth == marker.strokeWidth)
        let center = try #require(engine.selectionBounds).pageCenter
        engine.markUndo()
        engine.setInteraction(.rotating(center: center, startAngle: 0, initial: engine.document.snapshot()))
        engine.pointerMove(pointer(center.x, center.y + 100, command: true))
        engine.pointerUp(pointer(center.x, center.y + 100))
        let rotated = try #require(engine.shapes.first)
        #expect(abs(rotated.rotation - .pi / 2) < 0.0001 && rotated.tool == .highlighter)
        engine.undo(); #expect(engine.shapes == [resized])
        engine.undo(); #expect(engine.shapes == [marker])
    }

    static func regionGrabChecks() {
        for regionTool in [AnnotationTool.pixelate, .blur, .highlight] {
            let kind: AnnoShapeKind
            if regionTool == .highlight {
                kind = .highlight(HighlightProps(w: 200, h: 160))
            } else {
                var props = RedactionProps(); props.kind = regionTool == .blur ? .blur : .pixelate
                props.w = 200; props.h = 160; kind = .redaction(props)
            }
            let region = AnnoShape(x: 100, y: 100, kind: kind)
            for drawingTool in [AnnotationTool.arrow, .magnifier] {
                let engine = editor()
                engine.replaceDocument(shapes: [region]); engine.selectedIds = [region.id]
                engine.tool = drawingTool
                #expect(engine.hitShape(at: Vec(180, 170)) == nil, "\(regionTool) interior must not grab")
                engine.pointerDown(pointer(180, 170))
                switch (drawingTool, engine.interaction) {
                case (.arrow, .creatingArrow), (.magnifier, .creatingMagnifier): break
                default: Issue.record("\(drawingTool) must draw inside \(regionTool) without Command"); return
                }
                engine.pointerMove(pointer(250, 230)); engine.pointerUp(pointer(250, 230))
                #expect(engine.shapes.count == 2 && engine.shapes[0] == region && engine.tool == .select && engine.selectedIds == [engine.shapes[1].id])
            }
            let edge = editor(); edge.replaceDocument(shapes: [region]); edge.tool = .magnifier
            #expect(edge.hitShape(at: Vec(95, 135))?.id == region.id && edge.hitShape(at: Vec(110, 135)) == nil)
            #expect(edge.shapes(in: Box(150, 150, 10, 10)).map(\.id) == [region.id], "Marquee overlap stays filled")
            edge.pointerDown(pointer(100, 135))
            guard case .translating = edge.interaction else { Issue.record("Region edge must move"); return }
            edge.pointerMove(pointer(120, 155, command: true)); edge.pointerUp(pointer(120, 155))
            #expect(edge.shapes[0].x == 120 && edge.shapes[0].y == 120)
            edge.undo(); #expect(edge.shapes == [region])
            edge.selectedIds = [region.id]
            edge.pointerDown(pointer(100, 100))
            guard case .resizing = edge.interaction else { Issue.record("Selected region handle must resize"); return }
            edge.pointerUp(pointer(100, 100))

            var rotated = region; rotated.rotation = .pi / 4
            let rotation = editor(); rotation.replaceDocument(shapes: [rotated])
            #expect(rotation.hitShape(at: rotated.pageTransform.applyToPoint(Vec(0, 35)))?.id == region.id)
            #expect(rotation.hitShape(at: rotated.pageTransform.applyToPoint(Vec(80, 70))) == nil)
        }
        print("PASS: pixelate/blur/highlight interiors draw arrows and magnifiers; edges move, handles resize, rotated hits, marquee and undo preserved")
    }
}
