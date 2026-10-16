import AppKit
import Testing

@MainActor
struct AnnotationClipboardTests {
    static func board() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("annotation-copy-tests-\(UUID().uuidString)"))
    }

    private struct Payload: Encodable {
        var shapes: [AnnoShape]
        var bindings: [ArrowBinding]
        var images: [String: Data]
    }

    private static func expectRejected(_ shapes: [AnnoShape], bindings: [ArrowBinding] = []) throws {
        let board = board()
        defer { board.releaseGlobally() }
        let bytes = PastedImageTests.bandedPNG()
        let asset = try #require(AnnoImageAsset(data: bytes))
        let editor = AnnoEditor()
        let text = AnnoShape(x: 10, y: 20, kind: .text(TextProps()))
        editor.replaceDocument(shapes: [text])
        editor.imageAssets["kept"] = asset
        editor.selectedIds = [text.id]
        editor.markUndo()
        editor.nudgeSelected(dx: 1, dy: 0)
        editor.undo()
        editor.editingTextId = text.id
        let before = editor.document.snapshot()
        let revision = editor.historyRevision
        let selection = editor.selectedIds
        let tool = editor.tool
        let images = editor.imageAssets.mapValues { ObjectIdentifier($0.image) }
        var notifications = 0
        editor.onChange = { notifications += 1 }
        let picture = AnnoShape(x: 30, y: 40, kind: .image(ImageProps(assetID: "incoming", w: 20, h: 20)))
        let payload = Payload(shapes: [picture] + shapes, bindings: bindings, images: ["incoming": bytes])
        board.setData(try JSONEncoder().encode(payload), forType: AnnoEditor.annotationPasteboardType)
        #expect(!editor.pasteAnnotations(from: board))
        #expect(editor.shapes == before.shapes && editor.document.bindings == before.bindings)
        #expect(editor.historyRevision == revision && editor.canUndo && editor.canRedo)
        #expect(editor.imageAssets.mapValues(\.data) == ["kept": bytes])
        #expect(editor.imageAssets.mapValues({ ObjectIdentifier($0.image) }) == images)
        #expect(editor.editingTextId == text.id && editor.selectedIds == selection && editor.tool == tool)
        #expect(editor.annotationPasteRun?.count == nil && notifications == 0)
    }

    @Test static func selfBoundArrowIsRejectedWithoutMutation() throws {
        let arrow = AnnoShape(x: 0, y: 0, kind: .arrow(ArrowProps()))
        let binding = ArrowBinding(arrowId: arrow.id, toId: arrow.id, terminal: .end,
                                   normalizedAnchor: Vec(0.5, 0.5), isPrecise: false, isExact: false)
        try expectRejected([arrow], bindings: [binding])
    }

    @Test static func extremeDashedGeometryIsRejectedWithoutMutation() throws {
        for (width, stroke) in [(1e308, 1e-308), (100, 1e-308), (1e308, 8)] {
            try expectRejected([AnnoShape(x: 0, y: 0, kind: .geo(GeoProps(w: width, h: 100, strokeWidth: stroke, dash: .dashed)))])
        }
    }

    @Test static func clipboardBindingsUseTheDrawingRules() throws {
        let arrow = AnnoShape(x: 0, y: 0, kind: .arrow(ArrowProps()))
        let box = AnnoShape(x: 200, y: 100, kind: .geo(GeoProps()))
        let invalidPairs = [(box, AnnoShape(x: 300, y: 100, kind: .geo(GeoProps()))),
                            (arrow, AnnoShape(x: 100, y: 0, kind: .arrow(ArrowProps()))),
                            (arrow, AnnoShape(x: 100, y: 0, kind: .highlight(HighlightProps()))),
                            (arrow, AnnoShape(x: 100, y: 0, kind: .redaction(RedactionProps()))),
                            (AnnoShape(x: 0, y: 0, kind: .arrow(ArrowProps(isHighlighter: true))), box)]
        for (source, target) in invalidPairs {
            let binding = ArrowBinding(arrowId: source.id, toId: target.id, terminal: .end,
                                       normalizedAnchor: Vec(0.5, 0.5), isPrecise: false, isExact: false)
            let shapes = source.id == target.id ? [source] : [source, target]
            try expectRejected(shapes, bindings: [binding])
        }
        let unsafeAnchor = ArrowBinding(arrowId: arrow.id, toId: box.id, terminal: .end,
                                        normalizedAnchor: Vec(1e308, 0.5), isPrecise: true, isExact: false)
        try expectRejected([arrow, box], bindings: [unsafeAnchor])
    }

    @Test static func unsafeNumericPropertiesAndOffsetAreRejectedWithoutMutation() throws {
        let shapes = [
            AnnoShape(x: 1_000_000, y: 0, kind: .geo(GeoProps())), // Paste's offset exceeds the bound.
            AnnoShape(x: 0, y: 0, kind: .geo(GeoProps(cornerRadius: 1e308))),
            AnnoShape(x: 0, y: 0, kind: .draw(DrawProps(points: [Vec(0, 0, 1e308)]))),
            AnnoShape(x: 0, y: 0, kind: .arrow(ArrowProps(end: Vec(1e308, 0)))),
            AnnoShape(x: 0, y: 0, kind: .text(TextProps(fontSize: 1e308))),
            AnnoShape(x: 0, y: 0, kind: .redaction(RedactionProps(density: 1e308))),
            AnnoShape(x: 0, y: 0, kind: .highlight(HighlightProps(w: 1e308))),
            AnnoShape(x: 0, y: 0, kind: .numbered(NumberedProps(diameter: 1e308))),
            AnnoShape(x: 0, y: 0, kind: .magnifier(MagnifierProps(loupe: Vec(1e308, 0)))),
            AnnoShape(x: 0, y: 0, kind: .image(ImageProps(assetID: "incoming", w: 20, h: 1e308))),
        ]
        for shape in shapes { try expectRejected([shape]) }
    }

    @Test static func roundTripKeepsGeometryAndStylesWithNewIDsAndSteppingOffset() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let source = AnnoEditor()
        let shapes: [AnnoShape] = [
            AnnoShape(x: 30, y: 50, rotation: 0.3, opacity: 0.6, kind: .geo(GeoProps(w: 120, h: 80))),
            AnnoShape(x: 40, y: 60, kind: .text(TextProps(text: "Copy me", fontSize: 32))),
            AnnoShape(x: 70, y: 90, kind: .draw(DrawProps(points: [Vec(0, 0), Vec(50, 30)], isComplete: true))),
            AnnoShape(x: 80, y: 100, kind: .arrow(ArrowProps())),
            AnnoShape(x: 90, y: 110, kind: .redaction(RedactionProps())),
            AnnoShape(x: 100, y: 120, kind: .highlight(HighlightProps())),
            AnnoShape(x: 110, y: 130, kind: .numbered(NumberedProps(value: 3))),
            AnnoShape(x: 120, y: 140, kind: .magnifier(MagnifierProps())),
        ]
        source.viewport.imageSize = CGSize(width: 800, height: 600)
        source.replaceDocument(shapes: shapes)
        source.selectAll()
        #expect(source.copySelection(to: board))
        #expect(source.shapes == shapes && !source.canUndo)
        let target = AnnoEditor()
        target.viewport.imageSize = CGSize(width: 2000, height: 300)
        for step in 1...3 {
            let revision = target.historyRevision
            #expect(target.pasteAnnotations(from: board))
            #expect(target.historyRevision == revision + 1)
            let pasted = target.selectedShapes
            #expect(pasted.count == shapes.count && target.tool == .select)
            for (original, copy) in zip(shapes, pasted) {
                #expect(copy.id != original.id)
                #expect(copy.x == original.x + Double(step * 20))
                #expect(copy.y == original.y + Double(step * 20))
                #expect(copy.kind == original.kind && copy.rotation == original.rotation && copy.opacity == original.opacity)
            }
            #expect(Set(target.shapes.map(\.id)).count == target.shapes.count)
        }
        let pasted = target.shapes
        target.undo()
        #expect(target.shapes.count == shapes.count * 2 && target.selectedIds.isEmpty)
        target.redo()
        #expect(target.shapes == pasted)
        // Re-copying replaces the payload and starts the offset at the first step again.
        source.selectedIds = [shapes[1].id]
        #expect(source.copySelection(to: board))
        #expect(target.pasteAnnotations(from: board))
        let newest = try #require(target.selectedShapes.first)
        #expect(target.selectedShapes.count == 1 && newest.x == shapes[1].x + 20 && newest.kind == shapes[1].kind)
    }

    @Test static func copiedBindingsPointOnlyAtCopiesAndExternalTerminalsStayPut() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let source = AnnoEditor()
        let box = AnnoShape(x: 200, y: 200, kind: .geo(GeoProps(w: 100, h: 80)))
        let arrow = AnnoShape(x: 30, y: 240, kind: .arrow(ArrowProps(end: Vec(1, 1))))
        let binding = ArrowBinding(arrowId: arrow.id, toId: box.id, terminal: .end,
                                   normalizedAnchor: Vec(0.5, 0.5), isPrecise: false, isExact: false)
        source.replaceDocument(shapes: [box, arrow], bindings: [binding])
        source.selectAll()
        #expect(source.copySelection(to: board))
        #expect(source.pasteAnnotations(from: board))
        let copies = source.selectedShapes
        let copiedBinding = try #require(source.document.bindings.last)
        #expect(copiedBinding.arrowId == copies[1].id && copiedBinding.toId == copies[0].id)
        #expect(copiedBinding.normalizedAnchor == binding.normalizedAnchor)
        source.selectedIds = [arrow.id]
        let originalEnd = try #require(source.document.arrowInfo(arrow.id)).end.point
        #expect(source.copySelection(to: board))
        let target = AnnoEditor()
        #expect(target.pasteAnnotations(from: board))
        let copy = try #require(target.shapes.first)
        #expect(target.document.bindings.isEmpty && copy.arrowProps?.end == originalEnd)
    }

    @Test static func copiedPicturesCarryTheirBytesAndCannotOverwriteExistingAssets() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let bytes = PastedImageTests.bandedPNG()
        let asset = try #require(AnnoImageAsset(data: bytes))
        let source = AnnoEditor()
        source.viewport.imageSize = CGSize(width: 800, height: 600)
        let id = source.insertImage(asset, assetID: "same-id")
        let picture = try #require(source.document.shape(id))
        #expect(source.copySelection(to: board))
        source.release()
        let target = AnnoEditor()
        target.imageAssets["same-id"] = asset
        #expect(target.pasteAnnotations(from: board))
        let pasted = try #require(target.shapes.first?.imageProps)
        #expect(pasted.assetID != "same-id" && target.imageAssets[pasted.assetID]?.data == bytes)
        #expect(pasted.w == picture.imageProps?.w && pasted.h == picture.imageProps?.h)
        target.undo()
        #expect(target.shapes.isEmpty)
        target.redo()
        #expect(target.shapes.first?.imageProps == pasted && target.imageAssets[pasted.assetID]?.data == bytes)
    }

    @Test static func detachedCurvedArrowsKeepTheirRenderedArc() throws {
        let board = board()
        defer { board.releaseGlobally() }
        for bend in [-80.0, 80, 180] {
            for includeStartTarget in [false, true] {
                let source = AnnoEditor()
                let start = AnnoShape(x: 100, y: 200, kind: .geo(GeoProps(w: 80, h: 80)))
                let end = AnnoShape(x: 400, y: 200, kind: .geo(GeoProps(w: 80, h: 80)))
                let arrow = AnnoShape(x: 0, y: 0, kind: .arrow(ArrowProps(start: Vec(140, 240), end: Vec(440, 240), bend: bend)))
                let bindings = [(ArrowTerminal.start, start.id), (.end, end.id)].map { terminal, id in
                    ArrowBinding(arrowId: arrow.id, toId: id, terminal: terminal,
                                 normalizedAnchor: Vec(0.5, 0.5), isPrecise: false, isExact: false)
                }
                source.replaceDocument(shapes: [start, end, arrow], bindings: bindings)
                source.selectedIds = includeStartTarget ? [start.id, arrow.id] : [arrow.id]
                let before = try #require(source.document.arrowInfo(arrow.id))
                #expect(source.copySelection(to: board))
                let target = AnnoEditor()
                #expect(target.pasteAnnotations(from: board))
                let copiedArrow = try #require(target.shapes.last)
                let after = try #require(target.document.arrowInfo(copiedArrow.id))
                guard case let .arc(original) = before.body, case let .arc(copy) = after.body else {
                    Issue.record("Curved arrow became straight"); continue
                }
                #expect(Vec.dist(original.center, copy.center) < 0.0001)
                #expect(abs(original.radius - copy.radius) < 0.0001)
                #expect(original.sweepFlag == copy.sweepFlag && original.largeArcFlag == copy.largeArcFlag)
                #expect(Vec.dist(before.start.point, after.start.point) < 0.0001)
                #expect(Vec.dist(before.end.point, after.end.point) < 0.0001)
            }
        }
    }

    @Test static func noSelectionAndNewPictureOrTextNeverReuseAnOldAnnotationCopy() {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString("keep", forType: .string)
        let editor = AnnoEditor()
        let change = board.changeCount
        #expect(!editor.copySelection(to: board) && board.changeCount == change)
        let shape = AnnoShape(x: 10, y: 10, kind: .geo(GeoProps()))
        editor.replaceDocument(shapes: [shape])
        editor.selectAll()
        #expect(editor.copySelection(to: board) && editor.pasteAnnotations(from: board))
        board.clearContents()
        board.setData(PastedImageTests.bandedPNG(), forType: .png)
        #expect(!editor.pasteAnnotations(from: board))
        #expect(AnnoImageAsset.pasteboardData(board) != nil)
        board.clearContents()
        board.setString("text", forType: .string)
        #expect(!editor.pasteAnnotations(from: board) && editor.shapes.count == 2)
        board.clearContents()
        board.setData(Data("broken".utf8), forType: AnnoEditor.annotationPasteboardType)
        let revision = editor.historyRevision
        #expect(!editor.pasteAnnotations(from: board) && editor.historyRevision == revision)
        #expect(editor.shapes.count == 2)
    }
}
