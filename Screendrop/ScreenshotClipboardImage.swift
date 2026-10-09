import AppKit

enum ScreenshotClipboardImage {
    static func item(from url: URL, dataType: NSPasteboard.PasteboardType) async throws -> NSPasteboardItem {
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
        try Task.checkCancellation()

        // Keep the encoded image and file reference; expanding it to TIFF can
        // allocate hundreds of megabytes for a tall scrolling capture.
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(data, forType: dataType)
        return item
    }
}
