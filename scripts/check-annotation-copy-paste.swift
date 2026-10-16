import AppKit
import Foundation

// Run with check-editor-idle-save.py: actual production model, isolated home, no windows.
@main
struct AnnotationCopyPasteChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    static func main() throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            throw Failure(description: "Run through the isolated-home harness runner")
        }
        let root = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        try check(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path == root
                  && ScreendropStorage.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(root + "/"),
                  "Foundation storage escaped the isolated home")
        let board = NSPasteboard(name: NSPasteboard.Name("annotation-copy-harness-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let source = AnnotationEditorModel()
        let target = AnnotationEditorModel()
        defer { source.releaseEditorResources(); target.releaseEditorResources() }
        source.imageSize = CGSize(width: 800, height: 600)
        target.imageSize = CGSize(width: 1600, height: 400)
        source.updateViewport(imageFrame: CGRect(origin: .zero, size: source.imageSize))
        target.updateViewport(imageFrame: CGRect(origin: .zero, size: target.imageSize))
        let shapes = [AnnoShape(x: 30, y: 40, kind: .geo(GeoProps(w: 120, h: 80, swatch: .blue))),
                      AnnoShape(x: 60, y: 70, kind: .text(TextProps(text: "Clipboard", fontSize: 32)))]
        source.engine.replaceDocument(shapes: shapes)
        source.markSaved()
        target.markSaved()
        try check(!source.copySelectedAnnotations(to: board), "No selection didn't fall back to the image Copy action")
        source.selectAllAnnotations()
        try check(source.copySelectedAnnotations(to: board), "Selected annotations weren't copied")
        try check(source.shapes == shapes && source.engine.selectedIds == Set(shapes.map(\.id)), "Copy edited the source")
        for step in 1...2 {
            try check(target.paste(from: board), "Annotation paste failed")
            let pasted = target.engine.selectedShapes
            try check(pasted.count == 2 && target.shapes.count == 2 * step, "Paste didn't select the new group")
            try check(target.selectedSwatch == .blue, "Pasted selection didn't update the inspector style")
            for (original, copy) in zip(shapes, pasted) {
                try check(original.id != copy.id && original.kind == copy.kind
                          && copy.x == original.x + Double(step * 20) && copy.y == original.y + Double(step * 20),
                          "Paste stretched annotations or didn't step the offset")
            }
        }
        let twice = target.shapes
        target.undo()
        try check(target.shapes.count == 2, "One model Undo didn't remove the whole second paste")
        target.undo()
        try check(target.shapes.isEmpty, "One model Undo didn't remove the whole first paste")
        target.redo()
        target.redo()
        try check(target.shapes == twice, "Model Redo didn't restore the pasted groups")
        print("PASS model copy fallback, cross-editor geometry/new IDs/selection, repeated offsets, one-step Undo/Redo")

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
        let bytes = bitmap.representation(using: .png, properties: [:])!
        board.clearContents()
        board.setData(bytes, forType: .png)
        let before = target.shapes
        try check(target.paste(from: board), "A new picture didn't follow the existing image paste path")
        let picture = target.shapes.last!
        try check(picture.imageProps != nil && target.engine.selectedIds == [picture.id], "Picture paste wasn't selected")
        target.undo()
        try check(target.shapes == before, "Picture paste wasn't one model Undo step")
        board.clearContents()
        board.setString("plain text", forType: .string)
        try check(!target.paste(from: board) && target.shapes == before, "Plain text reused the stale annotation payload")
        target.isCropping = true
        try check(!target.paste(from: board), "Crop mode allowed paste")
        source.engine.replaceDocument(shapes: [AnnoShape(x: 0, y: 0, kind: .image(ImageProps(assetID: "missing", w: 20, h: 20)))])
        source.selectAllAnnotations()
        let change = board.changeCount
        try check(source.copySelectedAnnotations(to: board) && source.errorMessage != nil && board.changeCount == change,
                  "Failed selection Copy fell back to finishing or destroyed the clipboard")
        print("PASS newest clipboard wins; picture fallback and one-step Undo; plain text and crop gates")
        print("All annotation copy/paste model checks passed; no windows created or shown")
    }
}
