import Testing

@Suite struct ScrollingSettleTests {
    private typealias F = ScrollingReworkFixture

    @Test("Three registered observations settle media only as corroboration, never sole page authority")
    func settledMedia() throws {
        let video = 100..<160
        let first = F.frame(0, phase: 2, video: video)
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(first: first, confirmation: first,
            contentRows: 0..<F.height, observedMotionRows: Set(video),
            pageWitnessRows: Set(0..<100).union(160..<200)))
        var placement: ScrollingCapturePlacement?
        for (index, offset) in [20, 30, 40, 50, 60].enumerated() {
            placement = buffer.add(F.frame(offset, phase: 2, video: video), at: index + 1).placements.last
            #expect(placement?.offset == offset)
        }
        #expect(buffer.settledPageRows == Set(video))
        #expect(placement?.corroboratingRows == Set(40..<100))
        #expect(placement?.stableRows.allSatisfy { !video.contains($0 + 60) } == true)
        func onlyMedia(_ offset: Int) -> ScrollingCaptureRaster {
            let base = F.frame(offset, phase: 2, video: video)
            var pixels = base.pixels
            for y in 0..<F.height where !video.contains(offset + y) {
                for x in 0..<F.width { pixels[y * F.width + x] = F.pixel(x: x, pageY: y + 70_000) }
            }
            return ScrollingCaptureRaster(width: F.width, height: F.height, pixels: pixels)!
        }
        #expect(buffer.add(onlyMedia(80), at: 6).state != .appended)
        #expect(buffer.add(onlyMedia(80), at: 7).state != .appended)
        #expect(buffer.lastVerifiedOffset == 60)
    }

    @Test("Settled rows that change revoke corroboration on the next independently registered frame")
    func changingAgain() throws {
        let video = 100..<160
        let first = F.frame(0, phase: 2, video: video)
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(first: first, confirmation: first,
            contentRows: 0..<F.height, observedMotionRows: Set(video),
            pageWitnessRows: Set(0..<100).union(160..<200)))
        for (index, offset) in [20, 30, 40, 50].enumerated() {
            #expect(buffer.add(F.frame(offset, phase: 2, video: video), at: index + 1).placements.last?.offset == offset)
        }
        #expect(!buffer.settledPageRows.isEmpty)
        let placement = try #require(buffer.add(F.frame(60, phase: 3, video: video), at: 5).placements.last)
        #expect(buffer.settledPageRows.isEmpty && placement.corroboratingRows.isEmpty)
        #expect(placement.motionRows == Set(40..<100))
    }

    @Test("Settled media conflicting with the page vetoes a position; agreement still registers")
    func settledConflict() throws {
        let video = 100..<160
        let first = F.frame(0, phase: 2, video: video)
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(first: first, confirmation: first,
            contentRows: 0..<F.height, observedMotionRows: Set(video),
            pageWitnessRows: Set(0..<100).union(160..<200)))
        for (index, offset) in [20, 30, 40, 50, 60].enumerated() {
            #expect(buffer.add(F.frame(offset, phase: 2, video: video), at: index + 1).placements.last?.offset == offset)
        }
        let moved = F.frame(80, phase: 2, video: video), old = F.frame(60, phase: 2, video: video)
        var pixels = moved.pixels
        for y in 40..<100 { pixels.replaceSubrange((y * F.width)..<((y + 1) * F.width), with: old.row(y)) }
        let pinned = try #require(ScrollingCaptureRaster(width: F.width, height: F.height, pixels: pixels))
        #expect(buffer.add(pinned, at: 6).state != .appended && buffer.lastVerifiedOffset == 60)
        #expect(buffer.add(moved, at: 7).placements.last?.offset == 80)
    }

    private func primed(bytes: Int = 128 * 1024 * 1024) throws -> ScrollingCaptureRegistrationBuffer {
        let video = 20..<180
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(first: F.frame(0, phase: 1, video: video),
            confirmation: F.frame(0, phase: 2, video: video), contentRows: 0..<F.height,
            maximumBufferedBytes: bytes, pageWitnessRows: Set(0..<20).union(180..<200)))
        #expect(buffer.add(F.frame(5, phase: 3, video: video), at: 1, time: 10).placements.last?.offset == 5)
        return buffer
    }

    @Test("A moving unresolved sample is retained and later registered against an independently verified key")
    func movingBackfill() throws {
        var buffer = try primed()
        let pending = buffer.add(F.frame(196), at: 2, time: 10.05)
        #expect(pending.state == .pending && buffer.pendingCount == 1)
        let resolved = buffer.add(F.frame(190), at: 3, time: 10.10)
        #expect(resolved.placements.map(\.offset) == [196, 190])
        #expect(resolved.placements.map(\.index) == [2, 3])
        #expect(buffer.pendingCount == 0 && buffer.lastVerifiedOffset == 190)
    }

    @Test("Dominant motion retention is bounded by actual sample time and by decoded bytes", arguments: [false, true])
    func retentionLimits(bytes: Bool) throws {
        var buffer = try primed(bytes: bytes ? F.frame(0).byteCount * 5 : 128 * 1024 * 1024)
        let a = F.frame(400, phase: 10, video: 400..<600)
        #expect(buffer.add(a, at: 2, time: 10.05).state == .pending)
        #expect(buffer.pendingCount == 1)
        let end = buffer.add(F.frame(400, phase: 11, video: 400..<600), at: 3, time: bytes ? 10.10 : 12.10)
        #expect(end.failure == (bytes ? .bufferExhausted : .motionTimeout))
        #expect(buffer.pendingCount == 0 && buffer.lastVerifiedOffset == 5)
        buffer.discardUnresolved()
        #expect(!buffer.isLost && buffer.pendingCount == 0)
    }
}
