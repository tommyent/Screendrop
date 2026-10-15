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
