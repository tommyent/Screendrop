// swiftc -parse-as-library -default-isolation MainActor scripts/check-editor-pixels.swift \
//   Screendrop/{PixelInspection,PixelProbe,ScreenshotImageLoader}.swift -o /tmp/check-editor-pixels
import AppKit
import ImageIO

// The probe's only unrelated dependency; no app, defaults or Library services.
enum AnnotationCanvasExpansion {
    static func pixelsPerPoint(of source: CGImageSource) -> CGFloat {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return max(1, CGFloat((properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72) / 72)
    }
}

@main struct EditorPixelChecks {
    static func main() async throws {
        for name in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let space = CGColorSpace(name: name)!
            let context = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8,
                bytesPerRow: 12, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(colorSpace: space, components: [0.8, 0.3, 0.2, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
            let source = context.makeImage()!
            let buffer = PixelBuffer(image: source)!
            precondition(buffer.width == 3 && buffer.height == 2 && CFEqual(buffer.image.colorSpace, space))
            let reference = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8,
                bytesPerRow: 12, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            reference.draw(source, in: CGRect(x: 0, y: 0, width: 3, height: 2))
            let bytes = reference.data!.assumingMemoryBound(to: UInt8.self)
            let color = buffer.color(x: 0, y: 0)!
            precondition(abs(Int(color.red) - Int(bytes[0])) <= 1
                && abs(Int(color.green) - Int(bytes[1])) <= 1 && abs(Int(color.blue) - Int(bytes[2])) <= 1)
            precondition(buffer.color(x: -1, y: 0) == nil && buffer.color(x: 3, y: 0) == nil)
            precondition(buffer.span(x: 1, y: 1)!.horizontal == 0...2)
        }

        // Distinct rows/columns detect a flip or stride mistake in the shared image.
        let bytes = Data([255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255])
        let source = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
        let sharedImage = PixelBuffer(image: source)!.image
        let roundTrip = PixelBuffer(image: sharedImage)!
        precondition(roundTrip.color(x: 0, y: 0) == PixelColor(red: 255, green: 0, blue: 0))
        precondition(roundTrip.color(x: 1, y: 1) == PixelColor(red: 255, green: 255, blue: 255))
        precondition(roundTrip.span(x: 0, y: 0)!.vertical == 0...0)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pixel-check-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, source, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        let probe = PixelProbe()
        await probe.load(url, preview: source)
        precondition(abs(probe.pixelsPerPoint - 2) < 0.01 && probe.buffer != nil)
        precondition(probe.image(for: source) === probe.buffer?.image)
        precondition(probe.image(for: sharedImage) == nil)
        probe.release()
        precondition(probe.buffer == nil && probe.image(for: source) == nil)

        let reload = Task { await probe.load(url, preview: source) }
        await Task.yield()
        reload.cancel()
        probe.release()
        await reload.value
        precondition(probe.buffer == nil)
        print("PASS: sRGB/P3 readout and profile; image lifetime, rows, stride and ruler; probe load/release/cancellation")
    }
}
