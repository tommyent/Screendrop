import CoreGraphics
import Foundation
import Testing

@Suite struct ScrollingTraceTests {
    private typealias F = ScrollingReworkFixture
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private func replay(_ document: ScrollingCaptureTrace.Document) async throws {
        try #require(document.omittedSamples == 0, "Trace reached its size limit; it is explicitly incomplete")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let colorSpace = document.colorProfile.flatMap { CGColorSpace(iccData: $0 as CFData) } ?? space
        let first = try document.first.decoded()
        let engine = try #require(ScrollingCaptureEngine(firstFrame: first.image(in: colorSpace)!,
            selection: .init(columns: document.selectionColumns, rows: document.selectionRows),
            ignoredTrailingColumns: document.ignoredTrailingColumns, maximumHeight: document.maximumHeight,
            traceDirectory: directory))
        for record in document.records {
            let frame = try record.input.decoded()
            _ = await engine.add(frame.image(in: colorSpace)!, at: record.time)
            #expect(await engine.lastTraceRecord() == record, "Replay differs at sample \(record.index)")
        }
        let image = try #require(await engine.makeImage())
        #expect(image.height == document.records.last?.height)
        if let expected = document.outputChecksum {
            let raster = try #require(ScrollingCaptureRaster(image: image, colorSpace: colorSpace))
            #expect(ScrollingCaptureTrace.checksum(raster) == expected)
        }
    }

    @Test("Exact inputs, masks, events and recovery attempts replay deterministically")
    func roundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try #require(ScrollingCaptureEngine(firstFrame: F.frame(0).image(in: space)!,
            selection: .init(columns: 4..<44, rows: 60..<140), ignoredTrailingColumns: 1,
            traceDirectory: directory))
        var index = 0
        for offset in stride(from: 20, through: 240, by: 20) {
            index += 1
            _ = await engine.add(F.frame(offset, phase: index, video: 180..<300).image(in: space)!, at: Double(index) * 0.05)
        }
        for _ in 0..<25 {
            index += 1
            _ = await engine.add(F.frame(1000).image(in: space)!, at: Double(index) * 0.05)
        }
        _ = await engine.add(F.frame(240).image(in: space)!, at: Double(index + 1) * 0.05)
        _ = await engine.add(F.frame(240).image(in: space)!, at: Double(index + 2) * 0.05)
        let output = try #require(await engine.makeImage())
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let document = try ScrollingCaptureTrace.read(file)
        #expect(document.savedAfterLoss && document.savedOnDone)
        #expect(document.records.count == index + 2 && document.records.last?.height == output.height)
        #expect(document.records.contains { $0.recoveryAttempt })
        #expect(document.records.contains { $0.recoveryPatch != nil })
        #expect(document.records.contains { $0.events.contains { $0.contains("failure:") } })
        #expect(document.records.flatMap(\.events).contains("registration: lost; failure: noOverlap; pending: none"))
        #expect(document.records.flatMap(\.events).allSatisfy { !$0.contains(".ScrollingCapture") })
        #expect(document.records.allSatisfy { $0.changedInPlace.count == F.height && $0.maximumChannelDifference.count == F.height })
        #expect(document.records.last?.input.columns == document.records.last?.matchingColumns)
        try await replay(document)
    }

    @Test("Traces save only after loss; capped history is explicitly incomplete and pruned")
    func limits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = F.frame(0)
        let input = try ScrollingCaptureTrace.Raster(first)
        func record(_ index: Int, state: String) -> ScrollingCaptureTrace.Record {
            .init(index: index, time: Double(index), input: input, viewport: 0..<F.height,
                contentRows: nil, matchingColumns: first.matchingColumns, engine: "buffered", state: state,
                height: F.height, events: ["test"], recoveryAttempt: false, recoveryRows: nil,
                recoveryPatch: nil, bestShift: 0, changedInPlace: Data(repeating: 0, count: F.height),
                maximumChannelDifference: Data(repeating: 0, count: F.height))
        }
        for run in 0..<8 {
            var trace = try ScrollingCaptureTrace(first: first, selection: .init(columns: 0..<F.width, rows: 0..<F.height),
                ignoredTrailingColumns: 0, maximumHeight: 1000, colorSpace: space,
                directory: directory, maximumBytes: 150_000)
            trace.append(record(1, state: "pending")); trace.save()
            if run == 0 { #expect(!FileManager.default.fileExists(atPath: directory.path)) }
            for index in 2..<50 { trace.append(record(index, state: "lost")) }
            trace.save(done: true)
            #expect(trace.document.omittedSamples > 0)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        #expect(try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) } <= 600_000)
        #expect(try files.allSatisfy { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize! <= 150_000 })
    }

    @Test("Row diagnostics separate translation, redraw and local motion without supplying an offset")
    func rowStats() {
        let old = F.frame(0), new = F.frame(20, phase: 3, video: 80..<120)
        let stats = ScrollingCaptureTrace.differences(from: old, to: new, rows: 0..<F.height)
        #expect(stats.shift == 20)
        #expect(stats.changed.allSatisfy { $0 == 1 })
        #expect(stats.difference[0] == 0 && stats.difference[60] > 2)
    }

    @Test("Replay a local failure trace (never checked into git)",
          .enabled(if: ProcessInfo.processInfo.environment["SUKUSHO_SCROLL_TRACE"] != nil))
    func externalTrace() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SUKUSHO_SCROLL_TRACE"])
        try await replay(ScrollingCaptureTrace.read(URL(fileURLWithPath: path)))
    }

    @Test("Private direction regression grows past the repeated-post rival and keeps complete source rows",
          .enabled(if: ProcessInfo.processInfo.environment["SUKUSHO_SCROLL_DIRECTION_TRACE"] != nil))
    func externalDirectionTrace() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SUKUSHO_SCROLL_DIRECTION_TRACE"])
        let document = try ScrollingCaptureTrace.read(URL(fileURLWithPath: path))
        let colorSpace = document.colorProfile.flatMap { CGColorSpace(iccData: $0 as CFData) } ?? space
        let first = try document.first.decoded()
        let engine = try #require(ScrollingCaptureEngine(firstFrame: first.image(in: colorSpace)!,
            selection: .init(columns: document.selectionColumns, rows: document.selectionRows),
            ignoredTrailingColumns: document.ignoredTrailingColumns, traceDirectory: nil))
        var maximum = 0
        for record in document.records {
            let frame = try record.input.decoded()
            let update = await engine.add(frame.image(in: colorSpace)!, at: record.time)
            maximum = max(maximum, update.height)
            if record.index == 8 {
                let image = try #require(await engine.makeImage())
                let output = try #require(ScrollingCaptureRaster(image: image, colorSpace: colorSpace))
                try #require(output.height >= 2506 && output.width == frame.width && frame.height == 1084)
                #expect(Array(output.pixels[(1422 * output.width)..<(2506 * output.width)]) == frame.pixels)
            }
        }
        #expect(maximum >= 2506)
    }
}
