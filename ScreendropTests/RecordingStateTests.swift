import Testing

struct RecordingStateTests {
    @Test(arguments: [ScreenRecordingState.idle, .starting, .finishing])
    func discardCannotReplaceAStopAlreadyFinishing(_ state: ScreenRecordingState) {
        #expect(!state.canDiscard)
    }

    @Test(arguments: [ScreenRecordingState.recording, .paused])
    func liveAndPausedRecordingsCanRequestConfirmedDiscard(_ state: ScreenRecordingState) {
        #expect(state.canDiscard)
    }
}
