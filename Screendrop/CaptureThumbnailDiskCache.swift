import CryptoKit
import Foundation
import ImageIO

/// Rebuildable thumbnails, separate from the Library's authoritative images.
nonisolated struct CaptureThumbnailDiskCache: Sendable {
    let directory: URL

    static let shared = Self(directory: URL.cachesDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? "Screendrop", directoryHint: .isDirectory)
        .appending(path: "Library Thumbnails", directoryHint: .isDirectory))

    func url(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".png")
    }

    func image(for key: String) -> CGImage? {
        let file = url(for: key)
        guard let source = CGImageSourceCreateWithURL(file as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
        return image
    }

    func store(_ image: CGImage, for key: String) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (data as Data).write(to: url(for: key), options: .atomic)
        } catch { /* A missing cache must never prevent showing the capture. */ }
    }

    // shortcut: up to 32 thumbnails can exceed the budget between batch trims;
    // trim more often if disk pressure justifies the extra directory scans.
    func trim(to limit: Int = 256 * 1024 * 1024) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? []
        let entries = files.filter { $0.pathExtension == "png" }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        for (url, size, _) in entries.sorted(by: { $0.2 < $1.2 }) where total > limit {
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= size }
        }
    }
}
