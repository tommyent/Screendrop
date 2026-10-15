import Foundation
import Testing

struct RecordingBackgroundMusicTests {
    @Test func storageRoundTripAndDefaults() throws {
        let music = RecordingBackgroundMusic(fileName: "background-music.test.wav", displayName: "Test", credit: "Credit")
        let decoded = try JSONDecoder().decode(RecordingBackgroundMusic.self, from: JSONEncoder().encode(music))
        #expect(decoded == music)
        #expect(decoded.volume == 0.25 && decoded.loop && decoded.duck && decoded.duckAmount == .medium)
        try decoded.validate()
    }

    @Test func invalidStorageAndOffset() throws {
        for name in ["../screen.mov", "/tmp/song.wav", "", ".", ".."] {
            let music = RecordingBackgroundMusic(fileName: name, displayName: "Invalid")
            #expect(throws: (any Error).self) { try music.validate() }
        }
        #expect(RecordingBackgroundMusic.startOffset(.nan, duration: 8) == 0)
        #expect(RecordingBackgroundMusic.startOffset(-10, duration: 8) == 0)
        #expect(RecordingBackgroundMusic.startOffset(50, duration: 8) == 7.95)
        #expect(RecordingBackgroundMusic.DuckAmount.aLittle.gain > RecordingBackgroundMusic.DuckAmount.medium.gain)
        #expect(abs(RecordingBackgroundMusic.DuckAmount.aLot.gain - 0.1) < 0.0001)
    }

    @Test func loopFillsCutAndRepeatsFromOffset() {
        let parts = RecordingMusicEnvelope.placements(trackDuration: 4, startOffset: 1, duration: 8, loop: true)
        #expect(parts == [.init(sourceStart: 1, duration: 3, editorStart: 0),
                          .init(sourceStart: 1, duration: 3, editorStart: 3),
                          .init(sourceStart: 1, duration: 2, editorStart: 6)])
        #expect(RecordingMusicEnvelope.placements(trackDuration: 4, startOffset: 1, duration: 8, loop: false)
            == [.init(sourceStart: 1, duration: 3, editorStart: 0)])
        #expect(RecordingMusicEnvelope.placements(trackDuration: 20, startOffset: 2, duration: 3, loop: true)
            == [.init(sourceStart: 2, duration: 3, editorStart: 0)])
    }

    @Test func speechDetectionBridgesShortGapsAndKeepsSilence() {
        let levels: [Float] = Array(repeating: 0.001, count: 50) + Array(repeating: 0.1, count: 20)
            + Array(repeating: 0.001, count: 10) + Array(repeating: 0.1, count: 20)
            + Array(repeating: 0.001, count: 50)
        #expect(RecordingMusicEnvelope.speechRanges(levels: levels) == [1...2])
        #expect(RecordingMusicEnvelope.speechRanges(levels: Array(repeating: 0, count: 100)).isEmpty)
        #expect(RecordingMusicEnvelope.speechRanges(levels: Array(repeating: 0.05, count: 100)) == [0...2])
        // A short utterance in a long silent recording must still lower the music.
        #expect(!RecordingMusicEnvelope.speechRanges(levels: Array(repeating: 0, count: 1000) + [0.05, 0.05]).isEmpty)
        #expect(RecordingMusicEnvelope.speechRanges(levels: Array(repeating: 0.001, count: 1000) + [0.05, 0.05]) == [20...20.04])
        #expect(RecordingMusicEnvelope.bridge([0...1, 1.3...2]) == [0...1, 1.3...2])
    }

    @Test func speechMapsThroughCutsAndSpeed() {
        let timeline = RecordingClipTimeline(segments: [.init(sourceStart: 1, sourceEnd: 3),
            .init(sourceStart: 5, sourceEnd: 9, speed: 2)])
        #expect(RecordingMusicEnvelope.mappedSpeech([0...2, 3.2...4, 6...8], timeline: timeline)
            == [0...1, 2.5...3.5])
    }

    @Test func attackReleaseFadeAndDisabledDucking() throws {
        var settings = RecordingBackgroundMusic(fileName: "test.wav", displayName: "Test")
        let timeline = RecordingClipTimeline.full(sourceDuration: 5)
        let points = RecordingMusicEnvelope.points(settings: settings, speech: [1...2], timeline: timeline)
        func value(_ time: Double, in points: [RecordingMusicEnvelope.Point]) -> Double {
            for (a, b) in zip(points, points.dropFirst()) where time >= a.time && time <= b.time {
                return a.volume + (b.volume - a.volume) * (time - a.time) / (b.time - a.time)
            }
            return points.last?.volume ?? 0
        }
        #expect(abs(value(0.5, in: points) - 0.25) < 0.0001)
        #expect(abs(value(1.1, in: points) - 0.25 * settings.duckAmount.gain) < 0.0001)
        #expect(value(1.02, in: points) < 0.25 && value(1.02, in: points) > value(1.1, in: points))
        #expect(value(2.1, in: points) > value(1.9, in: points) && value(2.1, in: points) < 0.25)
        #expect(abs(value(2.4, in: points) - 0.25) < 0.0001)
        #expect(abs(value(4.5, in: points) - 0.125) < 0.0001)
        #expect(points.last == .init(time: 5, volume: 0))
        settings.duck = false
        let flat = RecordingMusicEnvelope.points(settings: settings, speech: [0...5], timeline: timeline)
        #expect(flat == [.init(time: 0, volume: 0.25), .init(time: 4, volume: 0.25), .init(time: 5, volume: 0)])
        #expect(RecordingMusicEnvelope.points(settings: settings, speech: [], timeline: .full(sourceDuration: 0.5)).last?.volume == 0)
    }
}
