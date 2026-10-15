import Testing

struct RecordingRenderCaptionTests {
    private let timeline = RecordingClipTimeline(segments: [
        .init(sourceStart: 0, sourceEnd: 2), .init(sourceStart: 4, sourceEnd: 8, speed: 2),
    ])
    private let words: [RecordingTranscriptWord] = [
        .init(text: "wrong ", start: 1, end: 2),
        .init(text: "secret ", start: 2, end: 4),
        .init(text: "finish", start: 4, end: 5),
    ]

    @Test func partialCaptionKeepsOnlySurvivingCorrectedWordsAndKaraokeTimings() {
        let captions = RecordingTranscript(words: words, cues: [.init(start: 1, end: 5, text: "Fixed private finish")])
            .renderCaptions(in: timeline)
        #expect(captions.cues.map(\.text) == ["Fixed finish"])
        #expect(captions.cues.first?.start == 1 && captions.cues.first?.end == 5)
        #expect(captions.words == [words[0], words[2]])
    }

    @Test func ambiguousPartialCaptionsAreDroppedWithTheirKaraokeWords() {
        for timed in [[], [RecordingTranscriptWord(text: "word", start: 1, end: 6)]] {
            let captions = RecordingTranscript(words: timed, cues: [.init(start: 1, end: 5, text: "Cannot map safely")])
                .renderCaptions(in: timeline)
            #expect(captions.cues.isEmpty && captions.words.isEmpty)
        }
        let changed = RecordingTranscript(words: words, cues: [.init(start: 1, end: 5, text: "Different word count here")])
            .renderCaptions(in: timeline)
        #expect(changed.cues.isEmpty && changed.words.isEmpty)
    }

    @Test func partlyCutWordsAndEntirelyCutCaptionsAreRemoved() {
        var straddling = words
        straddling[0].end = 2.1
        let captions = RecordingTranscript(words: straddling, cues: [
            .init(start: 1, end: 5, text: "Fixed private finish"), .init(start: 2, end: 4, text: "private"),
        ]).renderCaptions(in: timeline)
        #expect(captions.cues.map(\.text) == ["finish"])
        #expect(captions.words == [words[2]])
    }

    @Test func uncutCaptionsPreserveCorrectionsFormattingAndCueOnlyText() {
        let cue = RecordingSubtitleCue(start: 4, end: 6, text: " Corrected\ncaption ")
        let captions = RecordingTranscript(words: [], cues: [cue]).renderCaptions(in: timeline)
        #expect(captions.cues == [cue])
        let acrossSpeedChange = RecordingClipTimeline(segments: [
            .init(sourceStart: 0, sourceEnd: 2), .init(sourceStart: 2, sourceEnd: 8, speed: 2),
        ])
        let uncut = RecordingTranscript(words: words, cues: [.init(start: 1, end: 5, text: "Fixed private finish")])
        #expect(uncut.renderCaptions(in: acrossSpeedChange).cues == uncut.cues)
    }
}
