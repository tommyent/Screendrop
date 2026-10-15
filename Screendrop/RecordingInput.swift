import Foundation

/// Sidecar of everything the user did during the recording, on the screen
/// movie's timeline. Coordinates are normalized (0...1) with a top-left
/// origin so they stay valid at any render resolution.
nonisolated struct PointerCaptureFile: Codable, Sendable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion = Self.currentFormatVersion
    var travel: [PointerTravelSample] = []
    var presses: [PointerPressEvent] = []
    var keystrokes: [RecordingKeystrokeEvent] = []
    var artwork: [PointerArtwork] = []
    /// Prevents deterministic cleanup from being applied repeatedly when the
    /// same sidecar passes through Studio, flattening, and export builders.
    var isSanitized = false
}

/// A completed keyboard chord captured during recording: a special key press
/// (Tab, Esc, arrows, …) or a modifier shortcut (⌘C). Plain typing is never
/// recorded. Labels are display-ready strings so Studio and export render
/// exactly what was captured without re-deriving key names.
nonisolated struct RecordingKeystrokeEvent: Codable, Sendable, Equatable {
    /// Seconds on the screen movie timeline.
    var time: TimeInterval
    /// Held modifier symbols in keyboard order, e.g. ["⌃", "⌘"].
    var modifiers: [String] = []
    /// The trigger key's label, e.g. "K", "⇥", "esc".
    var key: String
}

nonisolated struct PointerTravelSample: Codable, Sendable, Equatable {
    enum PointerTravelKind: String, Codable, Sendable {
        case move
        case drag
    }

    /// Seconds on the screen movie timeline.
    var time: TimeInterval
    var x: Double
    var y: Double
    var kind: PointerTravelKind = .move
    /// References an entry in `PointerCaptureFile.artwork`. A nil ID means
    /// the renderer should use an AppKit-provided system arrow.
    var artworkID: String? = nil
}

nonisolated struct PointerPressEvent: Codable, Sendable, Equatable {
    enum PressPhase: String, Codable, Sendable {
        case down
        case up
    }

    var time: TimeInterval
    var x: Double
    var y: Double
    var button: Int
    var phase: PressPhase
    /// Pointer appearance active when the button event was captured.
    var artworkID: String? = nil
}

/// A captured pointer image embedded in input.json. `Data` is encoded as a
/// base-64 JSON string by Foundation's Codable implementation.
nonisolated struct PointerArtwork: Codable, Sendable, Equatable {
    nonisolated struct Point: Codable, Sendable, Equatable {
        var x: Double
        var y: Double
    }

    nonisolated struct Size: Codable, Sendable, Equatable {
        var width: Double
        var height: Double
    }

    var artworkID: String
    var imageData: Data
    /// Anchor point in the captured artwork's reference-size coordinate space.
    var anchorPoint: Point
    var referenceSize: Size
}

extension PointerCaptureFile {
    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case travel
        case presses
        case keystrokes
        case artwork
        case isSanitized
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        travel = try container.decodeIfPresent([PointerTravelSample].self, forKey: .travel) ?? []
        presses = try container.decodeIfPresent([PointerPressEvent].self, forKey: .presses) ?? []
        keystrokes = try container.decodeIfPresent(
            [RecordingKeystrokeEvent].self,
            forKey: .keystrokes
        ) ?? []
        artwork = try container.decodeIfPresent(
            [PointerArtwork].self,
            forKey: .artwork
        ) ?? []
        isSanitized = try container.decodeIfPresent(Bool.self, forKey: .isSanitized) ?? false
    }
}

extension PointerTravelSample {
    private enum CodingKeys: String, CodingKey {
        case time
        case x
        case y
        case kind
        case artworkID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decode(TimeInterval.self, forKey: .time)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        kind = try container.decodeIfPresent(
            PointerTravelKind.self,
            forKey: .kind
        ) ?? .move
        artworkID = try container.decodeIfPresent(String.self, forKey: .artworkID)
    }
}
