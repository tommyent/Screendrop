import AppKit
import Testing

@MainActor
struct EditorExportTests {
    @Test func highlighterSymbolLoadsWithInstalledSDK() {
        #expect(NSImage(systemSymbolName: AnnotationTool.highlighter.systemImage, accessibilityDescription: nil) != nil)
    }

    @Test func highlighterUsesOneConstantWidthNormalAlphaOutline() throws {
        let size = CGSize(width: 400, height: 180)
        let swatch = AnnotationStylePreset.defaultHighlighterSwatch
        var props = DrawProps(points: (0...20).map { Vec(Double($0) * 15, 0, Double($0) / 20) },
                              isComplete: true, isPen: true, isHighlighter: true, swatch: swatch, strokeWidth: 16)
        let marker = AnnoShape(x: 40, y: 60, kind: .draw(props))
        let document = AnnoDocument(); document.add(marker)
        let elements = AnnoShapeRenderer.elements(for: marker, in: document)
        guard case let .path(path) = try #require(elements.first).content else {
            Issue.record("Marker did not produce an outline"); return
        }
        #expect(elements.count == 1 && elements[0].fill == swatch.nsColor)
        #expect(abs(path.boundingBoxOfPath.height - 16) < 0.01)
        props.points = props.points.map { Vec($0.x, $0.y, 0.5) }; props.isPen = false
        guard case let .path(unpressured) = try #require(AnnoShapeRenderer.elements(
            for: AnnoShape(x: 0, y: 0, kind: .draw(props)), in: document).first).content else { return }
        #expect(path == unpressured)

        let context = try #require(CGContext(data: nil, width: 400, height: 180, bitsPerComponent: 8,
                                            bytesPerRow: 1600, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 100, y: 0, width: 20, height: 180))
        let target = AnnoShapeDrawing.Target(transform: .identity, pageSize: size, sample: { _ in nil },
                                             spotlightClip: nil, isFlippedContext: true)
        AnnoShapeDrawing.draw(document, in: context, target: target)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> [Int] { (0..<4).map { Int(pixels[(179 - y) * 1600 + x * 4 + $0]) } }
        #expect(zip(pixel(200, 60), [255, 239, 182, 255]).allSatisfy { abs($0 - $1) <= 1 }, "Paper pixel: \(pixel(200, 60))")
        #expect(zip(pixel(110, 60), [89, 73, 16, 255]).allSatisfy { abs($0 - $1) <= 1 }, "Text pixel: \(pixel(110, 60))")
        #expect(pixel(200, 48) == [255, 255, 255, 255])
        // Draw only the additional stroke over the first pass.
        let overlap = AnnoDocument(); overlap.add(AnnoShape(x: 40, y: 60, kind: .draw(props)))
        AnnoShapeDrawing.draw(overlap, in: context, target: target)
        #expect(pixel(200, 60)[2] < 182 && pixel(110, 60)[0] > 89)
    }

    @Test func transientSnappingGuidesNeverChangeExportPixels() {
        let size = CGSize(width: 800, height: 600)
        let editor = AnnoEditor()
        editor.viewport = AnnoViewport(imageFrame: CGRect(origin: .zero, size: size), imageSize: size)
        var props = GeoProps(); props.w = 100; props.h = 80
        let moving = AnnoShape(x: 100, y: 100, kind: .geo(props))
        let target = AnnoShape(x: 400, y: 450, kind: .geo(props))
        editor.replaceDocument(shapes: [moving, target])
        editor.pointerDown(PointerInfo(screenPoint: Vec(100, 135), pagePoint: Vec(100, 135)))
        editor.pointerMove(PointerInfo(screenPoint: Vec(295, 180), pagePoint: Vec(295, 180)))
        #expect(editor.document.shape(moving.id)?.x == 300 && !editor.snapGuides.isEmpty)

        func exported() -> Data {
            let context = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                                    bytesPerRow: 3200, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            context.translateBy(x: 0, y: 600); context.scaleBy(x: 1, y: -1)
            AnnoShapeDrawing.draw(editor.document, in: context,
                target: .init(transform: .identity, pageSize: size, sample: { _ in nil },
                              spotlightClip: nil, isFlippedContext: true))
            return Data(bytes: context.data!, count: 600 * 3200)
        }
        let withGuides = exported()
        editor.setSnapGuides([])
        #expect(withGuides == exported())
        editor.pointerUp(PointerInfo(screenPoint: Vec(295, 180), pagePoint: Vec(295, 180)))
        #expect(editor.snapGuides.isEmpty)
    }
}
