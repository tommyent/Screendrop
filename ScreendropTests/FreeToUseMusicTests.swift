import Foundation
import Testing

private final class MusicFixtureBundle: NSObject {}

nonisolated private final class MusicURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: (Int, Data)] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func configure(_ values: [String: (Int, Data)]) {
        lock.withLock { replies = values; recorded = [] }
    }
    static var requests: [URLRequest] { lock.withLock { recorded } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.replies[request.url!.absoluteString] ?? (500, Data())
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor
struct FreeToUseMusicTests {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: MusicFixtureBundle.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "json", subdirectory: "FreeToUse")
                               ?? bundle.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
    private func client(_ replies: [String: (Int, Data)]) -> FreeToUseMusicAPI {
        MusicURLProtocol.configure(replies)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MusicURLProtocol.self]
        return FreeToUseMusicAPI(session: URLSession(configuration: config))
    }
    private func url(_ path: String, query: String? = nil, offset: Int = 0, limit: Int = 25) -> String {
        FreeToUseMusicAPI.request(path: path, query: query, offset: offset, limit: limit).url!.absoluteString
    }
    private func trackData(_ mutate: (inout [[String: Any]]) -> Void) throws -> Data {
        var json = try #require(JSONSerialization.jsonObject(with: fixture("search-instrumental")) as? [String: Any])
        var tracks = try #require(json["data"] as? [[String: Any]])
        mutate(&tracks)
        json["data"] = tracks
        return try JSONSerialization.data(withJSONObject: json)
    }

    @Test("Real category fixtures paginate through all three groups")
    func categories() async throws {
        let api = client([
            url("music/categories/all", limit: 50): (200, try fixture("categories-page-1")),
            url("music/categories/all", offset: 50, limit: 50): (200, try fixture("categories-page-2"))
        ])
        let categories = try await api.categories()
        #expect(categories.count == 67)
        #expect(Set(categories.map(\.type)) == ["Mood", "Genre", "Video"])
        #expect(categories.contains { $0.name == "Vlog" && $0.type == "Video" })
        #expect(MusicURLProtocol.requests.count == 2)
    }

    @Test("Real tracks decode ordered artists, tags, duration, MP3 and exact credit")
    func tracks() throws {
        let page = try JSONDecoder().decode(FreeToUseMusicAPI.Page<FreeToUseMusicAPI.Track>.self,
                                           from: fixture("search-instrumental"))
        let track = try #require(page.data.first)
        #expect(track.title == "Grace")
        #expect(track.artist == "Johny Grimes")
        #expect(track.firstTags == "instrumental")
        #expect(track.duration == 131.08173)
        #expect(track.isUsable)
        #expect(track.mp3URL?.host == "eu.data.freetouse.com")
        #expect(track.credit == "“Grace” by Johny Grimes · Music from Free To Use: https://freetouse.com/music")
        #expect(page.nextOffset == 5)
    }

    @Test("The picker hides premium and unsafe tracks without changing the raw pagination offset")
    func premiumFiltering() async throws {
        let data = try trackData { tracks in
            tracks[0]["is_premium"] = true
            tracks[1]["files"] = ["mp3": "http://eu.data.freetouse.com/music.mp3"]
            tracks[2]["files"] = ["mp3": "https://eu.data.freetouse.com.evil.test/music.mp3"]
        }
        let model = FreeToUseMusicPickerModel(api: client([url("music/tracks/all"): (200, data)]))
        await model.loadTracks()
        #expect(model.tracks.map(\.title) == ["Broken", "Sleepy"])
        #expect(model.nextOffset == 5)
        model.close()
    }

    @Test("Artist and tag sequence numbers determine their display order")
    func order() throws {
        let data = try trackData { tracks in
            tracks[0]["artists"] = [[4, ["name": "Second"]], [0, ["name": "First"]]]
            tracks[0]["tags"] = [[3, "third"], [1, "first"], [2, "second"]]
        }
        let page = try JSONDecoder().decode(FreeToUseMusicAPI.Page<FreeToUseMusicAPI.Track>.self, from: data)
        let track = try #require(page.data.first)
        #expect(track.artist == "First, Second")
        #expect(track.firstTags == "first · second")
    }

    @Test("Search uses the whole catalogue, encodes special characters and clears category selection")
    func search() async throws {
        let query = "calm & piano + café"
        let api = client([url("music/tracks/search", query: query): (200, try fixture("search-instrumental"))])
        let model = FreeToUseMusicPickerModel(api: api)
        model.select(FreeToUseMusicAPI.Category(id: "category", name: "Calm", type: "Mood"))
        model.searchText = "  \(query)  "
        model.search()
        #expect(model.browse == .search(query))
        await model.loadTracks()
        let request = try #require(MusicURLProtocol.requests.first)
        #expect(request.url?.path == "/v3/music/tracks/search")
        let items = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first { $0.name == "query" }?.value == query)
        #expect(items?.first { $0.name == "limit" }?.value == "25")
        model.searchText = ""
        model.search()
        #expect(model.browse == .all)
        model.close()
    }

    @Test("Use offsets ignore the first half second and leave audio at the track end")
    func offsets() throws {
        let page = try JSONDecoder().decode(FreeToUseMusicAPI.Page<FreeToUseMusicAPI.Track>.self,
                                           from: fixture("search-instrumental"))
        let track = try #require(page.data.first)
        #expect(track.startOffset(at: 0.5) == 0)
        #expect(track.startOffset(at: 10.25) == 10.25)
        #expect(track.startOffset(at: track.duration) == track.duration - 1)
        #expect(track.startOffset(at: .nan) == 0)
        #expect(track.startOffset(at: -.infinity) == 0)
    }

    @Test("Listening advances the scrub bar but only an explicit seek chooses the music start")
    func listeningDoesNotChooseStart() {
        let preview = FreeToUseMusicPreview()
        preview.updatePlaybackPosition(10, duration: 131)
        #expect(preview.position == 10)
        #expect(preview.selectionPosition == 0)
        preview.scrubPosition = 20
        preview.updatePlaybackPosition(25, duration: 131)
        #expect(preview.position == 25)
        #expect(preview.selectionPosition == 20)
        preview.stop()
        #expect(preview.selectionPosition == 0)
    }

    @Test("Server and malformed responses produce inline errors and permit retry")
    func errorsAndRetry() async throws {
        let api = client([url("music/tracks/all"): (503, Data())])
        let model = FreeToUseMusicPickerModel(api: api)
        await model.loadTracks()
        #expect(model.tracksError?.contains("503") == true)
        MusicURLProtocol.configure([url("music/tracks/all"): (200, Data("{}".utf8))])
        await model.loadTracks()
        #expect(model.tracksError?.contains("unreadable") == true)
        MusicURLProtocol.configure([url("music/tracks/all"): (200, try fixture("search-instrumental"))])
        await model.loadTracks()
        #expect(model.tracksError == nil)
        #expect(model.tracks.count == 5)
        #expect(!model.isLoading)
        #expect(FreeToUseMusicAPI.message(for: URLError(.notConnectedToInternet)).contains("internet connection"))
        model.close()
    }

    @Test("A premium-only page still offers the next page, and repeated track IDs stay unique")
    func pagination() async throws {
        let first = try trackData { tracks in
            for index in tracks.indices { tracks[index]["is_premium"] = true }
        }
        var secondJSON = try #require(JSONSerialization.jsonObject(with: fixture("search-instrumental")) as? [String: Any])
        secondJSON["pagination"] = ["offset": 5, "count": 10, "limit": 5]
        var secondTracks = try #require(secondJSON["data"] as? [[String: Any]])
        secondTracks[1] = secondTracks[0]
        secondJSON["data"] = secondTracks
        let second = try JSONSerialization.data(withJSONObject: secondJSON)
        let model = FreeToUseMusicPickerModel(api: client([
            url("music/tracks/all"): (200, first),
            url("music/tracks/all", offset: 5): (200, second)
        ]))
        await model.loadTracks()
        #expect(model.tracks.isEmpty)
        #expect(model.nextOffset == 5)
        await model.loadTracks(reset: false)
        #expect(model.tracks.count == 4)
        #expect(model.nextOffset == nil)
        #expect(MusicURLProtocol.requests.count == 2)
        model.close()
    }

    @Test("Category requests use the category endpoint and never become a full catalogue fetch")
    func categoryEndpoint() async throws {
        let page = try JSONDecoder().decode(FreeToUseMusicAPI.Page<FreeToUseMusicAPI.Category>.self,
                                           from: fixture("categories-page-1"))
        let category = try #require(page.data.first)
        let path = "music/categories/\(category.id)/tracks"
        let api = client([url(path): (200, try fixture("search-instrumental"))])
        let tracks = try await api.tracks(in: .category(category))
        #expect(tracks.data.count == 5)
        #expect(MusicURLProtocol.requests.first?.url?.path == "/v3/\(path)")
    }

    @Test("Closing or cancelling before a load makes no request and publishes no error")
    func cancellation() async {
        let model = FreeToUseMusicPickerModel(api: client([:]))
        let task = Task { await model.loadTracks() }
        task.cancel()
        await task.value
        model.close()
        await model.loadTracks()
        await model.loadCategories()
        #expect(MusicURLProtocol.requests.isEmpty)
        #expect(model.tracksError == nil)
        #expect(model.categoriesError == nil)
        #expect(!model.isLoading)
    }
}
