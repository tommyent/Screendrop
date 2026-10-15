import Foundation

nonisolated struct RecordingBackgroundMusic: Codable, Equatable, Sendable {
    static let baseName = "background-music"

    enum DuckAmount: Double, Codable, CaseIterable, Identifiable, Sendable {
        case aLittle = -6, medium = -12, aLot = -20
        var id: Self { self }
        var title: String {
            switch self {
            case .aLittle: "A little"
            case .medium: "Medium"
            case .aLot: "A lot"
            }
        }
        var gain: Double { pow(10, rawValue / 20) }
    }

    var fileName: String
    var displayName: String
    var credit: String?
    var startOffset: TimeInterval = 0
    var volume: Double = 0.25
    var loop = true
    var duck = true
    var duckAmount: DuckAmount = .medium

    func validate() throws {
        guard !fileName.isEmpty, fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              !fileName.contains("/"), ![".", ".."].contains(fileName),
              startOffset.isFinite, startOffset >= 0,
              volume.isFinite, (0...1).contains(volume) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    static func startOffset(_ value: TimeInterval, duration: TimeInterval) -> TimeInterval {
        min(max(0, value.isFinite ? value : 0), max(0, duration - 0.05))
    }
}
