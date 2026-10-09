// swiftc -parse-as-library -default-isolation MainActor scripts/check-capture-pipeline.swift \
//   Screendrop/{ScreenshotManager,ScreenshotClipboardImage,CaptureLibraryThumbnails,CaptureThumbnailDiskCache}.swift -o /tmp/check-capture-pipeline
import AppKit
import ImageIO

// Unrelated capture/display and Library metadata dependencies. No app launch,
// screen capture, preferences, Library or general pasteboard access.
enum NotchBarTrimmer {
    static func trimmingEmptyMenuBar(_ image: CGImage, displayID: CGDirectDisplayID) -> CGImage { image }
}
enum ScreenshotFileNaming {
    static func fileName(extension ext: String) -> String { "check.\(ext)" }
}
nonisolated struct CaptureLibraryItem: Sendable {
    let fileURL: URL
    let isVideo = false
    let thumbnailKey: String
}

@main struct CapturePipelineChecks {
    static func pixels(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: context.bytesPerRow * context.height)
    }

    static func main() async throws {
        let context = CGContext(data: nil, width: 800, height: 1600, bitsPerComponent: 8,
            bytesPerRow: 3200, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 1600))
        let image = context.makeImage()!
        async let first = ScreenshotManager.shared.writeCapture(image, scale: 2)
        async let second = ScreenshotManager.shared.writeCapture(image, scale: 1)
        let (a, b) = await (first, second)
        guard let a, let b else { preconditionFailure("PNG encode failed") }
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        precondition(a != b, "Overlapping encodes must not overwrite one another")
        for (url, dpi) in [(a, 144.0), (b, 72.0)] {
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
            precondition(abs((properties[kCGImagePropertyDPIWidth] as! NSNumber).doubleValue - dpi) < 0.01)
            let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            precondition(decoded.width == 800 && decoded.height == 1600)
            precondition(pixels(decoded) == pixels(image))
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let thumbnails = CaptureLibraryThumbnails(disk: CaptureThumbnailDiskCache(directory: folder))
        let modified = try a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let capture = CaptureLibraryItem(fileURL: a, thumbnailKey: "\(a.path):\(modified.timeIntervalSince1970)")
        async let preview = thumbnails.image(at: a)
        async let library = thumbnails.image(for: capture)
        let (card, cell) = await (preview, library)
        precondition(card != nil && card === cell, "Preview and Library must share the same decode")
        precondition(card!.width == 320 && card!.height == 640)

        let item = try await ScreenshotClipboardImage.item(from: a, dataType: .png)
        precondition(Set(item.types) == [.fileURL, .png], "No eager uncompressed TIFF")
        precondition(item.string(forType: .fileURL) == a.absoluteString)
        let encoded = try Data(contentsOf: a)
        precondition(item.data(forType: .png) == encoded)
        let cancelled = Task { _ = try await ScreenshotClipboardImage.item(from: a, dataType: .png) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled copy prepared an item") }
        catch is CancellationError {}
        do {
            _ = try await ScreenshotClipboardImage.item(from: a.appendingPathExtension("missing"), dataType: .png)
            preconditionFailure("Missing file must fail before publishing")
        } catch is CocoaError {}
        print("PASS: concurrent lossless PNGs and DPI; shared thumbnail; encoded clipboard bytes, no TIFF; cancellation and read errors")
    }
}
