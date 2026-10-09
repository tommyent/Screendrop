import AppKit
@preconcurrency import AVFoundation
import ImageIO
import SwiftUI

/// Shared across reused grid/list cells and the inspector. Only four decodes
/// run at once, queued work is cancellable, and decoded pixels have a budget.
actor CaptureLibraryThumbnails {
    static let shared = CaptureLibraryThumbnails()
    private let cache = NSCache<NSString, CGImage>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private var running = 0
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []

    init() {
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 160
    }

    func image(for item: CaptureLibraryItem) async -> CGImage? {
        await image(at: item.fileURL, isVideo: item.isVideo, version: item.thumbnailKey)
    }

    func image(at url: URL, isVideo: Bool = false) async -> CGImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return await image(at: url, isVideo: isVideo, version: "\(url.path):\(modified.timeIntervalSince1970)")
    }

    private func image(at url: URL, isVideo: Bool, version: String) async -> CGImage? {
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
        let decode = Task.detached(priority: .utility) {
            await Self.decode(url, isVideo: isVideo)
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

    private nonisolated static func decode(_ url: URL, isVideo: Bool) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
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
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }
    }
}

struct CaptureLibraryThumbnail: View {
    let item: CaptureLibraryItem
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geometry in
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
        }
        .clipped()
        .task(id: item.thumbnailKey) {
            image = nil
            let result = await CaptureLibraryThumbnails.shared.image(for: item)
            guard !Task.isCancelled else { return }
            image = result
        }
        .accessibilityHidden(true)
    }
}
