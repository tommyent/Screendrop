import Foundation

/// Chapter anchors stay on the original movie so cuts and speed changes are reversible.
nonisolated struct RecordingChapter: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var start: TimeInterval
    var autoTitle: Bool? = nil
}

nonisolated enum RecordingChapterPlanner {
    static func title(from text: String) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let sentence = clean.prefix { !".!?。！？".contains($0) }
        return String(sentence.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func openingSentenceTitle(cues: [RecordingSubtitleCue], words: [RecordingTranscriptWord], through timeline: RecordingClipTimeline) -> String {
        title(from: survivingCues(cues, words: words, through: timeline).map(\.text).joined(separator: " "))
    }

    static func mapped(_ chapters: [RecordingChapter], through timeline: RecordingClipTimeline, cues: [RecordingSubtitleCue] = [], words: [RecordingTranscriptWord] = []) -> [RecordingChapter] {
        var result: [RecordingChapter] = []
        for chapter in chapters.filter({ $0.start.isFinite }).sorted(by: { $0.start < $1.start }) {
            guard chapter.start >= 0,
                  timeline.segments.contains(where: { chapter.start >= $0.sourceStart && chapter.start < $0.sourceEnd }),
                  let time = timeline.editorTime(forSourceTime: chapter.start),
                  time < timeline.duration - 0.5,
                  result.last.map({ time - $0.start > 0.001 }) ?? true else { continue }
            var mapped = chapter
            mapped.start = time
            mapped.title = String(chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            result.append(mapped)
        }
        if result.contains(where: { $0.autoTitle == true }) {
            let readable = survivingCues(cues, words: words, through: timeline)
            for index in result.indices where result[index].autoTitle == true {
                let end = index + 1 < result.count ? result[index + 1].start : timeline.duration
                let text = chapterText(readable, through: timeline, start: result[index].start, end: end)
                let title = title(from: text)
                result[index].title = title.isEmpty ? "Chapter \(index + 1)" : title
            }
        }
        return result
    }

    static func chapterText(_ cues: [RecordingSubtitleCue], through timeline: RecordingClipTimeline, start: TimeInterval, end: TimeInterval) -> String {
        let sourceStart = timeline.sourceTime(at: start)
        return cues.filter {
            guard let time = timeline.editorTime(forSourceTime: $0.start) else { return false }
            return $0.end > sourceStart && time < end
        }.map(\.text).joined(separator: " ")
    }

    static func shareData(_ chapters: [RecordingChapter], through timeline: RecordingClipTimeline, cues: [RecordingSubtitleCue] = [], words: [RecordingTranscriptWord] = []) throws -> Data {
        struct WireChapter: Encodable {
            var title: String
            var start: TimeInterval
        }
        var mapped = mapped(chapters, through: timeline, cues: cues, words: words)
        if !mapped.isEmpty { mapped[0].start = 0 }
        return try JSONEncoder().encode(mapped.map {
            WireChapter(title: $0.title.isEmpty ? "Chapter" : $0.title, start: $0.start)
        })
    }

    static func survivingCues(_ cues: [RecordingSubtitleCue], words: [RecordingTranscriptWord], through timeline: RecordingClipTimeline) -> [RecordingSubtitleCue] {
        cues.compactMap { cue in
            let slices = timeline.slices(overlapping: cue.start, sourceEnd: cue.end)
            guard let first = slices.first, !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let cueWords = words.filter { $0.midpoint >= cue.start && $0.midpoint < cue.end }
            let survivingWords = cueWords.filter { word in
                timeline.slices(overlapping: word.start, sourceEnd: word.end)
                    .reduce(0) { $0 + $1.sourceEnd - $1.sourceStart } >= word.end - word.start - 0.001
            }
            let covered = slices.reduce(0) { $0 + $1.sourceEnd - $1.sourceStart }
            if covered < cue.end - cue.start - 0.001 {
                // shortcut: partially cut corrected prose has no new word timings; omit it unless it matches surviving words.
                guard !cueWords.isEmpty, !survivingWords.isEmpty,
                      survivingWords.count == cueWords.count || cue.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        == survivingWords.map(\.text).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ") else { return nil }
            }
            var surviving = cue
            surviving.start = max(cue.start, first.sourceStart)
            return surviving
        }.sorted { $0.start < $1.start }
    }

    static func suggest(
        cues: [RecordingSubtitleCue], words: [RecordingTranscriptWord],
        timeline: RecordingClipTimeline, keeping existing: [RecordingChapter]
    ) -> [RecordingChapter] {
        let speech = words.isEmpty
            ? cues.map { ($0.start, $0.end) }
            : words.map { ($0.start, $0.end) }
        let surviving = speech.compactMap { interval -> (TimeInterval, TimeInterval)? in
            guard interval.0.isFinite, interval.1.isFinite, interval.1 > interval.0,
                  let first = timeline.slices(overlapping: interval.0, sourceEnd: interval.1).first else { return nil }
            return (first.sourceStart, interval.1)
        }.sorted { $0.0 < $1.0 }
        let readableCues = survivingCues(cues, words: words, through: timeline)
        var result = existing
        var lastSuggestion: TimeInterval?
        for (index, interval) in surviving.enumerated() {
            let time = timeline.editorTime(forSourceTime: interval.0)!
            guard index == 0 || interval.0 - surviving[index - 1].1 >= 2 else { continue }
            guard lastSuggestion.map({ time - $0 >= 20 }) ?? true else { continue }
            guard !mapped(existing, through: timeline).contains(where: { abs($0.start - time) < 20 }) else { continue }
            let text = readableCues.filter { $0.end > interval.0 && $0.start < interval.0 + 20 }
                .map(\.text).joined(separator: " ")
            let name = title(from: text)
            result.append(RecordingChapter(title: name.isEmpty ? "Chapter \(result.count + 1)" : name, start: interval.0, autoTitle: true))
            lastSuggestion = time
        }
        return result.sorted { $0.start < $1.start }
    }
}
