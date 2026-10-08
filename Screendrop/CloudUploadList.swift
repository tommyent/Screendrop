import Foundation

/// One upload on the Worker, as GET /api/uploads lists it. Uploads listed
/// from History instead, for a Worker without that route, have no size,
/// views or remote thumbnail, and no share settings.
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
    /// Nil: the link never expires.
    var expiresAt: Date? = nil
    var allowAnonymousComments: Bool? = nil
    var socialEnabled: Bool? = nil
    /// The Worker lists `expiresAt` (null included), so it can also change
    /// the expiry and anonymous comments. Older Workers leave it out.
    var supportsShareSettings = false

    var isVideo: Bool { mediaType == "video" }
    var name: String {
        guard let title, !title.isEmpty else { return filename }
        return title
    }
    var kindTitle: String { isVideo ? "Recording" : "Screenshot" }
}

extension CloudUpload {
    private nonisolated enum CodingKeys: String, CodingKey {
        case id, url, title, filename, mediaType, size, duration, createdAt, views, thumbnailUrl
        case expiresAt, allowAnonymousComments, socialEnabled
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            url: try c.decode(String.self, forKey: .url),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            filename: try c.decode(String.self, forKey: .filename),
            mediaType: try c.decode(String.self, forKey: .mediaType),
            size: try c.decodeIfPresent(Int.self, forKey: .size),
            duration: try c.decodeIfPresent(Double.self, forKey: .duration),
            createdAt: try c.decode(Date.self, forKey: .createdAt),
            views: try c.decodeIfPresent(Int.self, forKey: .views),
            thumbnailUrl: try c.decodeIfPresent(String.self, forKey: .thumbnailUrl),
            expiresAt: try c.decodeIfPresent(Date.self, forKey: .expiresAt),
            allowAnonymousComments: try c.decodeIfPresent(Bool.self, forKey: .allowAnonymousComments),
            socialEnabled: try c.decodeIfPresent(Bool.self, forKey: .socialEnabled),
            supportsShareSettings: c.contains(.expiresAt)
        )
    }
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
        try decoder.decode(Page.self, from: data)
    }

    /// One upload, as PATCH /api/upload/:id answers.
    static func decodeUpload(_ data: Data) throws -> CloudUpload {
        try decoder.decode(CloudUpload.self, from: data)
    }

    /// ISO 8601 dates, with or without fractional seconds: JavaScript's
    /// `toISOString()` writes milliseconds.
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
                ?? (try? Date.ISO8601FormatStyle().parse(text)) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
        }
        return decoder
    }

    /// PUT /api/upload headers for the share settings. No expiry header
    /// means the link never expires.
    static func applyShareSettings(to request: inout URLRequest, expiresAt: Date?, allowAnonymousComments: Bool) {
        if let expiresAt { request.setValue(expiresAt.formatted(.iso8601), forHTTPHeaderField: "X-Expires-At") }
        request.setValue(allowAnonymousComments ? "true" : "false", forHTTPHeaderField: "X-Allow-Anonymous-Comments")
    }

    /// An expiry was asked for, but the upload response doesn't carry one:
    /// a Worker from before expiry ignored the header, so the link won't expire.
    static func expiryIgnored(requested: Date?, response: [String: Any]?) -> Bool {
        requested != nil && !(response?["expiresAt"] is String)
    }

    /// Bearer PATCH /api/upload/:id. `expiresAt` is left out when nil, and
    /// `.some(nil)` clears it, so the link never expires.
    static func patchRequest(workerBase: String, token: String, id: String,
                             expiresAt: Date?? = nil, allowAnonymousComments: Bool? = nil) -> URLRequest? {
        guard CloudPreviewCache.isSafeID(id),
              let url = URL(string: workerBase + "/api/upload/" + id), url.host != nil else { return nil }
        var body: [String: Any] = [:]
        if let expiresAt { body["expiresAt"] = expiresAt.map { $0.formatted(.iso8601) } ?? NSNull() }
        if let allowAnonymousComments { body["allowAnonymousComments"] = allowAnonymousComments }
        guard !body.isEmpty, let data = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }

    /// The upload ID in a share link, its last path component.
    static func uploadID(of link: String?) -> String? {
        guard let link, let id = URL(string: link)?.lastPathComponent, !id.isEmpty, id != "/" else { return nil }
        return id
    }
}
