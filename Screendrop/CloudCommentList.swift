import Foundation

/// One comment left on a share page, as Bearer GET /api/comments lists it
/// (SPEC-share-v2.md section 8), with a summary of its upload.
nonisolated struct CloudComment: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let uploadId: String
    let authorName: String
    /// The provider's picture for a signed-in commenter; nil for anonymous ones.
    let authorAvatar: String?
    let text: String
    /// Where in the video it was left, in seconds; nil for a general comment.
    let timestamp: Double?
    let createdAt: Date
    let upload: Upload

    nonisolated struct Upload: Hashable, Sendable, Decodable {
        let title: String?
        let filename: String
        let mediaType: String
        let shareUrl: String
        let expiresAt: Date?
    }

    var uploadName: String {
        guard let title = upload.title, !title.isEmpty else { return upload.filename }
        return title
    }
    var isVideo: Bool { upload.mediaType == "video" }
}

/// The owner's comment feed, apart from the app so it can be checked
/// without a real token or Worker.
nonisolated enum CloudCommentList {
    struct Page: Decodable {
        let comments: [CloudComment]
        let next: Int?
    }

    static let pageSize = 500

    static func request(workerBase: String, token: String, offset: Int) -> URLRequest? {
        var components = URLComponents(string: workerBase + "/api/comments")
        components?.queryItems = [
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        guard let url = components?.url, url.host != nil else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func decode(_ data: Data) throws -> Page {
        try CloudUploadList.decoder.decode(Page.self, from: data)
    }

    /// Bearer DELETE /api/comments/:uploadId/:commentId, the owner's route.
    static func deleteRequest(workerBase: String, token: String, uploadID: String, commentID: String) -> URLRequest? {
        guard CloudPreviewCache.isSafeID(uploadID), CloudPreviewCache.isSafeID(commentID),
              let url = URL(string: "\(workerBase)/api/comments/\(uploadID)/\(commentID)"), url.host != nil else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The share page, opening a video at the comment's moment (?t=, in
    /// whole seconds, which the share page seeks to).
    static func shareLink(for comment: CloudComment) -> URL? {
        guard var components = URLComponents(string: comment.upload.shareUrl),
              components.scheme == "https" || components.scheme == "http",
              components.host?.isEmpty == false else { return nil }
        if comment.isVideo, let seconds = comment.timestamp, seconds.isFinite, seconds >= 0 {
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: "t", value: String(Int(min(seconds, Double(Int.max / 2)))))
            ]
        }
        return components.url
    }
}

/// What has been read in the comment inbox for one Worker: the newest
/// creation time marked read, and the comments marked read at exactly that
/// second, since times have whole-second resolution and ids are random.
/// ponytail: a comment stored later with an earlier second than the
/// watermark counts as read; a server read state if that ever matters.
nonisolated struct CommentWatermark: Codable, Equatable, Sendable {
    var createdAt: Date
    var ids: Set<String>

    func isUnread(_ comment: CloudComment) -> Bool {
        comment.createdAt > createdAt || (comment.createdAt == createdAt && !ids.contains(comment.id))
    }

    /// `old` with every comment in `comments` marked read as well.
    static func reading(_ comments: [CloudComment], after old: CommentWatermark?) -> CommentWatermark? {
        guard let newest = comments.map(\.createdAt).max() else { return old }
        if let old, old.createdAt > newest { return old }
        var ids = Set(comments.filter { $0.createdAt == newest }.map(\.id))
        if let old, old.createdAt == newest { ids.formUnion(old.ids) }
        return CommentWatermark(createdAt: newest, ids: ids)
    }
}
