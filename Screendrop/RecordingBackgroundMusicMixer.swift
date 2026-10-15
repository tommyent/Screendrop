import AVFoundation
import Foundation

nonisolated enum RecordingBackgroundMusicMixer {
    struct Configuration: Sendable {
        var url: URL
        var settings: RecordingBackgroundMusic
    }

    /// The recording/replacement is already cut; music follows editor time at its original speed.
    static func adding(to asset: AVAsset, music: RecordingReplacementAudio, settings: RecordingBackgroundMusic,
                       timeline: RecordingClipTimeline) throws -> (asset: AVAsset, trackID: CMPersistentTrackID) {
        try settings.validate()
        let composition: AVMutableComposition
        if let existing = asset as? AVComposition, let copy = existing.mutableCopy() as? AVMutableComposition {
            composition = copy
        } else {
            composition = AVMutableComposition()
            let length = min(asset.duration.seconds, timeline.duration)
            if length > 0 {
                try composition.insertTimeRange(CMTimeRange(start: .zero, duration: time(length)), of: asset, at: .zero)
            }
        }
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let range = music.track.timeRange
        let start = max(settings.startOffset, range.start.seconds)
        let end = min(music.duration, range.end.seconds)
        guard end > start else { throw CocoaError(.fileReadCorruptFile) }
        for part in RecordingMusicEnvelope.placements(trackDuration: end, startOffset: start, duration: timeline.duration, loop: settings.loop) {
            try track.insertTimeRange(CMTimeRange(start: time(part.sourceStart), duration: time(part.duration)),
                                      of: music.track, at: time(part.editorStart))
        }
        return (composition, track.trackID)
    }

    static func mix(asset: AVAsset, volume: Double, musicTrackID: CMPersistentTrackID?, settings: RecordingBackgroundMusic?,
                    speech: [ClosedRange<Double>], timeline: RecordingClipTimeline) -> AVAudioMix? {
        let tracks = asset.tracks(withMediaType: .audio)
        let recorded = tracks.filter { $0.trackID != musicTrackID }
        let base = RecordingAudioGain.makeMix(tracks: recorded, volume: volume)
        guard let settings, let track = tracks.first(where: { $0.trackID == musicTrackID }) else { return base }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let points = RecordingMusicEnvelope.points(settings: settings, speech: speech, timeline: timeline)
        if let first = points.first { parameters.setVolume(Float(first.volume), at: .zero) }
        for (start, end) in zip(points, points.dropFirst()) where end.time > start.time {
            parameters.setVolumeRamp(fromStartVolume: Float(start.volume), toEndVolume: Float(end.volume),
                timeRange: CMTimeRange(start: time(start.time), duration: time(end.time - start.time)))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = (base?.inputParameters ?? []) + [parameters]
        return mix
    }

    static func prepare(asset: AVAsset, music: Configuration?, sourceURL: URL, microphoneTrackID: CMPersistentTrackID?,
                        timeline: RecordingClipTimeline, volume: Double) async throws -> (asset: AVAsset, mix: AVAudioMix?) {
        guard let music else {
            return (asset, RecordingAudioGain.makeMix(tracks: try await asset.loadTracks(withMediaType: .audio), volume: volume))
        }
        guard let loaded = await RecordingReplacementAudio.load(url: music.url, displayName: music.settings.displayName) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The background music file is missing or unreadable. Add it again or remove it."])
        }
        let speech: [ClosedRange<Double>]
        if music.settings.duck, let microphoneTrackID {
            speech = try await RecordingMusicAnalysisCache.shared.availableAnalysis(url: sourceURL, trackID: microphoneTrackID)?.speech ?? []
        } else { speech = [] }
        try Task.checkCancellation()
        let combined = try adding(to: asset, music: loaded, settings: music.settings, timeline: timeline)
        return (combined.asset, mix(asset: combined.asset, volume: volume, musicTrackID: combined.trackID,
                                    settings: music.settings, speech: speech, timeline: timeline))
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }
}
