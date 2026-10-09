// Ported from scripts/check-editor-fill.swift; production model/cache code, no UI.
import AppKit
import Testing
import Foundation

@MainActor
@Suite
struct EditorFillTests {
    @Test static func fill() throws {
        let legacy = Data("""
        {"selectedToolRawValue":"filledRectangle","swatchID":"red","strokeWidth":4,
         "redactionDensity":0.55,"textFontName":"pro","textFontSize":48,
         "textIsBold":true,"textIsItalic":false,"textIsUnderline":false,"textAlignmentRawValue":0}
        """.utf8)
        let preset = try JSONDecoder().decode(AnnotationStylePreset.self, from: legacy)
        #expect(preset.selectedTool == .rectangle && preset.geoFill == .solid)
        #expect(!AnnotationTool.paletteTools.contains(.filledRectangle))
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
                    Issue.record("No geometry created"); return
                }
                #expect(props.fill == fill && props.geo == (tool == .ellipse ? .ellipse : .rectangle))
                let original = editor.shapes
                editor.applyStyleToSelection { shape in
                    guard case var .geo(props) = shape.kind else { return }
                    props.fill = fill == .none ? .solid : .none
                    shape.kind = .geo(props)
                }
                #expect(editor.shapes != original)
                editor.undo()
                #expect(editor.shapes == original)
                var saved = AnnotationStylePreset()
                saved.selectedToolRawValue = tool.rawValue
                saved.geoFillRawValue = fill.rawValue
                let restored = try JSONDecoder().decode(AnnotationStylePreset.self, from: JSONEncoder().encode(saved))
                #expect(restored.selectedTool == tool && restored.geoFill == fill)
            }
        }
        print("PASS: legacy fill preset, one Rectangle, rectangle/ellipse Outline and Solid, style undo and preset round-trip")
    }
}
