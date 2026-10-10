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
        // The scroll input each decision used; older traces have none and replay without it.
        let input = document.records.contains { $0.scrollInput != nil } ? ScrollingCaptureScrollInput() : nil
        let engine = try #require(ScrollingCaptureEngine(firstFrame: first.image(in: colorSpace)!,
            selection: .init(columns: document.selectionColumns, rows: document.selectionRows),
            ignoredTrailingColumns: document.ignoredTrailingColumns, maximumHeight: document.maximumHeight,
            traceDirectory: directory, scrollInput: input))
        for record in document.records {
            if let recorded = record.scrollInput, let input {
                if recorded.monitored { input.monitorStarted() }
                while input.current.scrolls < recorded.scrolls { input.noteScroll() }
            }
            let frame = try record.input.decoded()
            if let idle = record.timing?.stages["idleObserved"] {
                _ = await engine.noteIdle(at: idle)
            } else {
                _ = await engine.add(frame.image(in: colorSpace)!, at: record.time)
            }
            var actual = await engine.lastTraceRecord(), expected = record
            actual?.timing = nil; expected.timing = nil
            if expected.diagnosticsOmitted == true {
                actual?.bestShift = nil; actual?.changedInPlace = Data()
                actual?.maximumChannelDifference = Data(); actual?.diagnosticsOmitted = true
            }
            #expect(actual == expected, "Replay differs at sample \(record.index)")
        }
        let image = try #require(await engine.makeImage())
        _ = await engine.lastTraceRecord()
        #expect(image.height == document.records.last?.height)
        if let expected = document.outputChecksum {
            let raster = try #require(ScrollingCaptureRaster(image: image, colorSpace: colorSpace))
            #expect(ScrollingCaptureTrace.checksum(raster) == expected)
        }
    }

    @Test("Each record carries the scroll input its decision used")
    func recordsScrollInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = ScrollingCaptureScrollInput()
        input.monitorStarted()
        let engine = try #require(ScrollingCaptureEngine(firstFrame: F.frame(0).image(in: space)!,
            ignoredTrailingColumns: 0, traceDirectory: directory, scrollInput: input))
        _ = await engine.add(F.frame(0).image(in: space)!, at: 1)
        input.noteScroll()
        _ = await engine.add(F.frame(20).image(in: space)!, at: 1.05)
        let record = try #require(await engine.lastTraceRecord())
        #expect(record.scrollInput == .init(monitored: true, scrolls: 1))
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
        _ = await engine.lastTraceRecord() // Drain diagnostics explicitly; Done itself never waits.
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "scrolltrace" })
        let document = try ScrollingCaptureTrace.read(file)
        #expect(document.savedAfterLoss && document.savedOnDone)
        #expect(document.records.count == index + 2 && document.records.last?.height == output.height)
        #expect(document.records.contains { $0.recoveryAttempt })
        #expect(document.records.contains { $0.recoveryPatch != nil })
        #expect(document.records.contains { $0.events.contains { $0.contains("failure:") } })
        #expect(document.records.flatMap(\.events).contains("registration: lost; failure: noOverlap; pending: none"))
        #expect(document.records.flatMap(\.events).allSatisfy { !$0.contains(".ScrollingCapture") })
        #expect(document.records.allSatisfy { $0.diagnosticsOmitted == true ||
            ($0.changedInPlace.count == F.height && $0.maximumChannelDifference.count == F.height) })
        #expect(document.records.last?.input.columns == document.records.last?.matchingColumns)
        try await replay(document)
    }

    @Test("Numeric source/stage timings are retained; repeated recovery failures write only once until Done")
    func timingsAndWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try #require(ScrollingCaptureEngine(firstFrame: F.frame(0).image(in: space)!,
            ignoredTrailingColumns: 0, traceDirectory: directory))
        _ = await engine.add(F.frame(20).image(in: space)!, at: 10,
            timing: .init(sequence: 7, displayTime: 10, callbackTime: 10.01,
                engineEnqueued: 10.02, droppedSinceLast: 2, status: 0))
        await engine.noteTiming(.init(stages: ["uiPublished": 10.03]))
        let timing = try #require(await engine.lastTraceRecord()?.timing)
        #expect(timing.sequence == 7 && timing.droppedSinceLast == 2 && timing.displayTime == 10)
        #expect(timing.stages["uiPublished"] == 10.03)
        for stage in ["engine", "decode", "hash", "r7", "rowStats", "compression", "recordEncode"] {
            let start = try #require(timing.stages[stage + "Started"])
            let end = try #require(timing.stages[stage + "Finished"])
            #expect(end >= start)
        }
        for index in 1...25 { _ = await engine.add(F.frame(1000).image(in: space)!, at: 11 + Double(index) * 0.05) }
        _ = await engine.lastTraceRecord()
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "scrolltrace" })
        #expect(try ScrollingCaptureTrace.read(file).writeTimings?.count == 1)
        _ = await engine.makeImage()
        _ = await engine.lastTraceRecord()
        #expect(try ScrollingCaptureTrace.read(file).writeTimings?.count == 2)
        let writes = try PropertyListDecoder().decode([[String: TimeInterval]].self,
            from: Data(contentsOf: file.appendingPathExtension("timing")))
        #expect(writes.count == 2)
        #expect(writes.allSatisfy { ($0["fileWriteFinished"] ?? 0) >= ($0["fileWriteStarted"] ?? .infinity) })
    }

    @Test("Trace queue exhaustion omits diagnostics explicitly, without retaining uncapped frames")
    func queuedByteCap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let frame = F.frame(0)
        let writer = ScrollingCaptureTraceWriter(first: frame,
            selection: .init(columns: 0..<F.width, rows: 0..<F.height), ignoredTrailingColumns: 0,
            maximumHeight: 1000, colorSpace: space, directory: directory, maximumQueuedBytes: frame.byteCount)
        _ = await writer.document()
        writer.append(.init(index: 1, time: 1, old: frame, frame: frame, viewport: 0..<F.height,
            contentRows: nil, engine: "buffered", state: "lost", height: F.height, events: [],
            recoveryAttempt: false, recoveryRows: nil, recoveryPatch: nil, timing: .init()))
        let document = try #require(await writer.document())
        #expect(document.omittedSamples == 1 && document.records.isEmpty && document.savedAfterLoss)
        #expect(document.lastOmittedEvent?.contains("traceQueueFull") == true)
    }

    @Test("Overload keeps newest exact frames, sheds row statistics and records every gap")
    func latestPendingRing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "trace-overload-test"), gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let first = F.frame(0)
        let geometry = ScrollingCaptureTraceGeometry(displayID: 7,
            selection: CGRect(x: 20, y: 60, width: 40, height: 80),
            matchingRect: CGRect(x: 20, y: 10, width: 40, height: 200),
            targetWindowFrame: CGRect(x: 0, y: 0, width: 500, height: 300), targetWindowLayer: 0,
            reason: "clipped", obstacles: [.init(frame: CGRect(x: 10, y: 210, width: 100, height: 50), layer: 3)])
        let writer = ScrollingCaptureTraceWriter(first: first,
            selection: .init(columns: 0..<F.width, rows: 0..<F.height), ignoredTrailingColumns: 0,
            maximumHeight: 1000, colorSpace: space, directory: directory,
            maximumQueuedBytes: first.byteCount * 6, queue: queue, geometry: geometry)
        for index in 1...40 {
            let frame = F.frame(index / 2)
            writer.append(.init(index: index, time: Double(index), old: F.frame((index - 1) / 2), frame: frame,
                viewport: 0..<F.height, contentRows: nil, engine: "buffered",
                state: index == 1 || index >= 39 ? "lost" : "pending", height: F.height, events: [],
                recoveryAttempt: false, recoveryRows: nil, recoveryPatch: nil, timing: .init(sequence: index)))
        }
        gate.signal()
        let document = try #require(await writer.document())
        #expect(document.records.map(\.index) == [39, 40])
        #expect(document.omittedSamples == 38 && document.omittedRanges == [1..<39])
        #expect(document.savedAfterLoss && document.records.first?.diagnosticsOmitted == true)
        #expect(try document.records.first?.input.decoded() == F.frame(19))
        #expect(try document.records.last?.input.decoded() == F.frame(20))
        let lossFile = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "scrolltrace" })
        #expect(try ScrollingCaptureTrace.read(lossFile).records.last?.index == 39)
        writer.noteTiming(.init(sequence: 39, stages: ["uiEnd": 40.1]))
        writer.append(.init(index: 41, time: 41, old: F.frame(20), frame: F.frame(21),
            viewport: 0..<F.height, contentRows: nil, engine: "buffered", state: "pending",
            height: F.height, events: [], recoveryAttempt: false, recoveryRows: nil,
            recoveryPatch: nil, timing: .init()))
        writer.finish(at: 45)
        _ = await writer.document()
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "scrolltrace" })
        let saved = try ScrollingCaptureTrace.read(file)
        #expect(saved.records.last?.index == 41 && saved.omittedRanges == [1..<39])
        #expect(try saved.records.last?.input.decoded() == F.frame(21))
        #expect(saved.geometry == geometry)
        #expect(saved.records.first { $0.index == 39 }?.timing?.stages["uiEnd"] == 40.1)
        #expect(saved.savedAfterStall == true && !saved.savedOnDone)
    }

    @Test("Stopping on recovery rows then sending only idle recovers on one rest look")
    func idleRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try #require(ScrollingCaptureEngine(firstFrame: F.frame(0).image(in: space)!,
            ignoredTrailingColumns: 0, traceDirectory: directory))
        for (index, offset) in [20, 40, 60].enumerated() {
            _ = await engine.add(F.frame(offset, phase: index, video: 180..<300).image(in: space)!, at: Double(index))
        }
        #expect(await engine.engine == .buffered)
        _ = await engine.add(F.frame(1000).image(in: space)!, at: 3)
        _ = await engine.noteIdle(at: 3.2)
        #expect(await engine.noteIdle(at: 4.2).state == .lost)
        #expect(await engine.add(F.frame(60, phase: 2, video: 180..<300).image(in: space)!, at: 5).state == .lost)
        #expect(await engine.noteIdle(at: 5.2).state != .lost)
        let recovered = try #require(await engine.lastTraceRecord())
        #expect(recovered.events.contains { $0.hasPrefix("recovery: 60;") }, "\(recovered.events)")
        #expect(recovered.timing?.stages["idleObserved"] == 5.2)
        for index in 1...20 { #expect(await engine.noteIdle(at: 5.2 + Double(index) * 0.05).state != .lost) }
        #expect(await engine.lastTraceRecord()?.index == recovered.index)
        _ = await engine.makeImage()
        _ = await engine.lastTraceRecord()
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "scrolltrace" })
        try await replay(ScrollingCaptureTrace.read(file))
    }

    @Test("Capped history freezes a few records after the first loss, with explicit gaps and bounded private files")
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
            // The first loss (sample 2) and at most six after it stay; later lost frames are explicit gaps.
            let kept = trace.document.records.map(\.index)
            #expect(kept.contains(2) && kept.last! <= 8 && kept == Array(kept.first!...kept.last!))
            #expect(trace.document.omittedRanges == (kept.first! > 1 ? [1..<kept.first!] : []) + [(kept.last! + 1)..<50])
            #expect(trace.document.lastOmittedEvent == "sample 49: traceFrozenAfterLoss")
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        #expect(try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) } <= 600_000)
        #expect(try files.allSatisfy { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize! <= 150_000 })
    }

    @Test("Lost frames after the first loss never evict the frames leading up to it")
    func frozenAfterLoss() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = F.frame(0)
        var trace = try ScrollingCaptureTrace(first: first, selection: .init(columns: 0..<F.width, rows: 0..<F.height),
            ignoredTrailingColumns: 0, maximumHeight: 1000, colorSpace: space, directory: directory,
            maximumBytes: 2_000_000)
        for index in 1...200 {
            trace.append(.init(index: index, time: Double(index), input: try ScrollingCaptureTrace.Raster(F.frame(index)),
                viewport: 0..<F.height, contentRows: nil, matchingColumns: first.matchingColumns, engine: "buffered",
                state: index < 101 ? "pending" : "lost", height: F.height, events: [], recoveryAttempt: false,
                recoveryRows: nil, recoveryPatch: nil, bestShift: nil, changedInPlace: Data(), maximumChannelDifference: Data()))
        }
        let kept = trace.document.records.map(\.index)
        // Pending history up to the loss at 101, then exactly six lost frames; nothing after them.
        #expect(kept.count > 20 && kept.last == 107 && kept == Array(kept.first!...107), "\(kept)")
        #expect(trace.document.omittedRanges == [1..<kept.first!, 108..<201])
    }

    @Test("A loss dropped before it reached the history freezes it the same way", arguments: ["lost", "limit"])
    func frozenAfterOmittedLoss(state: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = F.frame(0)
        var trace = try ScrollingCaptureTrace(first: first, selection: .init(columns: 0..<F.width, rows: 0..<F.height),
            ignoredTrailingColumns: 0, maximumHeight: 1000, colorSpace: space, directory: directory,
            maximumBytes: 2_000_000)
        func append(_ index: Int, state: String) throws {
            trace.append(.init(index: index, time: Double(index), input: try ScrollingCaptureTrace.Raster(F.frame(index)),
                viewport: 0..<F.height, contentRows: nil, matchingColumns: first.matchingColumns, engine: "buffered",
                state: state, height: F.height, events: [], recoveryAttempt: false, recoveryRows: nil,
                recoveryPatch: nil, bestShift: nil, changedInPlace: Data(), maximumChannelDifference: Data()))
        }
        for index in 1...100 { try append(index, state: "pending") }
        let before = trace.document.records.map(\.index)
        trace.omit(index: 101, state: state)
        for index in 102...200 { try append(index, state: state) }
        // No pre-loss sample is evicted, and exactly six follow the dropped loss.
        #expect(trace.document.records.map(\.index) == before + Array(102...107))
        #expect(trace.document.omittedRanges == [1..<before.first!, 101..<102, 108..<201])
    }

    @Test("History eviction cannot reset the stalled-session deadline")
    func stalledHistoryRing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let frame = F.frame(0), input = try ScrollingCaptureTrace.Raster(frame)
        var trace = try ScrollingCaptureTrace(first: frame,
            selection: .init(columns: 0..<F.width, rows: 0..<F.height), ignoredTrailingColumns: 0,
            maximumHeight: 1000, colorSpace: space, directory: directory, maximumBytes: 150_000)
        for index in 1...50 {
            trace.append(.init(index: index, time: 1 + Double(index) / 100, input: input,
                viewport: 0..<F.height, contentRows: nil, matchingColumns: frame.matchingColumns,
                engine: "buffered", state: index == 1 ? "appended" : "pending", height: F.height,
                events: [], recoveryAttempt: false, recoveryRows: nil, recoveryPatch: nil,
                bestShift: nil, changedInPlace: Data(), maximumChannelDifference: Data()))
        }
        #expect(trace.document.omittedSamples > 0 && trace.document.records.first?.index != 1)
        trace.save(endedAt: 4.02)
        #expect(trace.document.savedAfterStall == true && !trace.document.savedAfterLoss)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "scrolltrace" })
        #expect(try ScrollingCaptureTrace.read(file).records.last?.index == 50)
    }

    @Test("A legacy jump with repeated divider rows reaches recovery on idle", arguments: [false, true])
    func legacyIdleJump(slowScroll: Bool) async throws {
        for sharedDivider in [false, true] {
            func frame(_ offset: Int) -> CGImage {
                let pixels = (0..<F.height).flatMap { y in (0..<F.width).map { x -> UInt32 in
                    let pageY = offset + y
                    if pageY % 20 >= 12 { return 0xffffffff }
                    if sharedDivider && pageY % 20 == 0 { return x % 4 == 0 ? 0xff555555 : 0xffeeeeee }
                    return F.pixel(x: x, pageY: pageY)
                } }
                return ScrollingCaptureRaster(width: F.width, height: F.height, pixels: pixels)!.image(in: space)!
            }
            let engine = try #require(ScrollingCaptureEngine(firstFrame: frame(0),
                ignoredTrailingColumns: 0, traceDirectory: nil))
            if slowScroll {
                for (index, offset) in [20, 40].enumerated() {
                    let update = await engine.add(frame(offset), at: Double(index + 1) * 0.05)
                    #expect(update.engine == .legacy && update.height == offset + F.height)
                }
            }
            let before = try #require(await engine.makeImage())
            _ = await engine.add(frame(1000), at: 1)
            _ = await engine.add(frame(1020), at: 1.05)
            #expect(await engine.noteIdle(at: 1.2).state == .pending)
            #expect(await engine.noteIdle(at: 1.3).state == .pending)
            #expect(await engine.noteIdle(at: 2.31).state == .lost)
            let after = try #require(await engine.makeImage())
            #expect(ScrollingCaptureRaster(image: after, colorSpace: space) == ScrollingCaptureRaster(image: before, colorSpace: space))
            _ = await engine.add(frame(slowScroll ? 40 : 0), at: 3)
            #expect(await engine.noteIdle(at: 3.2).state != .lost)
            #expect(await engine.noteIdle(at: 5).state != .lost)
        }
    }

    @Test("Idle on an accepted page or no-scroll hover never raises recovery", arguments: [false, true])
    func acceptedIdle(hover: Bool) async throws {
        let engine = try #require(ScrollingCaptureEngine(firstFrame: F.frame(0).image(in: space)!,
            ignoredTrailingColumns: 0, traceDirectory: nil))
        let offset = hover ? 0 : 20
        _ = await engine.add(F.frame(offset, phase: 1, video: hover ? 60..<100 : nil).image(in: space)!, at: 1)
        for time in [1.2, 1.3, 2.4, 5.0] { #expect(await engine.noteIdle(at: time).state != .lost) }
        #expect(await engine.makeImage()?.height == F.height + offset)
    }

    @Test("Done and Cancel preserve an opted-in pending stall without claiming a loss", arguments: [false, true])
    func stalledSessionEnd(cancel: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try #require(ScrollingCaptureEngine(firstFrame: F.frame(0).image(in: space)!,
            ignoredTrailingColumns: 0, traceDirectory: directory))
        #expect(await engine.add(F.frame(0, phase: 1, video: 60..<100).image(in: space)!, at: 1).state == .pending)
        if cancel {
            await engine.finishTrace(at: 4.1)
        } else {
            #expect(await engine.makeImage(at: 4.1)?.height == F.height)
        }
        _ = await engine.lastTraceRecord()
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "scrolltrace" })
        let document = try ScrollingCaptureTrace.read(file)
        #expect(document.savedAfterStall == true && !document.savedAfterLoss)
        #expect(document.savedOnDone == !cancel && (document.outputChecksum == nil) == cancel)
        #expect(document.endedAt == 4.1 && document.records.allSatisfy { $0.state == "pending" })
    }

    @Test("A short pending interval is not a stall, and progress resets its deadline")
    func stallDeadline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let frame = F.frame(0), input = try ScrollingCaptureTrace.Raster(frame)
        var trace = try ScrollingCaptureTrace(first: frame, selection: .init(columns: 0..<F.width, rows: 0..<F.height),
            ignoredTrailingColumns: 0, maximumHeight: 1000, colorSpace: space, directory: directory)
        func record(_ index: Int, time: Double, height: Int, state: String) -> ScrollingCaptureTrace.Record {
            .init(index: index, time: time, input: input, viewport: 0..<F.height, contentRows: nil,
                matchingColumns: frame.matchingColumns, engine: "legacy", state: state, height: height,
                events: [], recoveryAttempt: false, recoveryRows: nil, recoveryPatch: nil,
                bestShift: 0, changedInPlace: Data(), maximumChannelDifference: Data())
        }
        trace.append(record(1, time: 1, height: F.height, state: "pending"))
        trace.save(endedAt: 3.9)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        trace.append(record(2, time: 3, height: F.height + 20, state: "appended"))
        trace.append(record(3, time: 3.1, height: F.height + 20, state: "pending"))
        trace.save(endedAt: 5.9)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        trace.save(endedAt: 6)
        #expect(trace.document.savedAfterStall == true && !trace.document.savedAfterLoss && !trace.document.savedOnDone)
        #expect(FileManager.default.fileExists(atPath: directory.path))
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
