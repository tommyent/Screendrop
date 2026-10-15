import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Run with check-editor-idle-save.py against the actual app sources and an isolated home.
@main
struct ColourOpacityChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }

    static func modelChecks() throws {
        let model = AnnotationEditorModel()
        defer { model.releaseEditorResources() }
        let before: [AnnoShape] = [
            AnnoShape(x: 10, y: 10, opacity: 0.7, kind: .geo(GeoProps(swatch: .red.withAlpha(0.8)))),
            AnnoShape(x: 20, y: 20, kind: .draw(DrawProps(swatch: .blue.withAlpha(0.6)))),
            AnnoShape(x: 30, y: 30, kind: .arrow(ArrowProps(swatch: .green))),
            AnnoShape(x: 40, y: 40, kind: .text(TextProps(swatch: .yellow))),
            AnnoShape(x: 50, y: 50, kind: .numbered(NumberedProps(swatch: .purple))),
            AnnoShape(x: 60, y: 60, kind: .magnifier(MagnifierProps(swatch: .orange))),
            AnnoShape(x: 70, y: 70, kind: .redaction(RedactionProps())),
            AnnoShape(x: 80, y: 80, kind: .highlight(HighlightProps())),
        ]
        model.engine.replaceDocument(shapes: before)
        model.engine.selectedIds = Set(before.map(\.id))
        model.markSaved()
        let background = model.backgroundSettings
        model.setInspectorEditing(true)
        for alpha in [CGFloat(0.75), 0.5, 0.35] { model.setSwatchAlpha(alpha) }
        model.setInspectorEditing(false) // Also used by popover dismissal cleanup.
        let after = model.shapes
        for (original, changed) in zip(before, after) {
            try check(original.opacity == changed.opacity, "Colour alpha changed whole-object opacity")
            if let swatch = original.swatch {
                try check(changed.swatch == swatch.withAlpha(0.35), "Mixed-colour selection lost RGB or alpha")
            } else {
                try check(original == changed, "Opacity changed an annotation without a swatch")
            }
        }
        try check(model.backgroundSettings == background, "Opacity changed the background")
        try check(model.selectedSwatch.alpha == 0.35 && model.engine.currentSwatch == model.selectedSwatch,
                  "Current tool alpha did not follow the slider")
        try check(AnnotationPresetStore.load().swatch == model.selectedSwatch, "Remembered style lost alpha")
        model.undo()
        try check(model.shapes == before, "One Undo did not restore every prior alpha")
        try check(model.selectedSwatch == before[0].swatch, "Mixed-selection Undo left the displayed alpha stale")
        model.redo()
        try check(model.shapes == after, "Redo did not restore the opacity drag")
        for invalid in [CGFloat.nan, .infinity, -.infinity] { model.setSwatchAlpha(invalid) }
        try check(model.shapes == after, "Non-finite opacity changed shapes")

        model.engine.selectedIds = [before[0].id]
        model.setSwatchAlpha(0.2)
        model.undo()
        try check(model.selectedSwatch == after[0].swatch, "Undo left the displayed alpha stale")
        model.redo()
        try check(model.selectedSwatch.alpha == 0.2, "Redo left the displayed alpha stale")
        model.setSwatchAlpha(-2)
        try check(model.shapes[0].swatch?.alpha == 0 && model.isColorStyleAvailable,
                  "Zero alpha disabled the colour control or failed to clamp")
        model.setSwatchAlpha(2)
        try check(model.shapes[0].swatch?.alpha == 1, "Alpha above one was not clamped")
        model.setSwatchAlpha(0.35)
        model.setSwatch(.blue.withAlpha(model.selectedSwatch.alpha))
        try check(model.shapes[0].swatch == .blue.withAlpha(0.35), "Palette selection lost alpha")

        model.engine.selectedIds = []
        model.imageSize = CGSize(width: 200, height: 100)
        model.updateViewport(imageFrame: CGRect(origin: .zero, size: model.imageSize))
        model.selectTool(.freehand)
        let count = model.shapes.count
        model.engine.pointerDown(PointerInfo(screenPoint: Vec(10, 10), pagePoint: Vec(10, 10), command: true))
        model.engine.pointerMove(PointerInfo(screenPoint: Vec(150, 50), pagePoint: Vec(150, 50)))
        model.engine.pointerUp(PointerInfo(screenPoint: Vec(150, 50), pagePoint: Vec(150, 50)))
        try check(model.shapes.count == count + 1 && model.shapes.last?.swatch == .blue.withAlpha(0.35),
                  "New strokes lost the chosen alpha")
        print("PASS mixed RGB, six colour-bearing shapes, unchanged object/background opacity, one-step Undo/Redo, readout sync, finite bounds, palette/preset/new stroke alpha")
    }

    static func exportChecks(in folder: URL) throws {
        let size = CGSize(width: 200, height: 100)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
                                bytesPerRow: 800, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Opacity 012" as NSString).draw(at: CGPoint(x: 20, y: 40), withAttributes: [
            .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let sourceImage = context.makeImage()!
        let source = folder.appendingPathComponent("text.png")
        let writer = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, sourceImage, nil)
        try check(CGImageDestinationFinalize(writer), "Cannot encode synthetic text")

        func render(_ alpha: CGFloat) throws -> [UInt8] {
            let destination = folder.appendingPathComponent("alpha-\(alpha).png")
            let stroke = AnnoShape(x: 50, y: 50, kind: .draw(DrawProps(
                points: [Vec(0, 0), Vec(100, 0)], isComplete: true,
                swatch: .yellow.withAlpha(alpha), strokeWidth: 32
            )))
            try check(AnnotationCanvasExpansion(shapes: [stroke], imageSize: size, pixelsPerPoint: 1).isEmpty,
                      "Synthetic stroke exceeds its source image")
            try AnnotationRenderer.render(sourceURL: source, shapes: [stroke], bindings: [],
                                          destinationURL: destination, contentType: .png)
            guard let input = CGImageSourceCreateWithURL(destination as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(input, 0, nil) else {
                throw Failure(description: "Cannot decode export")
            }
            try check(image.width == 200 && image.height == 100, "Unexpected export size: \(image.width)×\(image.height)")
            context.clear(CGRect(origin: .zero, size: size))
            context.draw(image, in: CGRect(origin: .zero, size: size))
            return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 80000))
        }
        let clear = try render(0), translucent = try render(0.35), opaque = try render(1)
        var changedText = 0, changedPaper = 0
        for index in stride(from: 0, to: clear.count, by: 4) {
            if abs(Int(opaque[index + 2]) - Int(clear[index + 2])) > 30 {
                for channel in 0..<3 {
                    let expected = Double(clear[index + channel]) * 0.65 + Double(opaque[index + channel]) * 0.35
                    try check(abs(Double(translucent[index + channel]) - expected) < 4,
                              "Translucent export did not use normal colour-alpha compositing")
                }
                if clear[index] < 30 { changedText += 1 }
                if clear[index] > 245 { changedPaper += 1 }
            }
        }
        try check(changedText > 100 && changedPaper > 1000, "Export check missed text or paper beneath the stroke")
        context.clear(CGRect(origin: .zero, size: size))
        context.draw(sourceImage, in: CGRect(origin: .zero, size: size))
        let sourcePixels = Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 80000))
        try check(clear == sourcePixels, "Zero-alpha stroke changed the source pixels")
        print("PASS real PNG export over synthetic text: 0% unchanged, 35% expected compositing on text and paper, 100% opaque control")
    }

    static func main() throws {
        setbuf(stdout, nil)
        guard let root = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            throw Failure(description: "Run through the isolated-home harness runner")
        }
        let home = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        try check(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path == home
                  && ScreendropStorage.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(home + "/"),
                  "Foundation storage escaped the isolated home")
        try modelChecks()
        try exportChecks(in: URL(fileURLWithPath: root))
        print("All colour-opacity model/export checks passed; no windows created or shown")
    }
}
