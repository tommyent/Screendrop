import CryptoKit
import Foundation
import ImageIO

/// Rebuildable thumbnails, separate from the Library's authoritative images.
nonisolated struct CaptureThumbnailDiskCache: Sendable {
    let directory: URL

    static let shared = Self(directory: URL.cachesDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? "Screendrop", directoryHint: .isDirectory)
        .appending(path: "Library Thumbnails", directoryHint: .isDirectory))

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func sourceKey(for url: URL) -> String { digest(url.standardizedFileURL.path) }

    func url(for key: String, source: URL) -> URL {
        directory.appendingPathComponent(sourceKey(for: source) + "-" + digest(key) + ".thumb")
    }

    func image(for key: String, source: URL) -> CGImage? {
        let file = url(for: key, source: source)
        guard let source = CGImageSourceCreateWithURL(file as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
        return image
    }

    func store(_ image: CGImage, for key: String, source: URL) {
        let opaque = isOpaque(image)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,
            (opaque ? "public.jpeg" : "public.png") as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image,
            opaque ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil)
        guard CGImageDestinationFinalize(destination) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (data as Data).write(to: url(for: key, source: source), options: .atomic)
        } catch { /* A missing cache must never prevent showing the capture. */ }
    }

    private func isOpaque(_ image: CGImage) -> Bool {
        guard !image.isMask else { return false }
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return true
        case .first, .last, .premultipliedFirst, .premultipliedLast: break
        default: return false
        }
        // Inspect known 8-bit layouts; preserve alpha in unfamiliar formats.
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.decode == nil, image.pixelFormatInfo == .packed,
              let data = image.dataProvider?.data, CFDataGetLength(data) >= image.bytesPerRow * image.height,
              let bytes = CFDataGetBytePtr(data) else { return false }
        var alpha = image.alphaInfo == .first || image.alphaInfo == .premultipliedFirst ? 0 : 3
        switch image.byteOrderInfo {
        case .order32Little: alpha = 3 - alpha
        case .orderDefault, .order32Big: break
        default: return false
        }
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[y * image.bytesPerRow + x * 4 + alpha] != 255 { return false }
        }
        return true
    }

    func remove(for sources: [URL]) {
        let sourceKeys = Set(sources.map(sourceKey(for:)))
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["png", "thumb"].contains(file.pathExtension) && sourceKeys.contains(String(file.lastPathComponent.prefix(64))) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // shortcut: up to 32 thumbnails can exceed the budget between batch trims;
    // trim more often if disk pressure justifies the extra directory scans.
    func trim(to limit: Int = 256 * 1024 * 1024) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? []
        let entries = files.filter { ["png", "thumb"].contains($0.pathExtension) }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        for (url, size, _) in entries.sorted(by: { $0.2 < $1.2 }) where total > limit {
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= size }
        }
    }
}
