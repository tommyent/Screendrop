// swiftc -parse-as-library -default-isolation MainActor scripts/check-library-thumbnails.swift \
//   Screendrop/{CaptureLibraryThumbnails,CaptureThumbnailDiskCache}.swift -o /tmp/check-library-thumbnails
import AppKit
import ImageIO

nonisolated struct CaptureLibraryItem: Sendable {
    let fileURL: URL
    let isVideo = false
    let thumbnailKey: String
    var ownedURL: URL { fileURL }
}

@main struct LibraryThumbnailChecks {
    static func image(width: Int, height: Int, green: Bool) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: context.colorSpace!, components: green ? [0, 1, 0, 1] : [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL) {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
    }

    static func isGreen(_ image: CGImage) -> Bool {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.data!.assumingMemoryBound(to: UInt8.self)[1] > 250
    }

    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("library-thumbnails-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("private-capture.png")
        let disk = CaptureThumbnailDiskCache(directory: root.appendingPathComponent("cache"))
        write(image(width: 800, height: 1600, green: false), to: source)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: source.path)

        precondition(CaptureLibraryThumbnails.bucket(for: 320) == 320)
        precondition(CaptureLibraryThumbnails.bucket(for: 321) == 640)
        let thumbnails = CaptureLibraryThumbnails(disk: disk)
        let small = await thumbnails.image(at: source, maxPixelSize: 320)!
        let large = await thumbnails.image(at: source, maxPixelSize: 640)!
        precondition(small.width == 160 && small.height == 320 && large.width == 320 && large.height == 640)
        precondition(!isGreen(small) && !isGreen(large))
        let files = try manager.contentsOfDirectory(at: disk.directory, includingPropertiesForKeys: nil)
        precondition(files.count == 2 && files.allSatisfy { $0.deletingPathExtension().lastPathComponent.count == 129 })

        // A new decoder must read the disk cache, not re-decode the original:
        // replace only the cached small thumbnail with a visible sentinel.
        let smallFile = files.first { url in
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            return CGImageSourceCreateImageAtIndex(source, 0, nil)!.height == 320
        }!
        write(image(width: 160, height: 320, green: true), to: smallFile)
        let sentinelSource = CGImageSourceCreateWithURL(smallFile as CFURL, nil)!
        precondition(isGreen(CGImageSourceCreateImageAtIndex(sentinelSource, 0, nil)!), "Sentinel fixture was not green")
        let warm = await CaptureLibraryThumbnails(disk: disk).image(at: source, maxPixelSize: 320)!
        precondition(isGreen(warm), "A fresh decoder must use the on-disk thumbnail")

        // Corrupt cache is repaired from the original and never hides it.
        try Data("not an image".utf8).write(to: smallFile)
        let repaired = await CaptureLibraryThumbnails(disk: disk).image(at: source, maxPixelSize: 320)!
        precondition(!isGreen(repaired))

        // Same-path edits invalidate both disk and in-memory thumbnails, even
        // before the Library has scanned and replaced its older item metadata.
        let oldItem = CaptureLibraryItem(fileURL: source, thumbnailKey: "\(source.path):1000.0")
        _ = await thumbnails.image(for: oldItem)
        write(image(width: 800, height: 1600, green: true), to: source)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: source.path)
        let edited = await thumbnails.image(for: oldItem)!
        precondition(isGreen(edited), "An edited original must not reuse the old cached image")

        let unavailable = await CaptureLibraryThumbnails(disk: CaptureThumbnailDiskCache(directory: source))
            .image(at: source)!
        precondition(isGreen(unavailable), "Cache write failure must not prevent displaying the image")

        let lru = CaptureThumbnailDiskCache(directory: root.appendingPathComponent("lru"))
        lru.store(small, for: "older", source: source)
        lru.store(large, for: "newer", source: source)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: lru.url(for: "older", source: source).path)
        let size = try lru.url(for: "newer", source: source).resourceValues(forKeys: [.fileSizeKey]).fileSize!
        lru.trim(to: size)
        precondition(!manager.fileExists(atPath: lru.url(for: "older", source: source).path) && lru.image(for: "newer", source: source) != nil)

        let other = root.appendingPathComponent("other.png")
        disk.store(small, for: "unrelated", source: other)
        try manager.removeItem(at: source)
        await thumbnails.remove(for: [source])
        let remaining = try manager.contentsOfDirectory(at: disk.directory, includingPropertiesForKeys: nil)
        precondition(remaining.count == 1 && remaining[0].lastPathComponent == disk.url(for: "unrelated", source: other).lastPathComponent,
            "Delete all buckets and older versions, preserving unrelated captures")
        let deleted = await thumbnails.image(for: oldItem)
        precondition(deleted == nil, "A deleted source must not return its in-memory thumbnail")

        let pendingURL = root.appendingPathComponent("pending.png")
        write(image(width: 800, height: 1600, green: false), to: pendingURL)
        let pending = Task { await thumbnails.image(at: pendingURL) }
        await Task.yield()
        try manager.removeItem(at: pendingURL)
        await thumbnails.remove(for: [pendingURL])
        _ = await pending.value
        let afterPending = try manager.contentsOfDirectory(at: disk.directory, includingPropertiesForKeys: nil)
        precondition(!afterPending.contains { $0.lastPathComponent.hasPrefix(disk.sourceKey(for: pendingURL)) },
            "A concurrent request must not recreate a deleted thumbnail")

        let package = root.appendingPathComponent("recording.screendrop-recording")
        disk.store(small, for: "old-render", source: package)
        disk.store(large, for: "new-render", source: package)
        await thumbnails.remove(for: [package])
        let afterPackage = try manager.contentsOfDirectory(at: disk.directory, includingPropertiesForKeys: nil)
        precondition(afterPackage.count == 1, "Package deletion must remove all rendered thumbnail versions")
        print("PASS: 320/640 buckets; cross-decoder disk hit; corruption repair; edit invalidation; cache failure fallback; LRU trim; deletion eviction")
    }
}
