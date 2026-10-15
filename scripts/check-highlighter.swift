import AppKit
import CoreText
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct HighlighterChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }

    static let size = CGSize(width: 480, height: 160)
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func context() throws -> CGContext {
        guard let context = CGContext(data: nil, width: 480, height: 160, bitsPerComponent: 8,
                                      bytesPerRow: 1920, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "Cannot allocate fixture bitmap")
        }
        return context
    }

    static func fixture(_ source: URL) throws -> CGImage {
        let context = try context()
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
        context.textPosition = CGPoint(x: 50, y: 65)
        let text = NSAttributedString(string: "Synthetic marker text", attributes: [
            .font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.black,
        ])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        guard let image = context.makeImage(),
              let writer = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure(description: "Cannot encode fixture") }
        CGImageDestinationAddImage(writer, image, nil)
        try check(CGImageDestinationFinalize(writer), "Fixture PNG failed")
        return image
    }

    static func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try context()
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 160 * 1920))
    }

    static func exportedPixels(source: URL, shapes: [AnnoShape]) throws -> [UInt8] {
        let destination = source.deletingLastPathComponent().appendingPathComponent("export.png")
        try AnnotationRenderer.render(sourceURL: source, shapes: shapes, bindings: [],
                                      destinationURL: destination, contentType: .png)
        guard let reader = CGImageSourceCreateWithURL(destination as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(reader, 0, nil) else {
            throw Failure(description: "Cannot read actual exported PNG")
        }
        try check(image.width == 480 && image.height == 160, "Export dimensions changed")
        return try pixels(image)
    }

    static func exports(_ source: URL, image: CGImage) throws {
        let base = try exportedPixels(source: source, shapes: [])
        var props = ArrowProps(end: Vec(390, 0), arrowheadEnd: .none,
                               swatch: AnnotationStylePreset.defaultHighlighterSwatch, strokeWidth: 16, isHighlighter: true)
        let marker = AnnoShape(x: 40, y: 80, kind: .arrow(props))
        let marked = try exportedPixels(source: source, shapes: [marker])
        let overlapping = try exportedPixels(source: source, shapes: [marker, AnnoShape(x: 40, y: 80, kind: .arrow(props))])
        let legacy = AnnoShape(x: 40, y: 80, kind: .draw(DrawProps(points: [Vec(0, 0), Vec(390, 0)],
                               isComplete: true, isHighlighter: true, swatch: props.swatch, strokeWidth: 16)))
        let legacyPixels = try exportedPixels(source: source, shapes: [legacy])
        var darkText = 0, whitePaper = 0
        for index in stride(from: 0, to: marked.count, by: 4) {
            let x = (index / 4) % 480, y = index / 1920
            // Interior pixels exclude the glyph and marker's antialiased edges.
            guard (50..<400).contains(x), (75..<85).contains(y) else { continue }
            try check(zip(marked[index..<(index + 4)], legacyPixels[index..<(index + 4)]).allSatisfy {
                abs(Int($0) - Int($1)) <= 1
            }, "Straight/legacy marker interior pixels differ")
            if base[index] == 0 && base[index + 1] == 0 && base[index + 2] == 0 {
                try check(abs(Int(marked[index]) - 89) <= 2 && abs(Int(marked[index + 1]) - 73) <= 2
                          && abs(Int(marked[index + 2]) - 16) <= 2,
                          "Normal-blend text pixel mismatch at \(x),\(y): \(Array(marked[index..<(index + 4)]))")
                try check(overlapping[index] > marked[index], "Overlapping markers did not compound normally")
                darkText += 1
            }
            if base[index] == 255 && marked[index + 2] >= 180 && marked[index + 2] <= 184 {
                try check(abs(Int(marked[index + 1]) - 239) <= 2, "Normal-blend paper pixel mismatch")
                whitePaper += 1
            }
        }
        try check(darkText > 20 && whitePaper > 1000, "Marker missed synthetic text or white paper")

        let canvas = try context()
        canvas.draw(image, in: CGRect(origin: .zero, size: size))
        let document = AnnoDocument(); document.add(marker)
        AnnoShapeDrawing.draw(document, in: canvas, target: .init(
            transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 160),
            pageSize: size, sample: { _ in nil }, spotlightClip: nil, isFlippedContext: false))
        let canvasPixels = Array(UnsafeBufferPointer(start: canvas.data!.assumingMemoryBound(to: UInt8.self), count: marked.count))
        try check(zip(canvasPixels, marked).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "Shared canvas/export pixel mismatch")
        for alpha in [CGFloat(0), 1] {
            props.swatch = AnnotationSwatch("yellow", title: "Yellow", red: 1, green: 0.82, blue: 0.18, alpha: alpha)
            let output = try exportedPixels(source: source, shapes: [AnnoShape(x: 40, y: 80, kind: .arrow(props))])
            if alpha == 0 {
                try check(output == base, "Zero-alpha marker changed pixels")
            } else {
                let center = (80 * 480 + 240) * 4
                try check(zip(output[center..<(center + 4)], [255, 209, 46, 255]).allSatisfy {
                    abs(Int($0) - $1) <= 1
                }, "Opaque marker did not paint solid yellow")
            }
        }
        print("PASS: straight and legacy PNG exports over synthetic text; normal 35% alpha, overlap, 0%/100%, shared canvas-drawing parity")
    }

    static func modelStyles(_ source: URL) throws {
        AnnotationPresetStore.reset()
        let dismiss = Environment(\.dismiss).wrappedValue
        let model = AnnotationEditorModel()
        model.load(url: source, dismiss: dismiss)
        model.selectTool(.freehand); model.setSwatch(.blue); model.setStrokeWidth(6)
        model.setHandDrawn(true)
        model.selectTool(.highlighter)
        try check(model.selectedSwatch == AnnotationStylePreset.defaultHighlighterSwatch && model.strokeWidth == 16,
                  "Marker defaults missing")
        let custom = AnnotationSwatch("custom-marker", title: "Custom", red: 0.55, green: 0.3, blue: 0.95, alpha: 0.48)
        model.setSwatch(custom); model.setStrokeWidth(24)
        model.selectTool(.freehand)
        try check(model.selectedSwatch == .blue && model.strokeWidth == 6, "Marker polluted pen style")
        model.setSwatch(.green); model.setStrokeWidth(8)
        model.selectTool(.highlighter)
        try check(model.selectedSwatch == custom && model.strokeWidth == 24, "Marker adjustments were lost")
        let preset = AnnotationPresetStore.load()
        try check(preset.swatch == .green && preset.strokeWidth == 8 && preset.highlighterSwatch?.annotationSwatch == custom
                  && preset.highlighterStrokeWidth == 24, "Separate preset styles did not persist")

        let reopened = AnnotationEditorModel(); reopened.load(url: source, dismiss: dismiss)
        reopened.selectTool(.highlighter)
        try check(reopened.selectedSwatch == custom && reopened.strokeWidth == 24, "Reopened marker style was lost")
        reopened.selectTool(.freehand)
        try check(reopened.selectedSwatch == .green && reopened.strokeWidth == 8, "Reopened pen style was lost")

        let ordinary = AnnoShape(x: 40, y: 30, kind: .draw(DrawProps(points: [Vec(0, 0), Vec(150, 0)],
                                  isComplete: true, swatch: .blue, strokeWidth: reopened.engine.pageStrokeWidth(6))))
        reopened.selectTool(.highlighter)
        reopened.engine.replaceDocument(shapes: [ordinary]); reopened.engine.selectedIds = [ordinary.id]
        let frame = CGRect(origin: .zero, size: size)
        reopened.endInteraction(at: .zero, imageFrame: frame, boundaryFrame: frame)
        try check(reopened.selectedSwatch == .blue && reopened.strokeWidth == 6, "Selection did not expose pen style")
        try check(reopened.engine.currentSwatch == custom && reopened.engine.currentStrokeWidth == 24,
                  "Selecting pen changed the armed marker style")
        reopened.engine.pointerDown(.init(screenPoint: Vec(40, 120), pagePoint: Vec(40, 120)))
        reopened.engine.pointerMove(.init(screenPoint: Vec(300, 120), pagePoint: Vec(300, 120)))
        reopened.endInteraction(at: CGPoint(x: 300, y: 120), imageFrame: frame, boundaryFrame: frame)
        try check(reopened.shapes.last?.tool == .highlighter && reopened.shapes.last?.swatch == custom
                  && reopened.shapes.last?.strokeWidth == reopened.engine.pageStrokeWidth(24), "Next marker used pen style")
        try check(reopened.shapes.last?.arrowProps?.dash == .solid && reopened.handDrawn,
                  "Marker inherited the hand-drawn style or overwrote it")
        reopened.setSwatch(AnnotationStylePreset.defaultHighlighterSwatch)
        try check(reopened.shapes.last?.swatch?.alpha == 0.35, "Marker recolour lost alpha")
        reopened.undo()
        try check(reopened.shapes.last?.swatch == custom && reopened.selectedSwatch == custom,
                  "Undo did not restore marker colour alpha and displayed style")
        reopened.escapeSelectionOrDisarm(); reopened.escapeSelectionOrDisarm(); reopened.selectTool(.freehand)
        try check(reopened.selectedSwatch == .blue && reopened.strokeWidth == 6, "Escape lost the selected pen style")
        let marker = reopened.shapes.last!
        let line = AnnoShape(x: 40, y: 50, kind: .arrow(ArrowProps(arrowheadEnd: .none)))
        reopened.engine.replaceDocument(shapes: [marker, line]); reopened.engine.selectedIds = [marker.id, line.id]
        reopened.setHandDrawn(true)
        try check(reopened.engine.document.shape(marker.id)?.arrowProps?.dash == .solid
                  && reopened.engine.document.shape(line.id)?.arrowProps?.dash == .draw,
                  "Mixed selection bent the marker with the line's hand-drawn style")
        print("PASS: actual model defaults, independent pen/marker styles, preset reload, selection, next stroke, alpha Undo, Escape and mixed hand-drawn styles")
    }

    static func main() throws {
        guard let root = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            throw Failure(description: "Run through check-highlighter.py with an isolated home")
        }
        let isolated = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        try check(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path == isolated
                  && ScreendropStorage.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(isolated + "/"),
                  "Foundation storage escaped isolated home")
        NSApplication.shared.setActivationPolicy(.prohibited)
        let source = URL(fileURLWithPath: root).appendingPathComponent("synthetic-text.png")
        let image = try fixture(source)
        try exports(source, image: image)
        try modelStyles(source)
    }
}
