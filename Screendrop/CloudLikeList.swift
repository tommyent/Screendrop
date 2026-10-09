import Foundation

/// One like on a share page, as Bearer GET /api/likes lists it
/// (SPEC-share-v2.md section 9). Likes are anonymous: no viewer or author
/// comes back, so the app says "Someone". Unliking removes the row; liking
/// again is a new like with a new id.
nonisolated struct CloudLike: CloudFeedItem, Hashable, Decodable {
    let id: String
    let uploadId: String
    let createdAt: Date
    /// The same summary the comment feed carries.
    let upload: CloudComment.Upload

    var uploadName: String {
        guard let title = upload.title, !title.isEmpty else { return upload.filename }
        return title
    }
    var isVideo: Bool { upload.mediaType == "video" }
}

/// The owner's like feed, apart from the app so it can be checked without a
/// real token or Worker. Paging and order are the comment feed's.
nonisolated enum CloudLikeList {
    struct Page: Decodable {
        let likes: [CloudLike]
        let next: Int?
    }

    static func request(workerBase: String, token: String, offset: Int) -> URLRequest? {
        CloudCommentList.listRequest(path: "/api/likes", workerBase: workerBase, token: token, offset: offset)
    }

    static func decode(_ data: Data) throws -> Page {
        try CloudUploadList.decoder.decode(Page.self, from: data)
    }

    /// The upload's canonical share page; a like has no moment to open at.
    static func shareLink(for like: CloudLike) -> URL? {
        guard let url = URL(string: like.upload.shareUrl),
              url.scheme == "https" || url.scheme == "http", url.host?.isEmpty == false else { return nil }
        return url
    }
}
