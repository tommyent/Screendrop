import AppKit
import Testing

@MainActor
struct AnnotationClipboardTests {
    static func board() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("annotation-copy-tests-\(UUID().uuidString)"))
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
