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

    static func checkFormats(in root: URL, source: URL) {
        let disk = CaptureThumbnailDiskCache(directory: root.appendingPathComponent("formats"))
        for alpha in [CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast] {
            for order in [CGBitmapInfo.byteOrderDefault, .byteOrder32Big, .byteOrder32Little] {
                for transparent in [false, true] {
                    // Padding is deliberately transparent; only actual pixels count.
                    var bytes = Data(repeating: 0, count: 24)
                    let first = alpha == .first || alpha == .premultipliedFirst
                    let little = order == .byteOrder32Little
                    let alphaOffset = little ? (first ? 3 : 0) : (first ? 0 : 3)
                    for y in 0..<2 {
                        for x in 0..<2 {
                            let start = y * 12 + x * 4
                            for c in 0..<4 { bytes[start + c] = 40 }
                            bytes[start + alphaOffset] = transparent && x == 1 && y == 1 ? 128 : 255
                        }
                    }
                    let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: 12, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue).union(order),
                        provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent)!
                    let key = "\(alpha.rawValue)-\(order.rawValue)-\(transparent)"
                    disk.store(image, for: key, source: source)
                    let decoded = CGImageSourceCreateWithURL(disk.url(for: key, source: source) as CFURL, nil)!
                    precondition(CGImageSourceGetType(decoded) as String? == (transparent ? "public.png" : "public.jpeg"))
                    let cached = disk.image(for: key, source: source)!
                    precondition(cached.width == 2 && cached.height == 2)
                    if transparent {
                        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                            space: image.colorSpace!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        context.draw(cached, in: CGRect(x: 0, y: 0, width: 2, height: 2))
                        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
                        precondition(stride(from: 3, to: 16, by: 4).filter { pixels[$0] == 128 }.count == 1)
                    }
                }
            }
        }
    }

    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("library-thumbnails-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("private-capture.png")
        checkFormats(in: root, source: source)
        let disk = CaptureThumbnailDiskCache(directory: root.appendingPathComponent("cache"))
        write(image(width: 800, height: 1600, green: false), to: source)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: source.path)
        let oldValues = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let oldVersion = "v2:\(source.path):\(oldValues.fileSize ?? 0):\(oldValues.contentModificationDate!.timeIntervalSince1970)::320"
        let oldPNG = disk.url(for: oldVersion, source: source).deletingPathExtension().appendingPathExtension("png")
        try manager.createDirectory(at: disk.directory, withIntermediateDirectories: true)
        write(image(width: 160, height: 320, green: true), to: oldPNG)

        precondition(CaptureLibraryThumbnails.bucket(for: 320) == 320)
        precondition(CaptureLibraryThumbnails.bucket(for: 321) == 640)
        let thumbnails = CaptureLibraryThumbnails(disk: disk)
        let small = await thumbnails.image(at: source, maxPixelSize: 320)!
        let large = await thumbnails.image(at: source, maxPixelSize: 640)!
        precondition(small.width == 160 && small.height == 320 && large.width == 320 && large.height == 640)
        precondition(!isGreen(small) && !isGreen(large))
        let files = try manager.contentsOfDirectory(at: disk.directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "thumb" }
        precondition(files.count == 2 && files.allSatisfy { $0.deletingPathExtension().lastPathComponent.count == 129 })
        precondition(files.allSatisfy { CGImageSourceGetType(CGImageSourceCreateWithURL($0 as CFURL, nil)!) as String? == "public.jpeg" })

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
        let oldLRU = lru.url(for: "legacy", source: source).deletingPathExtension().appendingPathExtension("png")
        write(small, to: oldLRU)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: oldLRU.path)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: lru.url(for: "older", source: source).path)
        let size = try lru.url(for: "newer", source: source).resourceValues(forKeys: [.fileSizeKey]).fileSize!
        lru.trim(to: size)
        precondition(!manager.fileExists(atPath: lru.url(for: "older", source: source).path) && lru.image(for: "newer", source: source) != nil)
        precondition(!manager.fileExists(atPath: oldLRU.path), "Legacy PNGs must count towards the cache budget")

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
        print("PASS: JPEG opaque/PNG transparency in 12 alpha layouts with padded rows; 320/640 buckets; cross-decoder disk hit; corruption repair; edit invalidation; cache failure fallback; LRU trim; deletion eviction including legacy PNG")
    }
}
