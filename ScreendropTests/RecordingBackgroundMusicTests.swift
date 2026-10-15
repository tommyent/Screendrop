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
}
