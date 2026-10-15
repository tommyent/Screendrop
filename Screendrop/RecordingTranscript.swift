import Foundation

/// One transcribed word on the source (unedited) timeline, in seconds.
/// `text` keeps the transcript's original trailing punctuation/spacing so
/// concatenating words reconstructs the transcript exactly.
nonisolated struct RecordingTranscriptWord: Codable, Sendable, Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval

    /// Word as shown in the transcript editor, without the glued spacing.
    var displayText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var midpoint: TimeInterval {
        (start + end) / 2
    }
}

/// A full transcription: the word-level timing (drives transcript-based
/// video editing) plus the readable cues derived from it (drive the
/// subtitle bar).
nonisolated struct RecordingTranscript: Sendable {
    var words: [RecordingTranscriptWord]
    var cues: [RecordingSubtitleCue]

    /// Keeps source times for the compositor, but never displays wording from a cut.
    func renderCaptions(in timeline: RecordingClipTimeline) -> RecordingTranscript {
        func isKept(_ start: TimeInterval, _ end: TimeInterval) -> Bool {
            guard start.isFinite, end.isFinite, end > start else { return false }
            let kept = timeline.slices(overlapping: start, sourceEnd: end)
                .reduce(0) { $0 + $1.sourceEnd - $1.sourceStart }
            return abs(kept - (end - start)) < 0.000_001
        }

        var result = RecordingTranscript(words: [], cues: [])
        for var cue in cues where cue.start.isFinite && cue.end.isFinite && cue.end > cue.start {
            let timed = words.filter { $0.start >= cue.start && $0.start < cue.end }
                .sorted { $0.start < $1.start }
            if isKept(cue.start, cue.end) {
                result.cues.append(cue)
                result.words += timed.filter { isKept($0.start, $0.end) }
                continue
            }
            let corrected = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
            // A changed word count or invalid timing cannot safely locate corrected wording.
            guard !timed.isEmpty, timed.count == corrected.count,
                  timed.allSatisfy({ $0.end.isFinite && $0.end > $0.start && $0.end <= cue.end })
            else { continue }
            let surviving = zip(timed, corrected).filter { isKept($0.0.start, $0.0.end) }
            guard !surviving.isEmpty else { continue }
            cue.text = surviving.map { $0.1 }.joined(separator: " ")
            result.cues.append(cue)
            result.words += surviving.map { $0.0 }
        }
        return result
    }
}

/// One subtitle on the source (unedited) timeline, in seconds.
nonisolated struct RecordingSubtitleCue: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String

    init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case start
        case end
        case text
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Cues saved before editing shipped carry no identity; mint one so
        // the editor's list rows stay stable for this session.
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        text = try container.decode(String.self, forKey: .text)
    }
}
