import Foundation
import Testing

struct RecordingChapterTests {
    @Test func suggestsLongPausesAndPreservesExistingNames() {
        let cues = [RecordingSubtitleCue(start: 1, end: 3, text: "Corrected opening."),
                    RecordingSubtitleCue(start: 26, end: 28, text: "Export settings. More detail"),
                    RecordingSubtitleCue(start: 31, end: 33, text: "A nearby pause")]
        let manual = RecordingChapter(title: "My introduction", start: 0)
        let chapters = RecordingChapterPlanner.suggest(cues: cues, words: [], timeline: .full(sourceDuration: 60), keeping: [manual])
        #expect(chapters.map(\.title) == ["My introduction", "Export settings"])
        #expect(chapters.map(\.start) == [0, 26])
        #expect(RecordingChapterPlanner.suggest(cues: [], words: [], timeline: .full(sourceDuration: 60), keeping: [manual]) == [manual])
    }

    @Test func mappingDropsCutAnchorsHonorsSpeedAndRestoresOriginals() {
        let chapters = [RecordingChapter(title: "First", start: 2), RecordingChapter(title: "Cut", start: 12), RecordingChapter(title: "Later", start: 25)]
        let edited = RecordingClipTimeline(segments: [.init(sourceStart: 0, sourceEnd: 10, speed: 2), .init(sourceStart: 20, sourceEnd: 30)])
        let mapped = RecordingChapterPlanner.mapped(chapters, through: edited)
        #expect(mapped.map(\.start) == [1, 10])
        #expect(mapped.map(\.title) == ["First", "Later"])
        #expect(RecordingChapterPlanner.mapped(chapters, through: .full(sourceDuration: 30)) == chapters)
    }

    @Test func wordGapsRemainAnchoredAfterSilenceCuts() {
        let words = [RecordingTranscriptWord(text: "First", start: 1, end: 3), RecordingTranscriptWord(text: "Next", start: 30, end: 32)]
        let timeline = RecordingClipTimeline(segments: [.init(sourceStart: 0, sourceEnd: 24), .init(sourceStart: 29.5, sourceEnd: 40)])
        let chapters = RecordingChapterPlanner.suggest(cues: [.init(start: 30, end: 32, text: "Corrected next")], words: words, timeline: timeline, keeping: [])
        #expect(chapters.map(\.start) == [1, 30])
        #expect(chapters.last?.title == "Corrected next")
    }

    @Test func uploadPayloadUsesEditedTimesAndFreezesAValue() throws {
        var chapters = [RecordingChapter(title: "First", start: 2), RecordingChapter(title: "Cut", start: 12), RecordingChapter(title: "Later", start: 25)]
        let timeline = RecordingClipTimeline(segments: [.init(sourceStart: 0, sourceEnd: 10, speed: 2), .init(sourceStart: 20, sourceEnd: 30)])
        let data = try RecordingChapterPlanner.shareData(chapters, through: timeline)
        chapters[0].title = "Changed after upload started"
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(payload.count == 2)
        #expect(payload[0]["title"] as? String == "First")
        #expect(payload[0]["start"] as? Double == 0)
        #expect(payload[1]["start"] as? Double == 10)
        #expect(payload[0]["id"] == nil)
        #expect(String(decoding: try RecordingChapterPlanner.shareData([], through: timeline), as: UTF8.self) == "[]")
    }

    @Test func partiallyCutProseCannotReintroduceRemovedNarration() {
        let words = [RecordingTranscriptWord(text: "Private ", start: 0, end: 1), RecordingTranscriptWord(text: "public", start: 2, end: 3)]
        let timeline = RecordingClipTimeline(segments: [.init(sourceStart: 1.5, sourceEnd: 5)])
        let original = RecordingSubtitleCue(start: 0, end: 3, text: "Private public")
        #expect(RecordingChapterPlanner.survivingCues([original], words: words, through: timeline).isEmpty)
        let corrected = RecordingSubtitleCue(start: 0, end: 3, text: "public")
        #expect(RecordingChapterPlanner.survivingCues([corrected], words: words, through: timeline).map(\.text) == ["public"])
        #expect(RecordingChapterPlanner.survivingCues([original], words: [], through: timeline).isEmpty)
    }

    @Test func cutBoundaryBelongsToTheFollowingSurvivingFootage() {
        let timeline = RecordingClipTimeline(segments: [.init(sourceStart: 0, sourceEnd: 10), .init(sourceStart: 20, sourceEnd: 30)])
        let chapters = [RecordingChapter(title: "Removed at splice", start: 10), RecordingChapter(title: "Surviving", start: 20)]
        #expect(RecordingChapterPlanner.mapped(chapters, through: timeline).map(\.title) == ["Surviving"])
        let words = [RecordingTranscriptWord(text: "Cut", start: 10, end: 11), RecordingTranscriptWord(text: "Kept", start: 20, end: 21)]
        let proposed = RecordingChapterPlanner.suggest(cues: [], words: words, timeline: timeline, keeping: [])
        #expect(proposed.map(\.start) == [20])
    }

    @Test func chaptersNearTheRenderedEndAreDropped() throws {
        let chapters = [RecordingChapter(title: "Kept", start: 9.49), RecordingChapter(title: "Half second", start: 9.5), RecordingChapter(title: "At playhead end", start: 9.999)]
        let timeline = RecordingClipTimeline.full(sourceDuration: 10)
        #expect(RecordingChapterPlanner.mapped(chapters, through: timeline).map(\.title) == ["Kept"])
        let payload = try #require(JSONSerialization.jsonObject(with: RecordingChapterPlanner.shareData(chapters, through: timeline)) as? [[String: Any]])
        #expect(payload.count == 1)
        #expect(payload[0]["title"] as? String == "Kept")
    }

    @Test func oldMetadataAndNewChaptersRoundTrip() throws {
        var metadata = try JSONDecoder().decode(RecordingProjectMetadata.self, from: Data(#"{"version":1,"displayName":"Existing"}"#.utf8))
        #expect(metadata.chapters == nil)
        metadata.chapters = [RecordingChapter(title: "Start", start: 0)]
        #expect(try JSONDecoder().decode(RecordingProjectMetadata.self, from: JSONEncoder().encode(metadata)) == metadata)
    }

    @Test func openingSentenceAndInvalidAnchorsAreBounded() {
        #expect(RecordingChapterPlanner.title(from: "  A corrected\n opening. Another sentence") == "A corrected opening")
        #expect(RecordingChapterPlanner.title(from: String(repeating: "x", count: 100)).count == 80)
        let chapters = [RecordingChapter(title: "End", start: 10), RecordingChapter(title: "Invalid", start: .nan), RecordingChapter(title: "First", start: 0), RecordingChapter(title: "Duplicate", start: 0)]
        #expect(RecordingChapterPlanner.mapped(chapters, through: .full(sourceDuration: 10)).count == 1)
    }
}
