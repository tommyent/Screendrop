import AppKit
import Foundation

// Compile with Engine/*.swift, Annotation{Tool,Swatch,PresetStore,Metrics}.swift,
// AnnoRedactionPreviewCache, BoundedCGImageCache and AnnotationRedactionImageProcessor.
// No app, window, defaults write or capture is needed.
@main
struct EditorFillChecks {
    static func main() throws {
        let legacy = Data("""
        {"selectedToolRawValue":"filledRectangle","swatchID":"red","strokeWidth":4,
         "redactionDensity":0.55,"textFontName":"pro","textFontSize":48,
         "textIsBold":true,"textIsItalic":false,"textIsUnderline":false,"textAlignmentRawValue":0}
        """.utf8)
        let preset = try JSONDecoder().decode(AnnotationStylePreset.self, from: legacy)
        precondition(preset.selectedTool == .rectangle && preset.geoFill == .solid)
        precondition(!AnnotationTool.paletteTools.contains(.filledRectangle))
        for tool in [AnnotationTool.rectangle, .ellipse] {
            for fill in AnnoFillStyle.allCases {
                let editor = AnnoEditor()
                editor.viewport = AnnoViewport(imageFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
                                               imageSize: CGSize(width: 400, height: 300))
                editor.tool = tool
                editor.currentGeoFill = fill
                let start = Vec(50, 50), end = Vec(200, 180)
                editor.pointerDown(PointerInfo(screenPoint: start, pagePoint: start))
                editor.pointerMove(PointerInfo(screenPoint: end, pagePoint: end))
                editor.pointerUp(PointerInfo(screenPoint: end, pagePoint: end))
                guard case let .geo(props) = editor.shapes.first?.kind else {
                    preconditionFailure("No geometry created")
                }
                precondition(props.fill == fill && props.geo == (tool == .ellipse ? .ellipse : .rectangle))
                let original = editor.shapes
                editor.applyStyleToSelection { shape in
                    guard case var .geo(props) = shape.kind else { return }
                    props.fill = fill == .none ? .solid : .none
                    shape.kind = .geo(props)
                }
                precondition(editor.shapes != original)
                editor.undo()
                precondition(editor.shapes == original)
                var saved = AnnotationStylePreset()
                saved.selectedToolRawValue = tool.rawValue
                saved.geoFillRawValue = fill.rawValue
                let restored = try JSONDecoder().decode(AnnotationStylePreset.self, from: JSONEncoder().encode(saved))
                precondition(restored.selectedTool == tool && restored.geoFill == fill)
            }
        }
        print("PASS: legacy fill preset, one Rectangle, rectangle/ellipse Outline and Solid, style undo and preset round-trip")
    }
}
