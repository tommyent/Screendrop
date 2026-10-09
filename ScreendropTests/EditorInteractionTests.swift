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
        #expect(hollow.shapes.count == 2 && hollow.tool == .rectangle)

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
        #expect(forced.shapes.count == 2 && forced.shapes[0].x == 100 && forced.tool == .rectangle)
        forced.escapeSelectionOrDisarm()
        #expect(forced.selectedIds.isEmpty && forced.tool == .rectangle)
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
        text.updateEditingText(textID, to: "Keep the text tool armed")
        text.stopEditingText()
        #expect(text.tool == .text)
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
        print("PASS: every tool grabs; hollow interiors draw; Command and intent latch; handles, two-stage Escape, marquee, armed text and hover updates")
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
                #expect(engine.shapes.count == 2 && engine.shapes[0] == region && engine.tool == drawingTool)
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
