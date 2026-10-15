import Foundation
import Testing

nonisolated private final class NarrativeStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let malformed = request.url!.path.contains("malformed")
        let content = malformed ? "not JSON" : #"{"title":"A useful title","summary":"A factual summary of the narration."}"#
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
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
        #expect(throws: (any Error).self) { try RecordingNarrativeGenerator.validated(.init(title: "X", summary: String(repeating: "x", count: 401))) }
    }

    @Test func localServerPrecedesAppleAndPreservesChapterIDs() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        let id = UUID()
        let result = try await RecordingNarrativeGenerator.generate(.init(text: "Opening narration.", chapters: [.init(id: id, text: "Chapter narration.")]), server: RecordingModelServer(url: "http://localhost/v1", model: "fixture"), session: session, apple: { _ in
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
        let apple = try await RecordingNarrativeGenerator.generate(input, server: server, session: session, apple: { _ in .init(title: "Apple title", summary: "Apple summary") })
        #expect(apple.source == "Apple on-device model")
        let rules = try await RecordingNarrativeGenerator.generate(input, server: server, session: session, apple: { _ in throw RecordingNarrativeGenerator.Failure.unavailable })
        #expect(rules.title == "Opening sentence")
        #expect(rules.summary.isEmpty && rules.chapterTitles.isEmpty)
    }

    @Test func longNarrationUsesEveryChunkBeforeSummaryReduction() async throws {
        let text = String(repeating: "A narration sentence. ", count: 1000)
        let requests = NarrativeRequests()
        let result = try await RecordingNarrativeGenerator.generate(.init(text: text, chapters: []), server: nil, apple: { chunk in
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
            try await RecordingNarrativeGenerator.generate(.init(text: text, chapters: []), server: nil, apple: { _ in
                try await Task.sleep(for: .seconds(30))
                return .init(title: "Should not return", summary: "Canceled")
            })
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation cannot fall back to a successful suggestion") }
        catch { #expect(error is CancellationError) }
    }
}
