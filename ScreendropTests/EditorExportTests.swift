import AppKit
import Testing

@MainActor
struct EditorExportTests {
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
