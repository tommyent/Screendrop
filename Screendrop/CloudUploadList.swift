import Foundation

/// One upload on the Worker, as GET /api/uploads lists it. Uploads listed
/// from History instead, for a Worker without that route, have no size,
/// views or remote thumbnail.
nonisolated struct CloudUpload: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let url: String
    let title: String?
    let filename: String
    let mediaType: String
    let size: Int?
    let duration: Double?
    let createdAt: Date
    let views: Int?
    let thumbnailUrl: String?

    var isVideo: Bool { mediaType == "video" }
    var name: String {
        guard let title, !title.isEmpty else { return filename }
        return title
    }
    var kindTitle: String { isVideo ? "Recording" : "Screenshot" }
}

/// The request and response of GET /api/uploads, apart from the app so the
/// request can be checked without a real token or Worker.
nonisolated enum CloudUploadList {
    struct Page: Decodable {
        let uploads: [CloudUpload]
        let next: Int?
    }

    static let pageSize = 500

    /// `workerBase` is the normalized Worker origin, such as
    /// "https://screendrop-worker.example.workers.dev".
    static func request(workerBase: String, token: String, offset: Int) -> URLRequest? {
        var components = URLComponents(string: workerBase + "/api/uploads")
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Page.self, from: data)
    }

    /// The upload ID in a share link, its last path component.
    static func uploadID(of link: String?) -> String? {
        guard let link, let id = URL(string: link)?.lastPathComponent, !id.isEmpty, id != "/" else { return nil }
        return id
    }
}
