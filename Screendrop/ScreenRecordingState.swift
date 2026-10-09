enum ScreenRecordingState: Equatable {
    case idle
    case starting
    case recording
    case paused
    case finishing

    var canDiscard: Bool { self == .recording || self == .paused }
}

