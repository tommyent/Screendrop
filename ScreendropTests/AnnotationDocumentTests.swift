import Foundation
import Testing

@MainActor
struct AnnotationDocumentTests {
    private func withFiles(_ body: (URL, URL, URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Screendrop-SidecarTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let display = folder.appendingPathComponent("capture.png")
        let base = folder.appendingPathComponent("capture.base.png")
        try Data("display pixels".utf8).write(to: display)
        try Data("untouched pixels".utf8).write(to: base)
        try body(display, base, display.appendingPathExtension("screendrop"))
    }

    @Test func absentSidecarIsDifferentFromAnUnreadableOne() throws {
        try withFiles { _, _, sidecar in
            let document = try AnnotationDocument.load(from: sidecar)
            #expect(document == nil)
        }
    }

    @Test func currentMagnifierDocumentRoundTrips() throws {
        try withFiles { _, _, sidecar in
            let document = AnnotationDocument(shapes: [AnnoShape(x: 10, y: 20, kind: .magnifier(.init()))],
                                              background: AnnotationBackgroundSettings())
            try JSONEncoder().encode(document).write(to: sidecar)
            #expect(try AnnotationDocument.load(from: sidecar) == document)
        }
    }

    @Test func oldFreehandAndMarkedDrawDocumentsRoundTrip() throws {
        let plain = DrawProps(points: [Vec(0, 0), Vec(100, 40)], isComplete: true)
        let legacyData = try JSONEncoder().encode(plain)
        let legacyJSON = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        #expect(legacyJSON["isHighlighter"] == nil)
        let decoded = try JSONDecoder().decode(DrawProps.self, from: legacyData)
        #expect(decoded.isHighlighter == nil && AnnoShape(x: 0, y: 0, kind: .draw(decoded)).tool == .freehand)

        var marker = plain
        marker.isHighlighter = true
        marker.swatch = AnnotationStylePreset.defaultHighlighterSwatch
        marker.strokeWidth = 16
        let document = AnnotationDocument(shapes: [AnnoShape(x: 0, y: 0, kind: .draw(marker)),
                                                   AnnoShape(x: 0, y: 0, kind: .highlight(HighlightProps(w: 80, h: 40)))],
                                          background: AnnotationBackgroundSettings())
        let restored = try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document))
        #expect(restored == document && restored.shapes[0].tool == .highlighter)
        #expect(restored.shapes[0].swatch?.alpha == 0.35)
        #expect(restored.shapes[1].tool == .highlight && AnnotationTool.highlight.rawValue == "highlight")
        #expect(AnnotationTool.highlight.title == "Spotlight" && AnnotationTool.highlight.helpText.hasPrefix("Spotlight:"))
    }

    @Test func unknownShapeRefusesAndPreservesAllThreeFiles() throws {
        try withFiles { display, base, sidecar in
            let document = AnnotationDocument(shapes: [AnnoShape(x: 10, y: 20, kind: .magnifier(.init()))],
                                              background: AnnotationBackgroundSettings())
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
            var shapes = try #require(json["shapes"] as? [[String: Any]])
            shapes[0]["kind"] = ["futureMagnifier": ["_0": [:]]]
            json["shapes"] = shapes
            let original = try JSONSerialization.data(withJSONObject: json)
            try original.write(to: sidecar)
            #expect(throws: AnnotationDocumentReadError.unreadable) { try AnnotationDocument.load(from: sidecar) }
            #expect(try Data(contentsOf: display) == Data("display pixels".utf8))
            #expect(try Data(contentsOf: base) == Data("untouched pixels".utf8))
            #expect(try Data(contentsOf: sidecar) == original)
            #expect(AnnotationDocumentReadError.unreadable.localizedDescription.contains("newer Sukusho"))
        }
    }

    @Test func futureVersionCannotSilentlyDropNewFields() throws {
        try withFiles { _, _, sidecar in
            let document = AnnotationDocument(shapes: [], background: AnnotationBackgroundSettings(),
                                              version: AnnotationDocument.currentVersion + 1)
            let original = try JSONEncoder().encode(document)
            try original.write(to: sidecar)
            #expect(throws: AnnotationDocumentReadError.unreadable) { try AnnotationDocument.load(from: sidecar) }
            #expect(try Data(contentsOf: sidecar) == original)
        }
    }

    @Test(arguments: ["{", "[]", ""])
    func corruptSidecarRefusesInsteadOfOpeningAsNew(_ text: String) throws {
        try withFiles { _, _, sidecar in
            try Data(text.utf8).write(to: sidecar)
            #expect(throws: AnnotationDocumentReadError.unreadable) { try AnnotationDocument.load(from: sidecar) }
        }
    }

    @Test func legacyV1StillOpensAsFlattenedImage() throws {
        try withFiles { _, _, sidecar in
            try Data(#"{"version":1,"annotations":[]}"#.utf8).write(to: sidecar)
            let document = try #require(try AnnotationDocument.load(from: sidecar))
            #expect(document.version == 1 && document.shapes.isEmpty)
        }
    }
}
