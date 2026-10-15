import AVFoundation
import Foundation
import Testing

private final class MusicFixtureBundle: NSObject {}

// Exercise preview state without connecting an item to transport or sound output.
nonisolated private final class SilentMusicPlayer: AVPlayer, @unchecked Sendable {
    override func play() {}
    override func replaceCurrentItem(with item: AVPlayerItem?) {}
}

nonisolated private final class MusicURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: (Int, Data)] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var delayed = Set<String>()
    nonisolated(unsafe) private static var pending: [String: MusicURLProtocol] = [:]
    nonisolated(unsafe) private static var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    static func configure(_ values: [String: (Int, Data)]) {
        lock.withLock { replies = values; recorded = []; delayed = []; pending = [:] }
    }
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func delay(_ url: String) { _ = lock.withLock { delayed.insert(url) } }
    static func waitForRequest(_ url: String) async {
        await withCheckedContinuation { continuation in
            let started = lock.withLock {
                if recorded.contains(where: { $0.url?.absoluteString == url }) { return true }
                waiters[url, default: []].append(continuation)
                return false
            }
            if started { continuation.resume() }
        }
    }
    static func release(_ url: String) {
        let response = lock.withLock { pending.removeValue(forKey: url) }
        if let response { response.client?.urlProtocolDidFinishLoading(response) }
    }
    static func isPending(_ url: String) -> Bool { lock.withLock { pending[url] != nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.url!.absoluteString
        let (reply, delayed, waiters) = Self.lock.withLock {
            Self.recorded.append(request)
            let delayed = Self.delayed.contains(key)
            if delayed { Self.pending[key] = self }
            return (Self.replies[key] ?? (500, Data()), delayed, Self.waiters.removeValue(forKey: key) ?? [])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil,
                                       headerFields: ["Content-Type": request.url!.host == "eu.data.freetouse.com"
                                                      ? "application/octet-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.1)
        if !delayed { client?.urlProtocolDidFinishLoading(self) }
        for waiter in waiters { waiter.resume() }
    }
    override func stopLoading() {
        _ = Self.lock.withLock { Self.pending.removeValue(forKey: request.url!.absoluteString) }
    }
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

    private func firstTrack() throws -> FreeToUseMusicAPI.Track {
        let page = try JSONDecoder().decode(FreeToUseMusicAPI.Page<FreeToUseMusicAPI.Track>.self,
                                           from: fixture("search-instrumental"))
        return try #require(page.data.first)
    }

    private func audioData() throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("music-test-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][frame] = 0.1 * sin(Float(frame) * 0.05)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
        return try Data(contentsOf: url)
    }

    private func musicTemporaryFiles() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("freetouse-") })
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

    @Test("A nonempty invalid download stays inline with Retry; valid audio reaches the callback")
    func validatesDownloadedAudio() async throws {
        let track = try firstTrack()
        let mp3 = try #require(track.mp3URL).absoluteString
        let model = FreeToUseMusicPickerModel(api: client([mp3: (200, Data("<html>Maintenance</html>".utf8))]))
        defer { model.close() }
        var callbacks = 0
        var dismissals = 0
        model.use(track, setBackgroundMusic: { _, _, _, _ in callbacks += 1 }, dismiss: { dismissals += 1 })
        await model.downloadTask?.value
        #expect(callbacks == 0)
        #expect(dismissals == 0)
        #expect(model.failedDownloadID == track.id)
        #expect(model.downloadError?.contains("didn't send an MP3") == true)
        #expect(model.downloadingID == nil)

        let data = try audioData()
        MusicURLProtocol.configure([mp3: (200, data)])
        var adopted: URL?
        model.use(track, setBackgroundMusic: { fileURL, name, credit, offset in
            adopted = fileURL
            #expect((try? Data(contentsOf: fileURL)) == data)
            #expect(name == track.displayName)
            #expect(credit == track.credit)
            #expect(offset == 0)
            callbacks += 1
        }, dismiss: { dismissals += 1 })
        await model.downloadTask?.value
        #expect(callbacks == 1)
        #expect(dismissals == 1)
        #expect(model.downloadError == nil)
        #expect(!FileManager.default.fileExists(atPath: try #require(adopted).path))
    }

    @Test("A delayed old search cannot replace a newer search or category", .timeLimit(.minutes(1)), arguments: [false, true])
    func newerSelectionWins(_ category: Bool) async throws {
        let oldURL = url("music/tracks/search", query: "old")
        let newBrowse: FreeToUseMusicAPI.Browse = category
            ? .category(.init(id: "calm", name: "Calm", type: "Mood")) : .search("new")
        let newURL = category ? url("music/categories/calm/tracks") : url("music/tracks/search", query: "new")
        let oldData = try trackData { $0[0]["title"] = "Old result" }
        let newData = try trackData { $0[0]["title"] = "New result" }
        let model = FreeToUseMusicPickerModel(api: client([oldURL: (200, oldData), newURL: (200, newData)]))
        defer { model.close(); MusicURLProtocol.release(oldURL) }
        MusicURLProtocol.delay(oldURL)
        model.browse = .search("old")
        let old = Task { await model.loadTracks() }
        await MusicURLProtocol.waitForRequest(oldURL)
        model.browse = newBrowse
        await model.loadTracks()
        #expect(model.tracks.first?.title == "New result")
        MusicURLProtocol.release(oldURL)
        await old.value
        #expect(model.tracks.first?.title == "New result")
        #expect(model.nextOffset == 5)
        #expect(model.tracksError == nil)
        #expect(!model.isLoading)
    }

    @Test("An old search error stays hidden after a chip changes, before its new request starts", .timeLimit(.minutes(1)))
    func staleErrorAfterChip() async {
        let oldURL = url("music/tracks/search", query: "old")
        let model = FreeToUseMusicPickerModel(api: client([oldURL: (503, Data())]))
        defer { model.close(); MusicURLProtocol.release(oldURL) }
        MusicURLProtocol.delay(oldURL)
        model.browse = .search("old")
        let old = Task { await model.loadTracks() }
        await MusicURLProtocol.waitForRequest(oldURL)
        model.select(.init(id: "calm", name: "Calm", type: "Mood"))
        MusicURLProtocol.release(oldURL)
        await old.value
        #expect(model.tracksError == nil)
        #expect(model.tracks.isEmpty)
    }

    @Test("Closing a suspended download cancels transport, skips callback and leaves no owned temp file", .timeLimit(.minutes(1)))
    func closeSuspendedDownload() async throws {
        let track = try firstTrack()
        let mp3 = try #require(track.mp3URL).absoluteString
        let before = try musicTemporaryFiles()
        let model = FreeToUseMusicPickerModel(api: client([mp3: (200, try audioData())]))
        defer { model.close(); MusicURLProtocol.release(mp3) }
        MusicURLProtocol.delay(mp3)
        var callbacks = 0
        var dismissals = 0
        model.use(track, setBackgroundMusic: { _, _, _, _ in callbacks += 1 }, dismiss: { dismissals += 1 })
        let download = try #require(model.downloadTask)
        await MusicURLProtocol.waitForRequest(mp3)
        #expect(MusicURLProtocol.isPending(mp3))
        model.close()
        await download.value
        MusicURLProtocol.release(mp3)
        #expect(!MusicURLProtocol.isPending(mp3))
        #expect(callbacks == 0)
        #expect(dismissals == 0)
        #expect(model.downloadError == nil)
        #expect(model.downloadingID == nil)
        #expect(try musicTemporaryFiles() == before)
    }

    @Test("Download Retry preserves the explicit seek, and a synchronous receiver copies before cleanup", .timeLimit(.minutes(1)), arguments: [false, true])
    func retryAndSynchronousCopy(_ explicitSeek: Bool) async throws {
        let track = try firstTrack()
        let mp3 = try #require(track.mp3URL).absoluteString
        let before = try musicTemporaryFiles()
        let preview = FreeToUseMusicPreview(player: SilentMusicPlayer())
        let model = FreeToUseMusicPickerModel(api: client([mp3: (503, Data())]), preview: preview)
        defer { model.close() }
        preview.toggle(track)
        preview.updatePlaybackPosition(10, duration: track.duration)
        if explicitSeek { preview.scrubPosition = 20 }
        preview.updatePlaybackPosition(25, duration: track.duration)
        model.use(track, setBackgroundMusic: { _, _, _, _ in Issue.record("Failed download called receiver") },
                  dismiss: { Issue.record("Failed download dismissed") })
        await model.downloadTask?.value
        #expect(model.failedDownloadID == track.id)
        #expect(preview.trackID == nil)

        let data = try audioData()
        MusicURLProtocol.configure([mp3: (200, data)])
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("music-copy-\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: copy) }
        var adopted: URL?
        var callbacks = 0
        var dismissals = 0
        model.use(track, setBackgroundMusic: { fileURL, _, _, offset in
            adopted = fileURL
            #expect(offset == (explicitSeek ? 20 : 0))
            do { try FileManager.default.copyItem(at: fileURL, to: copy) }
            catch { Issue.record(error) }
            callbacks += 1
        }, dismiss: { dismissals += 1 })
        await model.downloadTask?.value
        #expect(callbacks == 1)
        #expect(dismissals == 1)
        #expect((try? Data(contentsOf: copy)) == data)
        #expect(!FileManager.default.fileExists(atPath: try #require(adopted).path))
        #expect(try musicTemporaryFiles() == before)
    }
}
