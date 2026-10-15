//
//  RecordingCompositionBuilder.swift
//  Screendrop
//
//  Shared gap-closing composition used by Studio playback and export.
//

import AVFoundation

nonisolated enum RecordingCompositionBuilder {
    static func makeAsset(
        from sourceAsset: AVAsset,
        timeline: RecordingClipTimeline,
        sourceDuration: TimeInterval,
        microphoneTrackID: CMPersistentTrackID? = nil,
        isolatedMicrophone: AVAssetTrack? = nil
    ) throws -> AVAsset {
        let normalized = timeline.normalized(to: sourceDuration)
        if isolatedMicrophone == nil, normalized.isUnedited(sourceDuration: sourceDuration) {
            return sourceAsset
        }

        let composition = AVMutableComposition()
        let trackPairs: [(AVAssetTrack, AVMutableCompositionTrack)]
        if let isolatedMicrophone {
            guard let microphoneTrackID else { throw CocoaError(.fileReadCorruptFile) }
            let tracks = sourceAsset.tracks
            guard tracks.contains(where: { $0.trackID == microphoneTrackID && $0.mediaType == .audio }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            trackPairs = try tracks.map { original in
                guard let destination = composition.addMutableTrack(
                    withMediaType: original.mediaType, preferredTrackID: original.trackID
                ) else { throw CocoaError(.fileReadCorruptFile) }
                destination.preferredTransform = original.preferredTransform
                return (original.trackID == microphoneTrackID ? isolatedMicrophone : original, destination)
            }
        } else {
            trackPairs = []
        }
        var insertionTime = CMTime.zero
        for clip in normalized.segments {
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
            )
            if trackPairs.isEmpty {
                try composition.insertTimeRange(range, of: sourceAsset, at: insertionTime)
            } else {
                for (source, destination) in trackPairs {
                    // Audio can begin late or end before the screen; retain those silent gaps.
                    let available = CMTimeRangeGetIntersection(range, otherRange: source.timeRange)
                    if available.duration > .zero {
                        try destination.insertTimeRange(available, of: source,
                            at: insertionTime + available.start - range.start)
                    }
                }
            }

            // Retiming here scales every track inserted above together
            // (video and audio alike), so a sped-up clip never drifts out
            // of sync the way independently retiming each track would.
            if abs(clip.speed - 1) > 0.000_001 {
                let insertedRange = CMTimeRange(start: insertionTime, duration: range.duration)
                let scaledDuration = CMTime(seconds: clip.editorDuration, preferredTimescale: 600)
                composition.scaleTimeRange(insertedRange, toDuration: scaledDuration)
                insertionTime = insertionTime + scaledDuration
            } else {
                insertionTime = insertionTime + range.duration
            }
        }
        return composition
    }

    /// Playback asset whose soundtrack comes from an imported file instead
    /// of the recording's own audio. The video track arrives already
    /// resolved so Studio can rebuild the player item synchronously, the
    /// way it does on every trim.
    static func makeAsset(
        videoTrack: AVAssetTrack,
        timeline: RecordingClipTimeline,
        sourceDuration: TimeInterval,
        replacementAudio: RecordingReplacementAudio
    ) throws -> AVAsset {
        let normalized = timeline.normalized(to: sourceDuration)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var insertionTime = CMTime.zero
        for clip in normalized.segments {
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
            )
            try video.insertTimeRange(range, of: videoTrack, at: insertionTime)

            if abs(clip.speed - 1) > 0.000_001 {
                let insertedRange = CMTimeRange(start: insertionTime, duration: range.duration)
                let scaledDuration = CMTime(seconds: clip.editorDuration, preferredTimescale: 600)
                video.scaleTimeRange(insertedRange, toDuration: scaledDuration)
                insertionTime = insertionTime + scaledDuration
            } else {
                insertionTime = insertionTime + range.duration
            }
        }

        // The import is already the finished cut's soundtrack, so it lies
        // flat from zero rather than being re-cut through the clip list -
        // and is clipped to whatever the timeline still holds.
        let audioLength = min(replacementAudio.duration, insertionTime.seconds)
        if audioLength > 0,
           let audio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try audio.insertTimeRange(
                CMTimeRange(
                    start: .zero,
                    duration: CMTime(seconds: audioLength, preferredTimescale: 600)
                ),
                of: replacementAudio.track,
                at: .zero
            )
        }
        return composition
    }
}
