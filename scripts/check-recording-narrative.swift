// Compile with the five production sources listed in ScreendropTests/README.md.
import Foundation

@main struct RecordingNarrativeServerCheck {
    static func main() async throws {
        let base = CommandLine.arguments[1]
        let id = UUID()
        let input = RecordingNarrativeInput(text: "Choose an export preset. Save the recording.", chapters: [.init(id: id, text: "Choose the export preset.")])
        if CommandLine.arguments.count > 2 {
            let result = try await RecordingNarrativeGenerator.generate(input,
                server: RecordingModelServer(url: base, model: CommandLine.arguments[2]))
            precondition(result.source == "Local model server", result.source)
            precondition(!result.title.isEmpty && result.title.count <= 80)
            precondition(!result.summary.isEmpty && result.summary.count <= 400)
            precondition(result.chapterTitles[id]?.isEmpty == false && result.chapterTitles[id]!.count <= 80)
            print("PASS: real local model returned a bounded title, summary and chapter name")
            print("Title: \(result.title)\nSummary: \(result.summary)\nChapter: \(result.chapterTitles[id]!)")
            return
        }
        let good = try await RecordingNarrativeGenerator.generate(input, server: RecordingModelServer(url: base, model: "fixture"), apple: { _, _ in throw RecordingNarrativeGenerator.Failure.unavailable })
        precondition(good.source == "Local model server" && good.title == "Export settings")
        precondition(good.chapterTitles[id] == "Export settings" && !good.summary.isEmpty)
        for model in ["bad-json", "http-error"] {
            let fallback = try await RecordingNarrativeGenerator.generate(input, server: RecordingModelServer(url: base, model: model), apple: { _, _ in .init(title: "Apple fallback", summary: "Apple summary") })
            precondition(fallback.source.contains("; used Apple on-device model") && fallback.title == "Apple fallback")
        }
        let rules = try await RecordingNarrativeGenerator.generate(input, server: RecordingModelServer(url: base, model: "bad-json"), apple: { _, _ in throw RecordingNarrativeGenerator.Failure.unavailable })
        precondition(rules.title == "Choose an export preset" && rules.summary.isEmpty && rules.chapterTitles.isEmpty)
        let canceled = Task {
            try await RecordingNarrativeGenerator.generate(input, server: nil, apple: { _, _ in
                try await Task.sleep(for: .seconds(20))
                return .init(title: "Canceled", summary: "Canceled")
            })
        }
        canceled.cancel()
        do { _ = try await canceled.value; fatalError("Canceled work returned a suggestion") }
        catch { precondition(error is CancellationError) }
        print("PASS: real loopback HTTP client, chapter IDs, malformed/503 fallback, no-AI rules and cancellation")
    }
}
