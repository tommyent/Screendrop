import Foundation

/// Chapter anchors stay on the original movie so cuts and speed changes are reversible.
nonisolated struct RecordingChapter: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var start: TimeInterval
}

nonisolated enum RecordingChapterPlanner {
    static func title(from text: String) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let sentence = clean.prefix { !".!?。！？".contains($0) }
        return String(sentence.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mapped(_ chapters: [RecordingChapter], through timeline: RecordingClipTimeline) -> [RecordingChapter] {
        var result: [RecordingChapter] = []
        for chapter in chapters.filter({ $0.start.isFinite }).sorted(by: { $0.start < $1.start }) {
            guard chapter.start.isFinite, chapter.start >= 0,
                  let time = timeline.editorTime(forSourceTime: chapter.start),
                  time < timeline.duration,
                  result.last.map({ time - $0.start > 0.001 }) ?? true else { continue }
            var mapped = chapter
            mapped.start = time
            mapped.title = String(chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            result.append(mapped)
        }
        return result
    }

    static func suggest(
        cues: [RecordingSubtitleCue], words: [RecordingTranscriptWord],
        timeline: RecordingClipTimeline, keeping existing: [RecordingChapter]
    ) -> [RecordingChapter] {
        let speech = words.isEmpty
            ? cues.map { ($0.start, $0.end) }
            : words.map { ($0.start, $0.end) }
        let surviving = speech.filter {
            $0.0.isFinite && $0.1.isFinite && $0.1 > $0.0
                && timeline.editorTime(forSourceTime: $0.0) != nil
        }.sorted { $0.0 < $1.0 }
        var result = existing
        var lastSuggestion: TimeInterval?
        for (index, interval) in surviving.enumerated() {
            let time = timeline.editorTime(forSourceTime: interval.0)!
            guard index == 0 || interval.0 - surviving[index - 1].1 >= 2 else { continue }
            guard lastSuggestion.map({ time - $0 >= 20 }) ?? true else { continue }
            guard !mapped(existing, through: timeline).contains(where: { abs($0.start - time) < 20 }) else { continue }
            let text = cues.filter { $0.end > interval.0 && $0.start < interval.0 + 20 }
                .map(\.text).joined(separator: " ")
            let name = title(from: text)
            result.append(RecordingChapter(title: name.isEmpty ? "Chapter \(result.count + 1)" : name, start: interval.0))
            lastSuggestion = time
        }
        return result.sorted { $0.start < $1.start }
    }
}
