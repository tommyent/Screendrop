import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Pasted pictures (sd-eec): drawn upright in their box on the canvas and in the export, and
/// carried by shapes as a reference only.
@MainActor
struct PastedImageTests {
    /// A 4x4 PNG whose top two rows are red and bottom two blue.
    static func bandedPNG() -> Data {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CG is y-up: the top of the picture is y 2...4.
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 2, width: 4, height: 2))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Draws one pasted picture at page (20, 30), 40x20, into a 100x100 page, either as the
    /// flipped canvas does or as the y-up export does, and returns the bitmap.
    static func drawn(flippedCanvas: Bool) -> (Data, Int) {
        let asset = AnnoImageAsset(data: bandedPNG())!
        let document = AnnoDocument()
        document.restore(AnnoDocument.Snapshot(
            shapes: [AnnoShape(x: 20, y: 30, kind: .image(ImageProps(assetID: "a", w: 40, h: 20)))],
            bindings: []))
        let bytesPerRow = 400
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let size = CGSize(width: 100, height: 100)
        var target = AnnoShapeDrawing.Target(transform: .identity, pageSize: size, sample: { _ in nil },
                                             spotlightClip: nil, isFlippedContext: flippedCanvas)
        if flippedCanvas {
            context.translateBy(x: 0, y: 100); context.scaleBy(x: 1, y: -1)
        } else {
            target.transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 100)
        }
        target.images = ["a": asset.image]
        AnnoShapeDrawing.draw(document, in: context, target: target)
        return (Data(bytes: context.data!, count: 100 * bytesPerRow), bytesPerRow)
    }

    /// RGB at page (x, y): a bitmap's first row in memory is the page's top row.
    static func rgb(_ bitmap: (Data, Int), x: Int, y: Int) -> [UInt8] {
        let offset = y * bitmap.1 + x * 4
        return [bitmap.0[offset], bitmap.0[offset + 1], bitmap.0[offset + 2]]
    }

    @Test(arguments: [true, false])
    func drawsUprightInItsBox(flippedCanvas: Bool) {
        let bitmap = Self.drawn(flippedCanvas: flippedCanvas)
        // Dominant channels: the PNG round trip shifts exact values slightly (red reads 255, 38, 0).
        let top = Self.rgb(bitmap, x: 40, y: 33), bottom = Self.rgb(bitmap, x: 40, y: 46)
        #expect(top[0] > 200 && top[2] < 60, "top of the picture is red: \(top)")
        #expect(bottom[2] > 200 && bottom[0] < 60, "bottom of the picture is blue: \(bottom)")
        #expect(Self.rgb(bitmap, x: 10, y: 10) == [255, 255, 255], "nothing outside its box")
        #expect(Self.rgb(bitmap, x: 61, y: 40) == [255, 255, 255], "nothing past its right edge")
    }

    @Test func shapesCarryOnlyTheReference() throws {
        let shape = AnnoShape(x: 1, y: 2, kind: .image(ImageProps(assetID: "asset-1", w: 300, h: 200)))
        let data = try JSONEncoder().encode(shape)
        #expect(try JSONDecoder().decode(AnnoShape.self, from: data) == shape)
        #expect(data.count < 300, "a shape is a few bytes, not the picture")
        #expect(shape.isFilled && shape.swatch == nil && shape.strokeWidth == 0)
    }

    @Test func undecodableBytesAreNoAsset() {
        #expect(AnnoImageAsset(data: Data("not an image".utf8)) == nil)
    }

    // MARK: Storage

    @Test func sidecarKeepsThePixelsOfShownPicturesOnly() throws {
        let png = Self.bandedPNG()
        let assets = ["shown": AnnoImageAsset(data: png)!, "undone": AnnoImageAsset(data: png)!]
        let shapes = [AnnoShape(x: 0, y: 0, kind: .image(ImageProps(assetID: "shown", w: 4, h: 4)))]
        let images = AnnotationDocument.images(for: shapes, from: assets)
        #expect(Array(images.keys) == ["shown"] && images["shown"] == png)

        let document = AnnotationDocument(shapes: shapes, background: AnnotationBackgroundSettings(), images: images)
        let reopened = try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document))
        #expect(reopened.shapes == shapes && reopened.images == images)
        // What the editor does on load: the reopened shape finds its pixels again.
        let loaded = reopened.images.compactMapValues(AnnoImageAsset.init(data:))
        #expect(loaded["shown"]?.image.width == 4)
    }

    @Test func sidecarsFromBeforePastingHaveNoImages() throws {
        let document = AnnotationDocument(shapes: [], background: AnnotationBackgroundSettings())
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as! [String: Any]
        json.removeValue(forKey: "images")
        let old = try JSONDecoder().decode(AnnotationDocument.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.images.isEmpty)
    }
}
