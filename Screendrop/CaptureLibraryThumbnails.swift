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

    func image(for item: CaptureLibraryItem, maxPixelSize: Int = 640) async -> CGImage? {
        await image(at: item.fileURL, isVideo: item.isVideo, version: item.thumbnailKey, maxPixelSize: maxPixelSize)
    }

    func image(at url: URL, isVideo: Bool = false, maxPixelSize: Int = 640) async -> CGImage? {
        await image(at: url, isVideo: isVideo, version: url.path, maxPixelSize: maxPixelSize)
    }

    private func image(at url: URL, isVideo: Bool, version: String, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let size = Self.bucket(for: CGFloat(maxPixelSize))
        var resourceURL = url
        // A reused URL can still hold the old stat values after an editor save.
        resourceURL.removeAllCachedResourceValues()
        let values = try? resourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let version = "v1:\(url.path):\(values?.fileSize ?? 0):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(isVideo ? version : ""):\(size)"
        let key = version as NSString
        if let image = cache.object(forKey: key) { return image }
        if let task = inFlight[version] {
            let result = await task.value
            return Task.isCancelled ? nil : result
        }
        guard await acquire() else { return nil }
        defer { release() }
        guard !Task.isCancelled else { return nil }
        if let image = cache.object(forKey: key) { return image }
        if let task = inFlight[version] {
            let result = await task.value
            return Task.isCancelled ? nil : result
        }
        let disk = disk
        let shouldTrim = requestsSinceTrim % 32 == 0
        requestsSinceTrim += 1
        let decode = Task.detached(priority: .utility) { () -> CGImage? in
            if shouldTrim { disk.trim() }
            if let image = autoreleasepool(invoking: { disk.image(for: version) }) { return image }
            guard let image = await Self.decode(url, isVideo: isVideo, maxPixelSize: size) else { return nil }
            autoreleasepool { disk.store(image, for: version) }
            return image
        }
        inFlight[version] = decode
        // A cancelled cell must not cancel work the preview card or another cell shares.
        let result = await decode.value
        inFlight[version] = nil
        guard let result else { return nil }
        cache.setObject(result, forKey: key, cost: result.bytesPerRow * result.height)
        return Task.isCancelled ? nil : result
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

    private nonisolated static func decode(_ url: URL, isVideo: Bool, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            return await withTaskCancellationHandler {
                try? await generator.image(at: .zero).image
            } onCancel: { generator.cancelAllCGImageGeneration() }
        }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
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
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geometry in
            let bucket = CaptureLibraryThumbnails.bucket(for: max(geometry.size.width, geometry.size.height) * displayScale)
            ZStack {
                Color(nsColor: .quaternaryLabelColor).opacity(0.25)
                if let image {
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
            .task(id: "\(item.thumbnailKey):\(bucket)") {
                image = nil
                let result = await CaptureLibraryThumbnails.shared.image(for: item, maxPixelSize: bucket)
                guard !Task.isCancelled else { return }
                image = result
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
