import AppKit
import Foundation
import Testing

@MainActor
struct ColourOpacityTests {
    @Test func alphaOnlyChangesAlphaAndClampsFiniteInput() {
        let swatch = AnnotationSwatch.blue.withAlpha(0.35)
        #expect(swatch.hasSameHue(as: .blue))
        #expect(swatch.id == AnnotationSwatch.blue.id && swatch.title == AnnotationSwatch.blue.title)
        #expect(swatch.nsColor.alphaComponent == 0.35)
        #expect(swatch.withAlpha(-1).alpha == 0)
        #expect(swatch.withAlpha(2).alpha == 1)
        for invalid in [CGFloat.nan, .infinity, -.infinity] {
            #expect(swatch.withAlpha(invalid) == swatch)
        }
    }

    @Test func paletteHueRetainsAlphaAndDoesNotBecomeCustom() {
        let translucent = AnnotationSwatch.red.withAlpha(0.35)
        let chosen = AnnotationSwatch.blue.withAlpha(translucent.alpha)
        #expect(chosen.alpha == 0.35 && chosen.hasSameHue(as: .blue))
        #expect(!chosen.hasSameHue(as: .red))
        #expect(AnnotationSwatch.allCases.contains { chosen.hasSameHue(as: $0) })
        let custom = AnnotationSwatch("custom", title: "Custom", red: 0.18, green: 0.48, blue: 1, alpha: 0)
        #expect(custom.hasSameHue(as: .blue))
        let other = AnnotationSwatch("other", title: "Custom", red: 0.3, green: 0.4, blue: 0.5)
        #expect(!AnnotationSwatch.allCases.contains { other.hasSameHue(as: $0) })
    }

    @Test(arguments: [CGFloat(0), 0.35, 1])
    func alphaRoundTripsThroughSidecarAndPreset(alpha: CGFloat) throws {
        let swatch = AnnotationSwatch.yellow.withAlpha(alpha)
        let shape = AnnoShape(x: 10, y: 20, kind: .draw(DrawProps(swatch: swatch)))
        let document = AnnotationDocument(shapes: [shape], background: AnnotationBackgroundSettings())
        #expect(try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document)) == document)
        var preset = AnnotationStylePreset()
        preset.swatchID = swatch.id
        preset.customSwatch = CodableSwatch(swatch: swatch)
        #expect(try JSONDecoder().decode(AnnotationStylePreset.self, from: JSONEncoder().encode(preset)).swatch == swatch)
    }

    @Test func legacySwatchWithoutAlphaStaysOpaque() throws {
        let data = Data(#"{"id":"red","title":"Red","red":0.97,"green":0.22,"blue":0.2}"#.utf8)
        #expect(try JSONDecoder().decode(AnnotationSwatch.self, from: data) == .red)
    }
}
