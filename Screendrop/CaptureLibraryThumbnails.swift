import AppKit
@preconcurrency import AVFoundation
import ImageIO
import SwiftUI

/// Shared across reused grid/list cells and the inspector. Only four decodes
/// run at once, queued work is cancellable, and decoded pixels have a budget.
actor CaptureLibraryThumbnails {
    static let shared = CaptureLibraryThumbnails()
    private let cache = NSCache<NSString, CGImage>()
    private let disk: CaptureThumbnailDiskCache
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private var requestsSinceTrim = 0
    private var running = 0
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []

    init(disk: CaptureThumbnailDiskCache = .shared) {
        self.disk = disk
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 160
    }

    nonisolated static func bucket(for pixelSize: CGFloat) -> Int { pixelSize > 320 ? 640 : 320 }

    /// `topOfTall` asks for a tall capture's top square, `maxPixelSize` wide, instead of the whole capture.
    func image(for item: CaptureLibraryItem, maxPixelSize: Int = 640, topOfTall: Bool = false) async -> CGImage? {
        await image(at: item.fileURL, owner: item.ownedURL, isVideo: item.isVideo, version: item.thumbnailKey,
                    maxPixelSize: maxPixelSize, top: topOfTall && item.isTall)
    }

    func image(at url: URL, isVideo: Bool = false, maxPixelSize: Int = 640) async -> CGImage? {
        await image(at: url, owner: url, isVideo: isVideo, version: url.path, maxPixelSize: maxPixelSize, top: false)
    }

    private func image(at url: URL, owner: URL, isVideo: Bool, version: String, maxPixelSize: Int, top: Bool) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let preview: RecordingPreviewSource?
        do { preview = isVideo ? try await RecordingPreviewSource(url) : nil }
        catch { return nil }
        let url = preview?.url ?? url
        let size = Self.bucket(for: CGFloat(maxPixelSize))
        var resourceURL = url
        // A reused URL can still hold the old stat values after an editor save.
        resourceURL.removeAllCachedResourceValues()
        guard let values = try? resourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let version = "v4:\(url.path):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(isVideo ? version : ""):\(preview?.revision ?? ""):\(size)\(top ? ":top" : "")"
        let filename = disk.url(for: version, source: owner).lastPathComponent
        let key = filename as NSString
        if let image = cache.object(forKey: key) { return image }
        if let task = inFlight[filename] {
            let result = await task.value
            return Task.isCancelled || !FileManager.default.fileExists(atPath: url.path) ? nil : result
        }
        guard await acquire() else { return nil }
        defer { release() }
        guard !Task.isCancelled else { return nil }
        // A queued request must not resurrect a cache after its source was deleted.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let image = cache.object(forKey: key) { return image }
        if let task = inFlight[filename] {
            let result = await task.value
            return Task.isCancelled || !FileManager.default.fileExists(atPath: url.path) ? nil : result
        }
        let disk = disk
        let shouldTrim = requestsSinceTrim % 32 == 0
        requestsSinceTrim += 1
        let decode = Task.detached(priority: .utility) { () -> CGImage? in
            if shouldTrim { disk.trim() }
            if let image = autoreleasepool(invoking: { disk.image(for: version, source: owner) }) { return image }
            guard let image = await Self.decode(url, isVideo: isVideo, maxPixelSize: size, top: top,
                                               redactions: preview?.redactions ?? []) else { return nil }
            autoreleasepool { disk.store(image, for: version, source: owner) }
            return image
        }
        inFlight[filename] = decode
        // A cancelled cell must not cancel work the preview card or another cell shares.
        let result = await decode.value
        inFlight[filename] = nil
        guard let result, FileManager.default.fileExists(atPath: url.path) else { return nil }
        cache.setObject(result, forKey: key, cost: result.bytesPerRow * result.height)
        return Task.isCancelled ? nil : result
    }

    func remove(for sources: [URL]) async {
        guard !sources.isEmpty else { return }
        let sourceKeys = Set(sources.map(disk.sourceKey(for:)))
        let pending = inFlight.filter { sourceKeys.contains(String($0.key.prefix(64))) }.map(\.value)
        // Finish existing writes before removal; queued requests recheck the source.
        for task in pending { _ = await task.value }
        cache.removeAllObjects()
        let disk = disk
        await Task.detached(priority: .utility) { disk.remove(for: sources) }.value
    }

    private func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if running < 4 { running += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(returning: false)
    }

    private func release() {
        if waiters.isEmpty { running -= 1 }
        else { waiters.removeFirst().1.resume(returning: true) }
    }

    private nonisolated static func decode(_ url: URL, isVideo: Bool, maxPixelSize: Int, top: Bool, redactions: [RecordingRedaction]) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            if !redactions.isEmpty {
                do { generator.videoComposition = try await RecordingRedactionFilter.composition(asset: generator.asset, redactions: redactions) }
                catch { return nil }
            }
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            return await withTaskCancellationHandler {
                try? await generator.image(at: .zero).image
            } onCancel: { generator.cancelAllCGImageGeneration() }
        }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            if top { return TallCapture.topSquare(of: source, width: maxPixelSize) }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }
    }
}

struct CaptureLibraryThumbnail: View {
    let item: CaptureLibraryItem
    /// Browse cards show a tall capture's top, filling the well (sd-7ym);
    /// the inspector and Quick Look keep it whole.
    var showsTopOfTall = false
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        let top = showsTopOfTall && item.isTall
        GeometryReader { geometry in
            let bucket = CaptureLibraryThumbnails.bucket(for: max(geometry.size.width, geometry.size.height) * displayScale)
            ZStack {
                Color(nsColor: .quaternaryLabelColor).opacity(0.25)
                if let image, top {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                        .clipped()
                        .mask { TallCapture.fade }
                } else if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Image(systemName: item.isVideo ? "video" : "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .task(id: "\(item.thumbnailKey):\(bucket):\(top)") {
                image = nil
                let result = await CaptureLibraryThumbnails.shared.image(for: item, maxPixelSize: bucket, topOfTall: top)
                guard !Task.isCancelled else { return }
                image = result
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Captures much taller than wide, such as scrolling captures, which a
/// fitted thumbnail shrinks to a strip (sd-7ym).
nonisolated enum TallCapture {
    static func isTall(width: Int, height: Int) -> Bool {
        width > 0 && Double(height) > Double(width) * 2.5
    }

    /// The image's top square, `width` px wide. Decoded at that width with
    /// the long side capped, never at full size, and redrawn so the cached
    /// square doesn't keep the strip's pixels.
    static func topSquare(of source: CGImageSource, width: Int) -> CGImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int, pixelWidth > 0,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // shortcut: past 1:6.4 at 640 px the cap makes the top a little soft; a region decode if that shows.
        let longSide = min(4096, max(width, width * pixelHeight / pixelWidth))
        guard let strip = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
        ] as CFDictionary) else { return nil }
        let side = min(strip.width, strip.height)
        let space = strip.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // y-up: the strip's top edge lands on the square's top edge.
        context.draw(strip, in: CGRect(x: 0, y: side - strip.height, width: strip.width, height: strip.height))
        return context.makeImage()
    }

    /// Fades a cropped thumbnail out at the bottom, so it reads as continuing.
    @MainActor static var fade: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 34)
        }
    }

    /// The bottom-left mark on a card showing a tall capture's top: Scrolling Capture's symbol.
    @MainActor static var badge: some View {
        Image(systemName: "rectangle.expand.vertical")
            .cardPill()
            .help("A tall capture. The card shows its top.")
            .accessibilityHidden(true)
    }
}
