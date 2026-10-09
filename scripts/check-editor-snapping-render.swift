import AppKit

// Compile with the production engine/dependencies from check-editor-fill.swift. No window or app.
@main
struct EditorSnappingRenderChecks {
    static let size = CGSize(width: 800, height: 600)

    static func bitmap() -> CGContext {
        let context = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                                bytesPerRow: 3200, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: 600); context.scaleBy(x: 1, y: -1)
        return context
    }

    static func bytes(_ context: CGContext) -> Data { Data(bytes: context.data!, count: 600 * 3200) }

    static func canvas(_ editor: AnnoEditor) -> CGContext {
        let context = bitmap()
        let view = AnnoCanvasNSView(frame: CGRect(origin: .zero, size: size))
        view.appearance = NSAppearance(named: .aqua)
        view.configure(editor: editor, sourceImage: nil, fullResolutionSource: nil,
                       imageFrame: view.bounds, imageSize: size, spotlightClip: nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        view.releaseResources()
        return context
    }

    static func exported(_ editor: AnnoEditor) -> Data {
        let context = bitmap()
        AnnoShapeDrawing.draw(editor.document, in: context,
                              target: .init(transform: .identity, pageSize: size, sample: { _ in nil },
                                            spotlightClip: nil, isFlippedContext: true))
        return bytes(context)
    }

    static func main() throws {
        let editor = AnnoEditor()
        editor.viewport = AnnoViewport(imageFrame: CGRect(origin: .zero, size: size), imageSize: size)
        var props = GeoProps(); props.w = 100; props.h = 80
        let moving = AnnoShape(x: 100, y: 100, kind: .geo(props))
        let target = AnnoShape(x: 400, y: 450, kind: .geo(props))
        editor.replaceDocument(shapes: [moving, target])
        let start = Vec(100, 135), end = Vec(295, 180)
        editor.pointerDown(PointerInfo(screenPoint: start, pagePoint: start))
        editor.pointerMove(PointerInfo(screenPoint: end, pagePoint: end))
        precondition(editor.document.shape(moving.id)!.x == 300 && !editor.snapGuides.isEmpty)
        let shown = canvas(editor), withGuides = bytes(shown), exportWithGuides = exported(editor)
        editor.setSnapGuides([])
        let withoutGuides = bytes(canvas(editor))
        precondition(withGuides != withoutGuides, "The actual canvas renderer must display guides")
        let differing = (250..<420).filter { row in
            // The bitmap is y-up; inspect the unobstructed part of the vertical guide in view space.
            let offset = (599 - row) * 3200 + 400 * 4
            return withGuides[offset..<(offset + 4)] != withoutGuides[offset..<(offset + 4)]
        }.count
        precondition(differing > 40 && differing < 130, "The guide must have both strokes and gaps")
        precondition(exportWithGuides == exported(editor), "Transient guides must never change export pixels")
        editor.pointerUp(PointerInfo(screenPoint: end, pagePoint: end))
        precondition(editor.snapGuides.isEmpty)

        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = NSBitmapImageRep(cgImage: shown.makeImage()!).representation(using: .png, properties: [:])!
        try png.write(to: directory.appendingPathComponent("snap-guides.png"))
        print("PASS: actual windowless canvas draws dashed guides; export pixels identical with/without guide state; release clears guides")
    }
}
