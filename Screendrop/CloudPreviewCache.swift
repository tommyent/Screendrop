import Foundation
import UniformTypeIdentifiers

/// Full uploads fetched for Quick Look from the Worker's media routes, one
/// folder per upload in Caches, capped in size with the least recently
/// viewed going first. Only password-protected uploads send the owner's
/// token, and only to the Worker's own origin (`CloudUploadList.mediaRequest`).
nonisolated struct CloudPreviewCache: Sendable {
    let folder: URL
    let limit: Int64

    static let shared = CloudPreviewCache(
        folder: URL.cachesDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "Screendrop", directoryHint: .isDirectory)
            .appending(path: "Cloud Previews", directoryHint: .isDirectory),
        limit: 1 << 30
    )

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // This folder is the cache; URLCache would keep a second copy.
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// The share link's origin with /api/media/:id for recordings or
    /// /api/image/:id for screenshots, the routes the share page plays from.
    static func mediaURL(for upload: CloudUpload) -> URL? {
        guard isSafeID(upload.id), let link = URL(string: upload.url),
              var components = URLComponents(url: link, resolvingAgainstBaseURL: false),
              components.scheme == "https" || components.scheme == "http",
              components.host?.isEmpty == false else { return nil }
        components.path = (upload.isVideo ? "/api/media/" : "/api/image/") + upload.id
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// IDs name a folder here, so only the Worker's own alphabet gets through.
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// The upload's name, safe as a file name, so Quick Look's title reads well.
    static func fileName(for upload: CloudUpload) -> String {
        let name = upload.title.flatMap { $0.isEmpty ? nil : $0 } ?? (upload.filename as NSString).deletingPathExtension
        let safe = String(name.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }.prefix(100))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        return safe.isEmpty ? upload.id : safe
    }

    /// The cached file, downloaded first if it isn't here. `progress` gets
    /// the fraction downloaded about ten times a second. Trimming afterwards
    /// spares `kept`, the uploads being previewed together.
    func file(for upload: CloudUpload, keeping kept: Set<String> = [],
              owner: (workerBase: String, token: String)? = nil,
              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard let source = Self.mediaURL(for: upload) else { throw CloudPreviewError.badLink }
        let manager = FileManager.default
        let directory = folder.appending(path: upload.id, directoryHint: .isDirectory)
        if let cached = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ).first {
            // Recently viewed, so trimming takes it last.
            try? manager.setAttributes([.modificationDate: Date.now], ofItemAtPath: cached.path)
            return cached
        }
        let relay = DownloadRelay()
        let poll = Task {
            while !Task.isCancelled {
                if let fraction = relay.fraction(expected: upload.size) { progress(fraction) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { poll.cancel() }
        let request = CloudUploadList.mediaRequest(source, workerBase: owner?.workerBase,
                                                   token: upload.hasPassword == true ? owner?.token : nil)
        let (download, response) = try await Self.session.download(for: request, delegate: relay)
        defer { try? manager.removeItem(at: download) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // An expired upload's media answers 404 until the daily clean-up deletes it.
            throw CloudPreviewError.status(upload.expiresAt.map { $0 <= .now } == true ? 410 : status)
        }
        let named = (upload.filename as NSString).pathExtension.filter { $0.isLetter || $0.isNumber }
        let ext = response.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
            ?? (named.isEmpty ? (upload.isVideo ? "mp4" : "png") : named)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: Self.fileName(for: upload) + "." + ext)
        do {
            try manager.moveItem(at: download, to: file)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
        progress(1)
        trim(keeping: kept.union([upload.id]))
        return file
    }

    /// Drops the least recently viewed uploads until the folder fits the
    /// cap, never one in `kept`.
    func trim(keeping kept: Set<String>) {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .contentModificationDateKey]
        let directories = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let entries = directories.compactMap { directory -> (directory: URL, size: Int64, used: Date)? in
            guard let file = try? manager.contentsOfDirectory(
                      at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
                  ).first,
                  let values = try? file.resourceValues(forKeys: keys) else { return nil }
            return (directory, Int64(values.totalFileAllocatedSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.used < $1.used })
        where total > limit && !kept.contains(entry.directory.lastPathComponent) {
            try? manager.removeItem(at: entry.directory)
            total -= entry.size
        }
    }

    /// Forgets a deleted upload.
    func remove(_ id: String) {
        guard Self.isSafeID(id) else { return }
        try? FileManager.default.removeItem(at: folder.appending(path: id, directoryHint: .isDirectory))
    }
}

nonisolated enum CloudPreviewError: LocalizedError {
    case badLink
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .badLink: "Its link doesn’t point to a Worker."
        case .status(404): "It’s no longer in the cloud."
        case .status(410): "Its link has expired."
        case .status(let code): "The Worker answered with HTTP \(code)."
        }
    }
}

/// Hands over the task URLSession makes for a download, for its byte counts.
private nonisolated final class DownloadRelay: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { self.task = task }
    }

    func fraction(expected size: Int?) -> Double? {
        guard let task = lock.withLock({ task }) else { return nil }
        let expected = task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : Int64(size ?? 0)
        guard expected > 0 else { return nil }
        return min(1, Double(task.countOfBytesReceived) / Double(expected))
    }
}
