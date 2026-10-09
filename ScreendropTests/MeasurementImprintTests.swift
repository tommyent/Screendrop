// sd-xoh: an imprinted measurement keeps the length its label states.
import AppKit
import Testing

@MainActor
@Suite
struct MeasurementImprintTests {
    static func pointer(_ point: Vec, clickCount: Int = 1) -> PointerInfo {
        PointerInfo(screenPoint: point, pagePoint: point, clickCount: clickCount)
    }

    static func editor(_ shapes: [AnnoShape] = []) -> AnnoEditor {
        let editor = AnnoEditor()
        editor.viewport = AnnoViewport(imageFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                       imageSize: CGSize(width: 800, height: 600))
        editor.replaceDocument(shapes: shapes)
        return editor
    }

    static func geometry(_ shape: AnnoShape?) -> (start: Vec, end: Vec, bend: Double, label: String?)? {
        guard case let .arrow(props) = shape?.kind else { return nil }
        return (props.start, props.end, props.bend, props.label)
    }

    /// The three points an ordinary arrow offers as handles, on screen.
    static func handlePoints(_ editor: AnnoEditor, _ shape: AnnoShape) -> [Vec] {
        guard let info = editor.document.arrowInfo(shape.id) else { return [] }
        return [info.start.handle, info.middle, info.end.handle]
            .map { editor.pageToScreen(shape.pageTransform.applyToPoint($0)) }
    }

    @Test func heldArrowStampsOnceAndLeavesNothingSelected() throws {
        let engine = Self.editor()
        // Held ↑, click: one imprint, unselected, so the held key's repeats keep measuring.
        engine.imprintMeasurement(from: Vec(300, 100), to: Vec(300, 220), label: "61 pt · 122 px")
        #expect(engine.shapes.count == 1 && engine.selectedIds.isEmpty)
        let stamped = try #require(engine.shapes.first)
        // The double-click's second click belongs to the same stamp.
        engine.imprintMeasurement(from: Vec(300, 100), to: Vec(300, 220), label: "61 pt · 122 px", clickCount: 2)
        #expect(engine.shapes.count == 1)
        // Still holding: a repeat that reaches the nudge path finds nothing to move.
        engine.nudgeSelected(dx: 0, dy: -1)
        engine.nudgeSelected(dx: 0, dy: -1)
        let after = try #require(engine.shapes.first)
        #expect(engine.shapes.count == 1 && engine.selectedIds.isEmpty)
        #expect(after.x == stamped.x && after.y == stamped.y)
        #expect(Self.geometry(after)?.end == Vec(0, 120))
    }

    @Test func measurementHasNoBendOrEndpointHandles() throws {
        let engine = Self.editor()
        engine.imprintMeasurement(from: Vec(100, 200), to: Vec(300, 200), label: "200 pt · 400 px")
        let shape = try #require(engine.shapes.first)
        engine.selectedIds = [shape.id]
        for point in Self.handlePoints(engine, shape) {
            #expect(engine.handle(at: point) == nil)
        }
        // An ordinary arrow keeps its three handles.
        var props = ArrowProps()
        props.end = Vec(200, 0)
        let arrow = AnnoShape(x: 100, y: 400, kind: .arrow(props))
        let plain = Self.editor([arrow])
        plain.selectedIds = [arrow.id]
        #expect(Self.handlePoints(plain, arrow).map { plain.handle(at: $0) } == [.arrowStart, .arrowMiddle, .arrowEnd])
    }

    @Test func draggingAMeasurementOnlyMovesIt() throws {
        let engine = Self.editor()
        engine.imprintMeasurement(from: Vec(100, 200), to: Vec(300, 200), label: "200 pt · 400 px")
        let shape = try #require(engine.shapes.first)
        let before = try #require(Self.geometry(shape))
        engine.selectedIds = [shape.id]
        // Where the bend handle and an endpoint would be: each press moves the whole measurement.
        for (press, release) in [(Vec(200, 200), Vec(230, 240)), (Vec(330, 240), Vec(360, 250))] {
            engine.pointerDown(Self.pointer(press))
            guard case .translating = engine.interaction else {
                Issue.record("A press at \(press) on a measurement did not move it")
                return
            }
            engine.pointerMove(Self.pointer(release))
            engine.pointerUp(Self.pointer(release))
        }
        let moved = try #require(engine.shapes.first)
        let after = try #require(Self.geometry(moved))
        #expect(moved.x == 160 && moved.y == 250)
        #expect(after.start == before.start && after.end == before.end && after.bend == 0 && after.label == before.label)
    }

    @Test func resizingAGroupMovesAMeasurementWithoutStretchingIt() throws {
        var box = GeoProps()
        box.w = 100; box.h = 100
        let engine = Self.editor([AnnoShape(x: 400, y: 300, kind: .geo(box))])
        engine.imprintMeasurement(from: Vec(100, 200), to: Vec(300, 200), label: "200 pt · 400 px")
        let measurementId = try #require(engine.shapes.first(where: \.isMeasurement)?.id)
        engine.selectedIds = Set(engine.shapes.map(\.id))
        let corner = try #require(engine.selectionBounds?.pagePoint(Vec(1, 1)))
        engine.pointerDown(Self.pointer(engine.pageToScreen(corner)))
        guard case .resizing = engine.interaction else { Issue.record("The group corner did not resize"); return }
        let target = Vec(corner.x + 200, corner.y + 100)
        engine.pointerMove(Self.pointer(target))
        engine.pointerUp(Self.pointer(target))
        let after = try #require(Self.geometry(engine.document.shape(measurementId)))
        #expect(after.start == Vec(0, 0) && after.end == Vec(200, 0) && after.bend == 0)
        guard case let .geo(scaled)? = engine.shapes.first(where: { !$0.isMeasurement })?.kind else {
            Issue.record("The box went missing"); return
        }
        #expect(scaled.w > 100)
    }

    @Test func savedLabelledArrowsLoadLockedAndUnchanged() throws {
        // A measurement bent before this fix: it loads as saved, and stays locked from then on.
        var props = ArrowProps()
        props.end = Vec(160, 0)
        props.bend = 40
        props.label = "80 pt · 160 px"
        props.arrowheadStart = .bar
        props.arrowheadEnd = .bar
        let saved = AnnotationDocument(shapes: [AnnoShape(x: 120, y: 260, kind: .arrow(props))],
                                       background: AnnotationBackgroundSettings())
        let loaded = try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(saved))
        #expect(loaded == saved)
        let engine = Self.editor(loaded.shapes)
        let shape = try #require(engine.shapes.first)
        #expect(shape.isMeasurement && Self.geometry(shape)?.bend == 40)
        engine.selectedIds = [shape.id]
        for point in Self.handlePoints(engine, shape) {
            #expect(engine.handle(at: point) == nil)
        }
    }
}
