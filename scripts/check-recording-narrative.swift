// Compile with the five production sources listed in ScreendropTests/README.md.
import Foundation

@main struct RecordingNarrativeServerCheck {
    static func main() async throws {
        let base = CommandLine.arguments[1]
        let id = UUID()
        let input = RecordingNarrativeInput(text: "Choose an export preset. Save the recording.", chapters: [.init(id: id, text: "Choose the export preset.")])
        if CommandLine.arguments.count > 2 {
            let realInput = RecordingNarrativeInput(text: input.text, chapters: [
                input.chapters[0], .init(id: UUID(), text: "Okay so now"), .init(id: UUID(), text: "Save the recording.")
            ])
            let result = try await RecordingNarrativeGenerator.generate(realInput,
                server: RecordingModelServer(url: base, model: CommandLine.arguments[2]),
                onServerReply: { fields, data in
                    FileHandle.standardOutput.write(Data("RAW \(fields): \(String(decoding: data, as: UTF8.self))\n".utf8))
                })
            precondition(result.source == "Local model server", result.source)
            precondition(!result.title.isEmpty && result.title.count <= 80)
            precondition(!result.summary.isEmpty && result.summary.count <= 400)
            precondition(result.chapterTitles.values.allSatisfy { !$0.isEmpty && $0.count <= 80 })
            print("PASS: real local model title and summary retained; chapter names are best effort")
            print("Source: \(result.source)\nTitle: \(result.title)\nSummary: \(result.summary)")
            for chapter in realInput.chapters {
                let title = result.chapterTitles[chapter.id] ?? RecordingChapterPlanner.title(from: chapter.text)
                print("Chapter (\(result.chapterTitles[chapter.id] == nil ? "rule-based" : "model")): \(title)")
            }
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
