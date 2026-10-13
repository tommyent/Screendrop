import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

/// sd-drv: Hand-drawn shapes look like a marker drew them, the same on every redraw, and the
/// export draws exactly what the canvas does.
@MainActor
struct MarkerHandDrawnTests {
    static let page = CGSize(width: 900, height: 600)

    static func shapes(idSuffix: String = "") -> [AnnoShape] {
        var arrow = ArrowProps()
        arrow.end = Vec(420, -150); arrow.strokeWidth = 14; arrow.dash = .draw
        var line = ArrowProps()
        line.end = Vec(300, 40); line.strokeWidth = 10; line.dash = .draw
        line.arrowheadEnd = .none
        var box = GeoProps()
        box.w = 300; box.h = 180; box.strokeWidth = 10; box.dash = .draw
        var oval = GeoProps()
        oval.geo = .ellipse; oval.w = 260; oval.h = 170; oval.strokeWidth = 10; oval.dash = .draw
        return [
            AnnoShape(id: AnnoShapeID("arrow" + idSuffix), x: 60, y: 230, kind: .arrow(arrow)),
            AnnoShape(id: AnnoShapeID("line" + idSuffix), x: 80, y: 520, kind: .arrow(line)),
            AnnoShape(id: AnnoShapeID("box" + idSuffix), x: 540, y: 60, kind: .geo(box)),
            AnnoShape(id: AnnoShapeID("oval" + idSuffix), x: 560, y: 340, kind: .geo(oval)),
        ]
    }

    static func document(_ shapes: [AnnoShape]) -> AnnoDocument {
        let document = AnnoDocument()
        document.restore(AnnoDocument.Snapshot(shapes: shapes, bindings: []))
        return document
    }

    /// The page drawn as the flipped canvas does, or as the y-up export does.
    static func bitmap(_ document: AnnoDocument, flippedCanvas: Bool) -> CGContext {
        let context = CGContext(data: nil, width: Int(page.width), height: Int(page.height), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: page))
        var target = AnnoShapeDrawing.Target(transform: .identity, pageSize: page, sample: { _ in nil },
                                             spotlightClip: nil, isFlippedContext: flippedCanvas)
        if flippedCanvas {
            context.translateBy(x: 0, y: page.height); context.scaleBy(x: 1, y: -1)
        } else {
            target.transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: page.height)
        }
        AnnoShapeDrawing.draw(document, in: context, target: target)
        return context
    }

    static func paths(_ document: AnnoDocument) -> [[CGPath]] {
        document.shapes.map { shape in
            document.renderElements(shape.id).compactMap { element in
                if case let .path(path) = element.content { return path }
                return nil
            }
        }
    }

    @Test func handDrawnIsTheSameEveryRedraw() {
        let first = Self.paths(Self.document(Self.shapes()))
        #expect(first == Self.paths(Self.document(Self.shapes())), "same shape, same marker")
        #expect(first != Self.paths(Self.document(Self.shapes(idSuffix: "-other"))), "seeded by the shape")
        #expect(first[0].count == 2, "an arrow is its bowed body and one open head")
    }

    @Test func exportDrawsExactlyWhatTheCanvasDraws() throws {
        let document = Self.document(Self.shapes())
        let canvas = Self.bitmap(document, flippedCanvas: true), export = Self.bitmap(document, flippedCanvas: false)
        let count = canvas.bytesPerRow * canvas.height
        #expect(Data(bytes: canvas.data!, count: count) == Data(bytes: export.data!, count: count))

        // Set SD_MARKER_PNG (TEST_RUNNER_SD_MARKER_PNG for xcodebuild) to look at the result.
        if let path = ProcessInfo.processInfo.environment["SD_MARKER_PNG"], let image = canvas.makeImage() {
            let destination = try #require(CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
    }

    /// p4's catch in Sol's place: the drawn bow, not just the straight line under it, grabs the arrow.
    @Test func aClickOnTheBowsApexSelectsTheArrow() throws {
        var props = ArrowProps()
        props.end = Vec(1000, 0); props.strokeWidth = 20; props.dash = .draw
        let arrow = AnnoShape(id: AnnoShapeID("bowed"), x: 100, y: 300, kind: .arrow(props))
        let editor = AnnoEditor()
        editor.viewport = AnnoViewport(imageFrame: CGRect(x: 0, y: 0, width: 1400, height: 800),
                                       imageSize: CGSize(width: 1400, height: 800))
        editor.replaceDocument(shapes: [arrow])

        // The body is move(start) then one cubic; its middle is the bow's apex.
        let body = try #require(Self.paths(editor.document)[0].first)
        var points: [CGPoint] = []
        body.applyWithBlock { element in
            let count = element.pointee.type == .addCurveToPoint ? 3 : element.pointee.type == .closeSubpath ? 0 : 1
            for i in 0..<count { points.append(element.pointee.points[i]) }
        }
        try #require(points.count == 4)
        let apex = Vec(0.125 * points[0].x + 0.375 * points[1].x + 0.375 * points[2].x + 0.125 * points[3].x,
                       0.125 * points[0].y + 0.375 * points[1].y + 0.375 * points[2].y + 0.125 * points[3].y)
        // The click margin is 8 page px here; the straight line alone misses the apex.
        #expect(abs(apex.y) > 8)
        #expect(!editor.document.geometry(arrow).hitTestPoint(apex, margin: 8, hitInside: false))
        #expect(editor.hitShape(at: Vec(apex.x + 100, apex.y + 300))?.id == arrow.id)
    }

    @Test func plainShapesStayAsTheyWere() {
        var box = GeoProps(); box.w = 300; box.h = 180
        let document = Self.document([AnnoShape(id: AnnoShapeID("plain"), x: 0, y: 0, kind: .geo(box))])
        #expect(Self.paths(document)[0] == [GeoPaths.path(for: box).solidPath()])
    }
}
