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

    @Test func plainShapesStayAsTheyWere() {
        var box = GeoProps(); box.w = 300; box.h = 180
        let document = Self.document([AnnoShape(id: AnnoShapeID("plain"), x: 0, y: 0, kind: .geo(box))])
        #expect(Self.paths(document)[0] == [GeoPaths.path(for: box).solidPath()])
    }
}
