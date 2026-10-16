import Foundation
import Testing

struct RecordingChapterTests {
    @Test func currentChapterUsesEditedBoundariesAndHidesBeforeTheFirst() {
        let chapters = [RecordingChapter(title: "Opening", start: 2), RecordingChapter(title: "Closing", start: 6)]
        for time in [-1.0, 0, 1.999, 10.001, .nan, .infinity] {
            #expect(RecordingChapterPlanner.current(chapters, at: time, duration: 10) == nil)
        }
        for time in [2.0, 3, 5.999] {
            #expect(RecordingChapterPlanner.current(chapters, at: time, duration: 10)?.id == chapters[0].id)
        }
        for time in [6.0, 9.999, 10] {
            #expect(RecordingChapterPlanner.current(chapters, at: time, duration: 10)?.id == chapters[1].id)
        }
        #expect(RecordingChapterPlanner.current([], at: 2, duration: 10) == nil)
    }

    @Test func chapterDragClampsBetweenNeighboursAndStaysVisibleAtTheEnd() throws {
        let chapters = [RecordingChapter(title: "First", start: 1), RecordingChapter(title: "Middle", start: 3),
                        RecordingChapter(title: "Last", start: 7)]
        let clamp = { (index: Int, time: Double) in
            RecordingChapterPlanner.clampedStart(id: chapters[index].id, proposed: time, chapters: chapters, duration: 10)
        }
        #expect(clamp(0, -100) == 0)
        #expect(clamp(0, 100) == 2.984)
        #expect(clamp(1, -100) == 1.016)
        #expect(clamp(1, 100) == 6.984)
        #expect(clamp(1, 5) == 5)
        let end = try #require(clamp(2, 100))
        var moved = chapters
        moved[2].start = end
        #expect(end < 9.5 && end > chapters[1].start)
        #expect(RecordingChapterPlanner.mapped(moved, through: .full(sourceDuration: 10)).map(\.id) == chapters.map(\.id))
        #expect(clamp(1, .nan) == nil && clamp(1, .infinity) == nil)
        #expect(RecordingChapterPlanner.clampedStart(id: UUID(), proposed: 1, chapters: chapters, duration: 10) == nil)
        #expect(RecordingChapterPlanner.clampedStart(id: chapters[0].id, proposed: 0, chapters: chapters, duration: 0.4) == nil)
    }

    @Test func neighbourClampedDragKeepsAllChaptersAfterSpeedChanges() throws {
        let timeline = RecordingClipTimeline.full(sourceDuration: 40)
        let chapters = [RecordingChapter(title: "First", start: 5), RecordingChapter(title: "Middle", start: 15),
                        RecordingChapter(title: "Last", start: 25)]
        for proposed in [0.0, 40] {
            var moved = chapters
            let time = try #require(RecordingChapterPlanner.clampedStart(id: chapters[1].id, proposed: proposed,
                chapters: RecordingChapterPlanner.mapped(chapters, through: timeline), duration: timeline.duration))
            moved[1].start = timeline.sourceTime(at: time)
            for speed in [1.0, 2, 3, 4, 6, 8] {
                let faster = RecordingClipTimeline(segments: [.init(sourceStart: 0, sourceEnd: 40, speed: speed)])
                #expect(RecordingChapterPlanner.mapped(moved, through: faster).map(\.id) == chapters.map(\.id))
                let payload = try #require(JSONSerialization.jsonObject(
                    with: RecordingChapterPlanner.shareData(moved, through: faster)) as? [[String: Any]])
                #expect(payload.compactMap { $0["title"] as? String } == chapters.map(\.title))
            }
        }
    }

    @Test func movedChapterMapsBackToItsSurvivingSourceAnchor() throws {
        let timeline = RecordingClipTimeline(segments: [.init(sourceStart: 0, sourceEnd: 2, speed: 2),
                                                        .init(sourceStart: 4, sourceEnd: 8)])
        let chapters = [RecordingChapter(title: "First", start: 0.5), RecordingChapter(title: "Middle", start: 5),
                        RecordingChapter(title: "Last", start: 7)]
        let visible = RecordingChapterPlanner.mapped(chapters, through: timeline)
        let time = try #require(RecordingChapterPlanner.clampedStart(id: chapters[1].id, proposed: 1,
                                                                     chapters: visible, duration: timeline.duration))
        #expect(time == 1 && timeline.sourceTime(at: time) == 4)
        var moved = chapters
        moved[1].start = timeline.sourceTime(at: time)
        let mapped = RecordingChapterPlanner.mapped(moved, through: timeline)
        #expect(mapped.map(\.start) == [0.25, 1, 4])
        #expect(RecordingChapterPlanner.current(mapped, at: 1, duration: timeline.duration)?.id == chapters[1].id)
    }

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

    @Test func automaticNamesFollowCutsInStudioAndSharesUnlessRenamed() throws {
        let cues = [RecordingSubtitleCue(start: 1, end: 2, text: "Public opening"), RecordingSubtitleCue(start: 3, end: 4, text: "private words.")]
        let original = RecordingClipTimeline.full(sourceDuration: 10)
        let cut = RecordingClipTimeline(segments: [.init(sourceStart: 0, sourceEnd: 3), .init(sourceStart: 4, sourceEnd: 10)])
        let rule = RecordingChapter(title: "Public opening private words", start: 0, autoTitle: true)
        #expect(RecordingChapterPlanner.mapped([rule], through: cut, cues: cues).first?.title == "Public opening")
        let payload = try #require(JSONSerialization.jsonObject(with: RecordingChapterPlanner.shareData([rule], through: cut, cues: cues)) as? [[String: Any]])
        #expect(payload[0]["title"] as? String == "Public opening")
        #expect(Set(payload[0].keys) == ["title", "start"])
        #expect(RecordingChapterPlanner.mapped([rule], through: original, cues: cues).first?.title == "Public opening private words")
        var manual = rule
        manual.title = "My chosen name"
        manual.autoTitle = false
        #expect(RecordingChapterPlanner.mapped([manual], through: cut, cues: cues).first?.title == "My chosen name")
        let legacy = try JSONDecoder().decode(RecordingChapter.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","title":"Legacy name","start":0}"#.utf8))
        #expect(legacy.autoTitle == nil)
        #expect(RecordingChapterPlanner.mapped([legacy], through: cut, cues: cues).first?.title == "Legacy name")
    }

    @Test func oldMetadataAndNewChaptersRoundTrip() throws {
        var metadata = try JSONDecoder().decode(RecordingProjectMetadata.self, from: Data(#"{"version":1,"displayName":"Existing"}"#.utf8))
        #expect(metadata.chapters == nil)
        metadata.chapters = [RecordingChapter(title: "Start", start: 0)]
        #expect(try JSONDecoder().decode(RecordingProjectMetadata.self, from: JSONEncoder().encode(metadata)) == metadata)
    }

    @Test func automaticFallbacksAreNumberedAndLegacyChaptersStayManual() throws {
        let legacy = try JSONDecoder().decode(RecordingChapter.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","title":"Chapter 7","start":0}"#.utf8))
        let automatic = RecordingChapter(title: "Old narration", start: 5, autoTitle: true)
        let timeline = RecordingClipTimeline.full(sourceDuration: 10)
        let chapters = [legacy, automatic]
        #expect(RecordingChapterPlanner.mapped(chapters, through: timeline).map(\.title) == ["Chapter 7", "Chapter 2"])
        let cues = [RecordingSubtitleCue(start: 0, end: 2, text: "Legacy narration."),
                    RecordingSubtitleCue(start: 5, end: 7, text: "Corrected narration! More detail.")]
        #expect(RecordingChapterPlanner.mapped(chapters, through: timeline, cues: cues).map(\.title) == ["Chapter 7", "Corrected narration"])
        let payload = try #require(JSONSerialization.jsonObject(with: RecordingChapterPlanner.shareData(chapters, through: timeline)) as? [[String: Any]])
        #expect(payload.map { $0["title"] as? String } == ["Chapter 7", "Chapter 2"])
    }

    @Test func retiredMetadataFieldsDecodeAndAreDroppedOnSave() throws {
        let data = Data(#"{"version":1,"displayName":"Existing","narrationSummary":"Old summary","chapters":[{"id":"00000000-0000-0000-0000-000000000001","title":"Previously generated name","start":0,"autoTitle":true,"autoTitleSource":"old fingerprint"}]}"#.utf8)
        let metadata = try JSONDecoder().decode(RecordingProjectMetadata.self, from: data)
        let chapter = try #require(metadata.chapters?.first)
        #expect(metadata.displayName == "Existing" && chapter.autoTitle == true)
        let cues = [RecordingSubtitleCue(start: 1, end: 2, text: "Opening sentence.")]
        #expect(RecordingChapterPlanner.mapped([chapter], through: .full(sourceDuration: 10), cues: cues).first?.title == "Opening sentence")
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        #expect(Set(encoded.keys) == ["version", "displayName", "chapters"])
        let chapters = try #require(encoded["chapters"] as? [[String: Any]])
        #expect(Set(chapters[0].keys) == ["id", "title", "start", "autoTitle"])
    }

    @Test func openingSentenceUsesOnlySurvivingCorrectedText() {
        let cues = [RecordingSubtitleCue(start: 0, end: 2, text: "Removed opening."),
                    RecordingSubtitleCue(start: 4, end: 6, text: "  Corrected\n opening! More detail.")]
        let timeline = RecordingClipTimeline(segments: [.init(sourceStart: 3, sourceEnd: 10, speed: 2)])
        #expect(RecordingChapterPlanner.openingSentenceTitle(cues: cues, words: [], through: timeline) == "Corrected opening")
        let partial = RecordingSubtitleCue(start: 0, end: 5, text: "Removed public")
        let words = [RecordingTranscriptWord(text: "Removed ", start: 0, end: 1), RecordingTranscriptWord(text: "public", start: 4, end: 5)]
        #expect(RecordingChapterPlanner.openingSentenceTitle(cues: [partial], words: words, through: timeline).isEmpty)
        var corrected = partial
        corrected.text = "public"
        #expect(RecordingChapterPlanner.openingSentenceTitle(cues: [corrected], words: words, through: timeline) == "public")
        #expect(RecordingChapterPlanner.openingSentenceTitle(cues: [], words: [], through: timeline).isEmpty)
    }

    @Test func openingSentenceAndInvalidAnchorsAreBounded() {
        #expect(RecordingChapterPlanner.title(from: "  A corrected\n opening. Another sentence") == "A corrected opening")
        #expect(RecordingChapterPlanner.title(from: String(repeating: "x", count: 100)).count == 80)
        let chapters = [RecordingChapter(title: "End", start: 10), RecordingChapter(title: "Invalid", start: .nan), RecordingChapter(title: "First", start: 0), RecordingChapter(title: "Duplicate", start: 0)]
        #expect(RecordingChapterPlanner.mapped(chapters, through: .full(sourceDuration: 10)).count == 1)
    }
}
