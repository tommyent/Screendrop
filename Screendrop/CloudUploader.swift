//
//  CloudUploader.swift
//  Screendrop
//
//  Uploads screenshots to R2 via the Screendrop Cloud worker.
//
//  Flow:
//  1. PUT /api/upload with the raw file body + metadata headers
//  2. Worker streams the body directly to R2 via binding (no buffering)
//  3. Worker creates the D1 metadata row, returns the shareable short URL
//
//  The user only needs a worker URL and upload token - no S3 credentials.
//

import AppKit
import AVFoundation
@preconcurrency import CoreMedia
import ImageIO
import UniformTypeIdentifiers

struct CloudUploadResult: Sendable {
    let id: String
    let url: String
    let filename: String
    let size: Int
}

@MainActor
@Observable
final class CloudUploader: NSObject {
    static let shared = CloudUploader()

    /// Upload progress keyed by preview item ID.
    private(set) var uploadProgress: [UUID: Double] = [:]

    /// Set of item IDs currently uploading.
    private(set) var uploadingItems: Set<UUID> = []

    /// Completed upload URLs keyed by preview item ID.
    private(set) var uploadedURLs: [UUID: String] = [:]

    /// Set of item IDs whose upload failed (cleared after shake animation).
    private(set) var failedItemIDs: Set<UUID> = []

    /// One cancellable operation covers preparation and transport. Its ID
    /// keeps a cancelled completion from clearing a newer retry's state.
    private var activeTasks: [UUID: (id: UUID, task: Task<(CloudUploadResult, URL, Data?), any Error>)] = [:]

    private override init() {
        super.init()
    }

    var isConfigured: Bool {
        CloudCredentialStore.shared.isConfigured
    }

    func upload(
        itemID: UUID,
        fileURL: URL,
        title: String? = nil,
        socialEnabled: Bool = true
    ) async throws -> CloudUploadResult {
        try Task.checkCancellation()
        guard isConfigured else {
            throw CloudUploadError.notConfigured
        }
        let creds = CloudCredentialStore.shared.snapshot()

        // The Dock mirrors the whole span - the deliverable render (when
        // one is needed) plus the upload itself.
        let dockProgressID = DockExportProgressCoordinator.shared.start()
        let operationID = UUID()
        activeTasks[itemID]?.task.cancel()
        uploadingItems.insert(itemID)
        uploadProgress[itemID] = 0
        failedItemIDs.remove(itemID)

        let uploadTask = Task { [weak self] () throws -> (CloudUploadResult, URL, Data?) in
            guard let self else { throw CancellationError() }
            try Task.checkCancellation()

            // The task is registered before this render can suspend.
            var fileURL = fileURL
            let sessionDirectory = fileURL.deletingLastPathComponent()
            if RecordingSession.isSessionDirectory(sessionDirectory) {
                fileURL = try await RecordingSessionRenderer.ensureDeliverable(
                    for: RecordingSession(directoryURL: sessionDirectory)
                )
            }
            try Task.checkCancellation()

            let fileName = fileURL.lastPathComponent
            let fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let mimeType = self.mimeTypeForFile(fileURL)
            let isVideo = mimeType.hasPrefix("video/")
            let transcriptData = isVideo && RecordingSession.isSessionDirectory(sessionDirectory)
                ? CloudSidecarUploader.transcriptData(sessionDirectory: sessionDirectory, uploadedFileURL: fileURL)
                : nil
            let dimensions: (width: Int, height: Int)?
            let duration: Double?

            if isVideo {
                let videoMeta = await self.videoDimensions(at: fileURL)
                dimensions = videoMeta.dimensions
                duration = videoMeta.duration
            } else {
                dimensions = self.imageDimensions(at: fileURL)
                duration = nil
            }

            let result = try await Self.streamUpload(
                data: fileData,
                filename: fileName,
                contentType: mimeType,
                mediaType: isVideo ? "video" : "image",
                width: dimensions?.width,
                height: dimensions?.height,
                duration: duration,
                title: title,
                socialEnabled: socialEnabled,
                creds: creds,
                progress: { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard self?.activeTasks[itemID]?.id == operationID else { return }
                        self?.uploadProgress[itemID] = fraction
                        DockExportProgressCoordinator.shared.update(
                            dockProgressID,
                            progress: fraction
                        )
                    }
                }
            )

            return (result, fileURL, transcriptData)
        }

        activeTasks[itemID] = (operationID, uploadTask)
        defer {
            DockExportProgressCoordinator.shared.finish(dockProgressID)
            if activeTasks[itemID]?.id == operationID {
                activeTasks.removeValue(forKey: itemID)
                uploadingItems.remove(itemID)
                uploadProgress.removeValue(forKey: itemID)
            }
        }

        do {
            let (result, uploadedFileURL, transcriptData) = try await withTaskCancellationHandler {
                try await uploadTask.value
            } onCancel: {
                uploadTask.cancel()
            }
            guard !Task.isCancelled, !uploadTask.isCancelled,
                  activeTasks[itemID]?.id == operationID else {
                // A response in hand means the server accepted the upload.
                // Cleanup must outlive this cancelled task and use its worker.
                Task.detached(priority: .utility) {
                    try? await Self.performDelete(uploadID: result.id, creds: creds)
                }
                throw CancellationError()
            }
            uploadedURLs[itemID] = result.url
            if mimeTypeForFile(uploadedFileURL).hasPrefix("video/") {
                scheduleSidecarUpload(uploadID: result.id, fileURL: uploadedFileURL, transcriptData: transcriptData, title: title, creds: creds)
            }
            return result
        } catch {
            if uploadTask.isCancelled || Task.isCancelled || error is CancellationError
                || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if activeTasks[itemID]?.id == operationID {
                failedItemIDs.insert(itemID)
            }
            throw error
        }
    }

    /// Ships the share-page extras (poster, title, transcript) after the
    /// video itself is up. Best-effort and detached: the share link is
    /// already usable, sidecars enrich the page when they land.
    private func scheduleSidecarUpload(uploadID: String, fileURL: URL, transcriptData: Data?, title: String?, creds: CloudCredentials) {
        let item = ScreenshotHistoryStore.shared.items.first {
            $0.url.standardizedFileURL == fileURL.standardizedFileURL
        }
        let createdAt = item?.createdAt ?? Date()
        Task.detached(priority: .utility) {
            await CloudSidecarUploader.uploadVideoSidecars(
                uploadID: uploadID,
                uploadedFileURL: fileURL,
                transcriptData: transcriptData,
                createdAt: createdAt,
                customTitle: title,
                creds: creds
            )
        }
    }

    func cancelUpload(for itemID: UUID) {
        activeTasks[itemID]?.task.cancel()
        activeTasks.removeValue(forKey: itemID)
        uploadingItems.remove(itemID)
        uploadProgress.removeValue(forKey: itemID)
    }

    func clearUploadState(for itemID: UUID) {
        cancelUpload(for: itemID)
        uploadedURLs.removeValue(forKey: itemID)
        failedItemIDs.remove(itemID)
    }

    func clearFailed(for itemID: UUID) {
        failedItemIDs.remove(itemID)
    }

    // MARK: - Delete

    /// Deletes an upload from the cloud entirely: R2 files (main file, poster,
    /// transcript, storyboard) plus its D1 row and comments/likes/view events.
    /// Irreversible - the share link 404s immediately after.
    func deleteFromCloud(uploadID: String) async throws {
        let creds = CloudCredentialStore.shared.snapshot()
        guard creds.isConfigured else {
            throw CloudUploadError.notConfigured
        }
        try await Self.performDelete(uploadID: uploadID, creds: creds)
    }

    nonisolated private static func performDelete(uploadID: String, creds: CloudCredentials) async throws {
        let workerBase = normalizeWorkerURL(creds.workerURL)
        let token = creds.uploadToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: "\(workerBase)/api/upload/\(uploadID)") else {
            throw CloudUploadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CloudUploadError.invalidResponse
        }

        guard http.statusCode == 200 else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw CloudUploadError.serverError(http.statusCode, body)
        }
    }

    // MARK: - Streaming Upload

    /// Sends the raw file bytes as the request body to PUT /api/upload.
    /// Metadata (filename, dimensions, etc.) is passed via headers so the
    /// Worker can stream the body directly to R2 without buffering.
    nonisolated private static func streamUpload(
        data: Data,
        filename: String,
        contentType: String,
        mediaType: String,
        width: Int?,
        height: Int?,
        duration: Double?,
        title: String?,
        socialEnabled: Bool,
        creds: CloudCredentials,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> CloudUploadResult {
        let workerBase = normalizeWorkerURL(creds.workerURL)
        let token = creds.uploadToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: "\(workerBase)/api/upload") else {
            throw CloudUploadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 300
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(filename, forHTTPHeaderField: "X-Filename")
        request.setValue(mediaType, forHTTPHeaderField: "X-Media-Type")

        if let width { request.setValue(String(width), forHTTPHeaderField: "X-Width") }
        if let height { request.setValue(String(height), forHTTPHeaderField: "X-Height") }
        if let duration { request.setValue(String(duration), forHTTPHeaderField: "X-Duration") }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
            request.setValue(encoded, forHTTPHeaderField: "X-Title")
        }
        request.setValue(socialEnabled ? "true" : "false", forHTTPHeaderField: "X-Social-Enabled")

        let progressDelegate = UploadProgressDelegate { sent, expected in
            guard expected > 0 else { return }
            progress?(min(1, Double(sent) / Double(expected)))
        }

        try Task.checkCancellation()
        let (responseData, response) = try await URLSession.shared.upload(
            for: request,
            from: data,
            delegate: progressDelegate
        )

        guard let http = response as? HTTPURLResponse else {
            throw CloudUploadError.invalidResponse
        }

        guard http.statusCode == 201 else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw CloudUploadError.serverError(http.statusCode, body)
        }

        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        guard let id = json?["id"] as? String,
              let shareURL = json?["url"] as? String,
              let name = json?["filename"] as? String,
              let fileSize = json?["size"] as? Int else {
            throw CloudUploadError.invalidResponse
        }

        progress?(1)
        return CloudUploadResult(id: id, url: shareURL, filename: name, size: fileSize)
    }

    // MARK: - Helpers

    nonisolated private static func normalizeWorkerURL(_ raw: String) -> String {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.lowercased().hasPrefix("http") ? trimmed : "https://\(trimmed)"
    }

    private func mimeTypeForFile(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        default: return "application/octet-stream"
        }
    }

    private func imageDimensions(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    nonisolated private func videoDimensions(at url: URL) async -> (dimensions: (width: Int, height: Int)?, duration: Double?) {
        let asset = AVURLAsset(url: url)
        var dims: (width: Int, height: Int)?
        var dur: Double?

        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            let size = try? await track.load(.naturalSize)
            let transform = try? await track.load(.preferredTransform)
            if let size, let transform {
                let transformed = size.applying(transform)
                dims = (width: Int(abs(transformed.width)), height: Int(abs(transformed.height)))
            } else if let size {
                dims = (width: Int(size.width), height: Int(size.height))
            }
        }

        if let loadedDuration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(loadedDuration)
            if seconds.isFinite, seconds > 0 {
                dur = seconds
            }
        }

        return (dimensions: dims, duration: dur)
    }
}

// MARK: - Upload Progress Delegate

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}

// MARK: - Errors

enum CloudUploadError: LocalizedError {
    case notConfigured
    case invalidURL
    case networkError(Error)
    case serverError(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Cloud upload is not configured. Set your worker URL and upload token in Settings."
        case .invalidURL:
            "Invalid worker URL."
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .serverError(let code, let body):
            "Server error (\(code)): \(body)"
        case .invalidResponse:
            "Invalid response from server."
        }
    }
}
