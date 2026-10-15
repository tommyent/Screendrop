import Foundation

nonisolated struct FreeToUseMusicAPI: Sendable {
    struct Category: Decodable, Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let type: String
    }

    // The API represents ordered artists/tags as [sequence, value] pairs.
    struct Ordered<Value: Decodable & Sendable>: Decodable, Sendable {
        let sequence: Int
        let value: Value

        init(from decoder: Decoder) throws {
            var pair = try decoder.unkeyedContainer()
            sequence = try pair.decode(Int.self)
            value = try pair.decode(Value.self)
        }
    }

    struct Track: Decodable, Identifiable, Sendable {
        struct Artist: Decodable, Sendable { let name: String }
        struct Files: Decodable, Sendable { let mp3: URL? }

        let id: String
        let title: String
        let artists: [Ordered<Artist>]
        let tags: [Ordered<String>]
        let duration: TimeInterval
        let isPremium: Bool
        let files: Files

        enum CodingKeys: String, CodingKey {
            case id, title, artists, tags, duration, files
            case isPremium = "is_premium"
        }

        var artist: String {
            artists.sorted { $0.sequence < $1.sequence }.map(\.value.name).joined(separator: ", ")
        }
        var firstTags: String {
            tags.sorted { $0.sequence < $1.sequence }.prefix(2).map(\.value).joined(separator: " · ")
        }
        var displayName: String { "\(title) — \(artist)" }
        var credit: String { "“\(title)” by \(artist) · Music from Free To Use: https://freetouse.com/music" }
        var mp3URL: URL? {
            guard let url = files.mp3, url.scheme == "https",
                  let host = url.host, host.hasSuffix(".data.freetouse.com"),
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
            return url
        }
        var isUsable: Bool {
            !isPremium && mp3URL != nil && duration.isFinite && duration > 0 && !title.isEmpty && !artist.isEmpty
        }

        func startOffset(at position: TimeInterval) -> TimeInterval {
            guard position.isFinite, position > 0.5 else { return 0 }
            return min(position, max(0, duration - 1))
        }
    }

    struct Page<Item: Decodable & Sendable>: Decodable, Sendable {
        struct Pagination: Decodable, Sendable {
            let offset: Int
            let count: Int
        }
        let ok: Bool
        let data: [Item]
        let pagination: Pagination

        var nextOffset: Int? {
            let next = pagination.offset + data.count
            return !data.isEmpty && next < pagination.count ? next : nil
        }
    }

    enum Browse: Hashable, Sendable {
        case all
        case category(Category)
        case search(String)
    }

    enum Failure: LocalizedError {
        case http(Int), invalidResponse, unavailableTrack, invalidAudio

        var errorDescription: String? {
            switch self {
            case .http(let status): "Free To Use returned HTTP \(status). Try again."
            case .invalidResponse: "Free To Use sent an unreadable response. Try again."
            case .unavailableTrack: "That track isn't available with the free licence."
            case .invalidAudio: "Free To Use didn't send an MP3. Try again."
            }
        }
    }

    let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        self.session = session ?? URLSession(configuration: configuration)
    }

    func categories() async throws -> [Category] {
        var result: [Category] = []
        var offset = 0
        repeat {
            let page: Page<Category> = try await fetch(path: "music/categories/all", offset: offset, limit: 50)
            result += page.data
            guard let next = page.nextOffset else { break }
            offset = next
        } while true
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }
    }

    func tracks(in browse: Browse, offset: Int = 0) async throws -> Page<Track> {
        let path: String
        var query: String?
        switch browse {
        case .all: path = "music/tracks/all"
        case .category(let category): path = "music/categories/\(category.id)/tracks"
        case .search(let text): path = "music/tracks/search"; query = text
        }
        return try await fetch(path: path, query: query, offset: offset, limit: 25)
    }

    static func request(path: String, query: String? = nil, offset: Int, limit: Int) -> URLRequest {
        var components = URLComponents(string: "https://api.freetouse.com")!
        components.path = "/v3/\(path)"
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit)),
                                 URLQueryItem(name: "offset", value: String(offset))]
        if let query { components.queryItems?.append(URLQueryItem(name: "query", value: query)) }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func fetch<Item>(path: String, query: String? = nil, offset: Int, limit: Int) async throws -> Page<Item> {
        let (data, response) = try await session.data(for: Self.request(path: path, query: query, offset: offset, limit: limit))
        try Task.checkCancellation()
        try Self.check(response)
        let page: Page<Item>
        do { page = try JSONDecoder().decode(Page<Item>.self, from: data) }
        catch { throw Failure.invalidResponse }
        guard page.ok, page.pagination.offset == offset, page.pagination.count >= 0,
              !page.data.isEmpty || offset >= page.pagination.count else { throw Failure.invalidResponse }
        return page
    }

    func download(_ track: Track) async throws -> URL {
        guard track.isUsable, let url = track.mp3URL else { throw Failure.unavailableTrack }
        let (temporaryURL, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Task.checkCancellation()
        try Self.check(response)
        guard ["audio/mpeg", "audio/mp3", "application/octet-stream"].contains(response.mimeType ?? ""),
              (try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
            throw Failure.invalidAudio
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetouse-\(UUID().uuidString).mp3")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
    }

    static func message(for error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Can't reach Free To Use. Check your internet connection and retry."
            case .timedOut: return "Free To Use took too long to respond. Retry."
            default: break
            }
        }
        return error.localizedDescription
    }
}
