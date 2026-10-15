import Foundation
import Testing

nonisolated private final class NarrativeStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path.contains("timeout") {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let malformed = path.contains("malformed")
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let titleOnly = path.contains("title-only") || payload?["max_tokens"] as? Int == 128
        let messages = payload?["messages"] as? [[String: String]]
        let failedChapter = path.contains("chapter-failure") && titleOnly && messages?.last?["content"] == "Okay so now"
        let content: String
        if malformed || (failedChapter && path.contains("chapter-failure-json")) { content = "not JSON" }
        else if failedChapter { content = "{}" }
        else if titleOnly { content = #"{"title":"A useful title"}"# }
        else { content = #"{"title":"A useful title","summary":"A factual summary of the narration."}"# }
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        let status = path.contains("http-error") || (failedChapter && path.contains("chapter-failure-http")) ? 503 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor NarrativeRequests {
    var inputs: [String] = []
    func record(_ text: String) { inputs.append(text) }
}

@MainActor
struct RecordingNarrativeTests {
    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NarrativeStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func modelServerURLsAndResponseValidation() throws {
        for url in ["http://localhost:11434", "http://localhost:11434/v1/", "http://localhost:11434/v1/chat/completions"] {
            #expect(try RecordingModelServer(url: url, model: "llama3.2:3b").url.absoluteString == "http://localhost:11434/v1/chat/completions")
        }
        for url in ["file:///tmp/server", "https://name:password@localhost/v1", "http://localhost/v1?secret=x", "localhost"] {
            #expect(throws: (any Error).self) { try RecordingModelServer(url: url, model: "model") }
        }
        #expect(throws: (any Error).self) { try RecordingNarrativeGenerator.validated(.init(title: "", summary: "X")) }
        let clamped = try RecordingNarrativeGenerator.validated(.init(title: String(repeating: "🎥", count: 90), summary: String(repeating: "x", count: 401)))
        #expect(clamped.title.count == 80 && clamped.summary.count == 400)
        #expect(try RecordingNarrativeGenerator.validated(.init(title: "Name", summary: ""), fields: .title).title == "Name")
        #expect(try RecordingNarrativeGenerator.validated(.init(title: "", summary: "Summary"), fields: .summary).summary == "Summary")
    }

    @Test func localServerPrecedesAppleAndPreservesChapterIDs() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        let id = UUID()
        let result = try await RecordingNarrativeGenerator.generate(.init(text: "Opening narration.", chapters: [.init(id: id, text: "Chapter narration.")]), server: RecordingModelServer(url: "http://localhost/v1", model: "fixture"), session: session, apple: { _, _ in
            Issue.record("Apple must not run after a successful local server")
            throw RecordingNarrativeGenerator.Failure.unavailable
        })
        #expect(result.source == "Local model server")
        #expect(result.title == "A useful title")
        #expect(result.chapterTitles == [id: "A useful title"])
    }

    @Test func malformedServerFallsBackToAppleThenRules() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        let input = RecordingNarrativeInput(text: "Opening sentence. Another sentence.", chapters: [])
        let server = try RecordingModelServer(url: "http://localhost/malformed/v1", model: "fixture")
        let apple = try await RecordingNarrativeGenerator.generate(input, server: server, session: session, apple: { _, _ in .init(title: "Apple title", summary: "Apple summary") })
        #expect(apple.source == "Local model server failed: bad JSON; used Apple on-device model")
        let rules = try await RecordingNarrativeGenerator.generate(input, server: server, session: session, apple: { _, _ in throw RecordingNarrativeGenerator.Failure.unavailable })
        #expect(rules.title == "Opening sentence")
        #expect(rules.summary.isEmpty && rules.chapterTitles.isEmpty)
        #expect(rules.source.contains("Local model server failed: bad JSON; used Opening-sentence title"))
        #expect(!rules.source.contains("pause-based"))
    }

    @Test func failingChapterKeepsOtherServerSuggestions() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        let first = UUID(), thin = UUID(), last = UUID()
        let input = RecordingNarrativeInput(text: "Choose an export preset. Save the recording.", chapters: [
            .init(id: first, text: "Choose an export preset."),
            .init(id: thin, text: "Okay so now"),
            .init(id: last, text: "Save the recording.")
        ])
        for failure in ["missing", "http", "json"] {
            let result = try await RecordingNarrativeGenerator.generate(input,
                server: RecordingModelServer(url: "http://localhost/chapter-failure-\(failure)/v1", model: "fixture"), session: session,
                apple: { _, _ in
                    Issue.record("A failed chapter must not discard the successful server title and summary")
                    throw RecordingNarrativeGenerator.Failure.unavailable
                })
            #expect(result.source == "Local model server")
            #expect(result.title == "A useful title" && result.summary == "A factual summary of the narration.")
            #expect(result.chapterTitles == [first: "A useful title", last: "A useful title"])
        }
    }

    @Test func chapterCancellationStopsGeneration() async throws {
        do {
            _ = try await RecordingNarrativeGenerator.generate(.init(text: "Narration.", chapters: [.init(id: UUID(), text: "Chapter.")]), server: nil, apple: { _, fields in
                if fields == .title { throw CancellationError() }
                return .init(title: "Title", summary: "Summary")
            })
            Issue.record("Chapter cancellation must not return partial suggestions")
        } catch { #expect(error is CancellationError) }
    }

    @Test func titleOnlyServerResponsesAndFailureReasons() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        let title = try await RecordingNarrativeGenerator.serverText("Name this chapter", server: RecordingModelServer(url: "http://localhost/title-only/v1", model: "fixture"), fields: .title, session: session)
        #expect(title.title == "A useful title" && title.summary.isEmpty)
        for (path, reason) in [("http-error", "HTTP 503"), ("timeout", "timed out")] {
            let result = try await RecordingNarrativeGenerator.generate(.init(text: "Narration.", chapters: []), server: RecordingModelServer(url: "http://localhost/\(path)/v1", model: "fixture"), session: session, apple: { _, _ in .init(title: "Apple title", summary: "Apple summary") })
            #expect(result.source.localizedCaseInsensitiveContains(reason))
            #expect(result.source.contains("; used Apple on-device model"))
        }
    }

    @Test func cachedInputFollowsCueWordClipAndChapterEdits() {
        var cache = RecordingNarrativeInputCache()
        var source = RecordingNarrativeInputCache.Source(cues: [.init(start: 1, end: 2, text: "Original narration")], words: [], timeline: .full(sourceDuration: 10), chapters: [RecordingChapter(title: "Original", start: 0, autoTitle: true)])
        let original = cache.input(for: source)
        #expect(cache.input(for: source) == original)
        source.cues[0].text = "Corrected narration"
        #expect(cache.input(for: source).text == "Corrected narration")
        #expect(cache.visibleChapters.first?.title == "Corrected narration")
        source.timeline = .init(segments: [.init(sourceStart: 0, sourceEnd: 1), .init(sourceStart: 2, sourceEnd: 10)])
        #expect(cache.input(for: source).text.isEmpty)
        let manual = RecordingChapter(title: "Manual", start: 4)
        source.chapters = [manual]
        #expect(cache.input(for: source).chapters.map(\.id) == [manual.id])
        #expect(cache.visibleChapters.first?.title == "Manual")

        source.cues = [.init(start: 0, end: 3, text: "public")]
        source.timeline = .init(segments: [.init(sourceStart: 1.5, sourceEnd: 5)])
        #expect(cache.input(for: source).text.isEmpty)
        source.words = [.init(text: "Private ", start: 0, end: 1), .init(text: "public", start: 2, end: 3)]
        #expect(cache.input(for: source).text == "public")
    }

    @Test func longNarrationUsesEveryChunkBeforeSummaryReduction() async throws {
        let text = String(repeating: "A narration sentence. ", count: 1000)
        let requests = NarrativeRequests()
        let result = try await RecordingNarrativeGenerator.generate(.init(text: text, chapters: []), server: nil, apple: { chunk, _ in
            await requests.record(chunk)
            return .init(title: "Narration", summary: "A bounded summary.")
        })
        let inputs = await requests.inputs
        let chunkCount = RecordingNarrativeGenerator.chunks(text).count
        #expect(inputs.prefix(chunkCount).joined() == text)
        #expect(inputs.count > chunkCount)
        #expect(result.summary == "A bounded summary.")
    }

    @Test func chunkingPreservesAllUnicodeTextAndCancellationStopsFallback() async throws {
        let text = String(repeating: "Narration 🎥. ", count: 1500)
        let chunks = RecordingNarrativeGenerator.chunks(text)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.count <= 2000 })
        let task = Task {
            try await RecordingNarrativeGenerator.generate(.init(text: text, chapters: []), server: nil, apple: { _, _ in
                try await Task.sleep(for: .seconds(30))
                return .init(title: "Should not return", summary: "Canceled")
            })
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation cannot fall back to a successful suggestion") }
        catch { #expect(error is CancellationError) }
    }
}
