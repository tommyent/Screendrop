//
//  VideoCompressionModels.swift
//  Screendrop
//

import Foundation

enum VideoCompressionQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    var id: String { rawValue }
}

enum VideoCompressionSpeed: String, CaseIterable, Identifiable, Codable, Sendable {
    case ultrafast = "Ultrafast"
    case fast = "Fast"
    case medium = "Medium"
    case slow = "Slow"

    var id: String { rawValue }
}

enum VideoCompressionCodec: String, CaseIterable, Identifiable, Codable, Sendable {
    case h264 = "H.264"
    case hevc = "HEVC"

    var id: String { rawValue }
}

enum VideoCompressionResolution: String, CaseIterable, Identifiable, Codable, Sendable {
    case original = "Original"
    case p1080 = "1080p"
    case p720 = "720p"
    case p480 = "480p"

    var id: String { rawValue }
}

/// Delivery container for exported recordings. The encoded video and audio
/// are identical either way - only the wrapper differs.
enum VideoExportContainer: String, CaseIterable, Identifiable, Codable, Sendable {
    /// What capture already writes, so a plain recording exports as a
    /// copy-on-write clone with no rewrite at all.
    case mov = "MOV"
    /// Plays outside Apple platforms - Slack, Discord, browsers, Windows.
    /// Costs a container rewrite when the source is a QuickTime master.
    case mp4 = "MP4"

    nonisolated static let `default` = VideoExportContainer.mov

    var id: String { rawValue }

    var fileExtension: String { rawValue.lowercased() }

    init?(fileExtension: String) {
        guard let match = Self.allCases.first(where: {
            $0.fileExtension == fileExtension.lowercased()
        }) else { return nil }
        self = match
    }
}

nonisolated enum VideoExportFrameRate: String, CaseIterable, Identifiable, Codable, Sendable {
    case fps30 = "30 fps"
    case fps60 = "60 fps"

    var id: String { rawValue }
    var framesPerSecond: Double { self == .fps30 ? 30 : 60 }
}

nonisolated struct VideoCompressionSettings: Codable, Equatable, Sendable {
    var quality: VideoCompressionQuality = .medium
    var speed: VideoCompressionSpeed = .fast
    var codec: VideoCompressionCodec = .h264
    var resolution: VideoCompressionResolution = .original
    var removeAudio = false
    /// Optional so projects saved before the format picker keep decoding.
    /// A synthesized `Codable` decoder ignores property defaults and throws
    /// on a missing key, and `loadEditDocument` swallows that with `try?` -
    /// a non-optional field here would silently discard the whole project.
    var container: VideoExportContainer?
    /// Studio delivery options. Missing keys preserve the historical render
    /// for existing projects, preferences, and cached-deliverable stamps.
    var frameRate: VideoExportFrameRate?
    var motionBlurEnabled: Bool?

    var effectiveContainer: VideoExportContainer { container ?? .default }
    var effectiveFrameRate: VideoExportFrameRate { frameRate ?? .fps60 }
    var effectiveMotionBlurEnabled: Bool { motionBlurEnabled ?? true }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.quality == rhs.quality && lhs.speed == rhs.speed && lhs.codec == rhs.codec
            && lhs.resolution == rhs.resolution && lhs.removeAudio == rhs.removeAudio
            && lhs.container == rhs.container
            && lhs.effectiveFrameRate == rhs.effectiveFrameRate
            && lhs.effectiveMotionBlurEnabled == rhs.effectiveMotionBlurEnabled
    }
}
