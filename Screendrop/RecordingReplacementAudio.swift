import AVFoundation
import Foundation

/// A soundtrack imported to stand in for the recording's own audio, with
/// its track resolved once so Studio can rebuild the player item
/// synchronously while the user drags a trim handle.
nonisolated struct RecordingReplacementAudio {
    enum LoadError: LocalizedError {
        case unreadable
        var errorDescription: String? {
            "The replacement audio file is missing or has no readable audio track. Choose another audio file or reset to recorded audio."
        }
    }
    // AVAssetTrack holds its asset weakly; keep the source alive for rebuilds.
    private let asset: AVURLAsset
    let url: URL
    /// The file's name as the user chose it, for the inspector.
    let displayName: String
    let track: AVAssetTrack
    let duration: TimeInterval

    /// Resolves a picked file, or nil when it carries no audio.
    static func load(url: URL, displayName: String) async -> RecordingReplacementAudio? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0 else {
            return nil
        }
        return RecordingReplacementAudio(
            asset: asset,
            url: url,
            displayName: displayName,
            track: track,
            duration: duration
        )
    }
}
