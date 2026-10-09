import AppKit
import ImageIO

enum ScreenshotClipboardImage {
    static func item(from url: URL, dataType: NSPasteboard.PasteboardType) async throws -> NSPasteboardItem {
        try Task.checkCancellation()
        let (data, tiff) = try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                let data = try Data(contentsOf: url)
                return (data, Self.tiffData(from: data))
            }
        }.value
        try Task.checkCancellation()

        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(data, forType: dataType)
        if let tiff { item.setData(tiff, forType: .tiff) }
        return item
    }

    nonisolated private static func tiffData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 25_000_000 / height else { return nil }
        // ponytail: skip TIFF above 25 MP to avoid huge tall-image allocations;
        // use a lazy provider if TIFF-only targets need these captures too.
        return NSBitmapImageRep(data: data)?.tiffRepresentation ?? NSImage(data: data)?.tiffRepresentation
    }
}
