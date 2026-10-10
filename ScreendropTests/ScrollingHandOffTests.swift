// Generated pixels only: no captured screens or third-party content.
import CoreGraphics
import Foundation
import Testing

@Suite struct ScrollingHandOffTests {
    private typealias F = ScrollingReworkFixture
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A page whose row `y` shows the fixture row `source(y)`, with page-anchored
    /// video in `video` so R7's first append isn't static and hands over.
    private func frame(_ offset: Int, phase: Int, video: Range<Int> = 60..<100,
                       source: (Int) -> Int) -> CGImage {
        var pixels: [UInt32] = []
        for y in 0..<F.height { for x in 0..<F.width {
            let pageY = offset + y
            pixels.append(video.contains(pageY) && x < F.width - 4
                ? 0xff000000 | UInt32((phase * 701 + x * 107 + pageY * 53) & 0xffffff)
                : F.pixel(x: x, pageY: source(pageY)))
        } }
        return ScrollingCaptureRaster(width: F.width, height: F.height, pixels: pixels)!.image(in: space)!
    }

    private func run(_ source: @escaping (Int) -> Int) async throws -> [ScrollingCaptureEngine.Update] {
        let engine = try #require(ScrollingCaptureEngine(firstFrame: frame(0, phase: 0, source: source),
            ignoredTrailingColumns: 0, traceDirectory: nil))
        var updates: [ScrollingCaptureEngine.Update] = []
        // Still first, then gentle moves, as in user-2347.
        for (index, offset) in [0, 0, 16, 42, 76, 124].enumerated() {
            updates.append(await engine.add(frame(offset, phase: index + 1, source: source), at: Double(index + 1) * 0.05))
        }
        return updates
    }

    @Test("A still page's first move hands over, and gentle shifts place past a faint repeat")
    func firstMove() async throws {
        // Rows 150..<162 repeat rows 0..<12: a rival 12 rows strong, far below the true shift.
        let updates = try await run { $0 >= 150 && $0 < 162 ? $0 - 150 : $0 }
        #expect(updates.last?.height == F.height + 124, "\(updates.map { "\($0.state)/\($0.height)" })")
    }

    @Test("With no travel yet, the strongest witnessed shift places only with a clear margin over every rival",
          arguments: [("clear winner", Set(0..<200), 20), ("close rival", Set(0..<30).union(100..<120), nil),
                      ("tied rival", Set(0..<20).union(100..<120), nil)] as [(String, Set<Int>, Int?)])
    func rivalMargin(_ name: String, witnesses: Set<Int>, expected: Int?) throws {
        // Rows 100..<120 repeat rows 0..<20, so a 20-row rival sits 100 rows behind the true shift.
        func frame(_ offset: Int) -> ScrollingCaptureRaster {
            let pixels = (0..<F.height).flatMap { y in
                let pageY = offset + y
                return (0..<F.width).map { F.pixel(x: $0, pageY: (100..<120).contains(pageY) ? pageY - 100 : pageY) }
            }
            return ScrollingCaptureRaster(width: F.width, height: F.height, pixels: pixels)!
        }
        // Direction 0, as right after the hand-off: every candidate counts as forward.
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(first: frame(0), confirmation: frame(0),
            contentRows: 0..<F.height, pageWitnessRows: witnesses, direction: 0))
        #expect(buffer.add(frame(20), at: 1).placements.last?.offset == expected, "\(name)")
    }

    @Test("Private user-2347 trace grows through its first-move hand-off",
          .enabled(if: ProcessInfo.processInfo.environment["SUKUSHO_SCROLL_HANDOFF_TRACE"] != nil))
    func externalHandOffTrace() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SUKUSHO_SCROLL_HANDOFF_TRACE"])
        let document = try ScrollingCaptureTrace.read(URL(fileURLWithPath: path))
        let colorSpace = document.colorProfile.flatMap { CGColorSpace(iccData: $0 as CFData) } ?? space
        let engine = try #require(ScrollingCaptureEngine(firstFrame: try document.first.decoded().image(in: colorSpace)!,
            selection: .init(columns: document.selectionColumns, rows: document.selectionRows),
            ignoredTrailingColumns: document.ignoredTrailingColumns, maximumHeight: document.maximumHeight,
            traceDirectory: nil))
        var heights: [Int] = []
        for record in document.records {
            let update = await engine.add(try record.input.decoded().image(in: colorSpace)!, at: record.time)
            if update.state == .appended { heights.append(update.height) }
        }
        // It stuck at the first frame's height; it must now append several times, each taller.
        #expect(heights.count >= 5 && heights == heights.sorted() && Set(heights).count == heights.count, "\(heights)")
    }
}
