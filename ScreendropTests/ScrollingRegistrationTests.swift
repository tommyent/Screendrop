import Testing

@Suite struct ScrollingRegistrationTests {
    private typealias F = ScrollingReworkFixture
    @Test("Wider rest frames register a whole video entering the small output selection")
    func widerVideo() throws {
        let video = 100..<220
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(
            first: F.frame(0, phase: 0, video: video), confirmation: F.frame(0, phase: 1, video: video),
            contentRows: 0..<F.height))
        for (index, offset) in [20, 40, 60, 80, 100, 120, 160, 200, 240].enumerated() {
            #expect(buffer.add(F.frame(offset, phase: index * 2 + 2, video: video), at: index * 2 + 1).state == .pending)
            let event = buffer.add(F.frame(offset, phase: index * 2 + 3, video: video), at: index * 2 + 2)
            #expect(event.state == .appended)
            #expect(event.placements.last?.offset == offset)
        }
        #expect(buffer.frontier == 240)
    }
    @Test("No-scroll hover does not append, lose track or fill the unresolved ring")
    func hover() throws {
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(
            first: F.frame(0), confirmation: F.frame(0), contentRows: 0..<F.height,
            maximumBufferedBytes: F.frame(0).byteCount * 4))
        for index in 1...40 {
            #expect(buffer.add(F.frame(0, phase: index, video: 60..<100), at: index).state == .pending)
            #expect(buffer.pendingCount == 0)
        }
        #expect(buffer.frontier == 0 && !buffer.isLost)
        _ = buffer.add(F.frame(20), at: 41)
        #expect(buffer.add(F.frame(20), at: 42).state == .appended)
    }
    @Test("Changed browser chrome outside the viewport never ends capture")
    func headers() throws {
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(
            first: F.frame(0, header: 12, footer: 10), confirmation: F.frame(0, header: 12, footer: 10),
            contentRows: 12..<190))
        _ = buffer.add(F.frame(30, header: 12, footer: 10), at: 1)
        #expect(buffer.add(F.frame(30, header: 12, footer: 10), at: 2).state == .appended)
        let changed = buffer.add(F.frame(60, header: 6, footer: 10), at: 3)
        #expect(changed.state == .pending)
        #expect(buffer.add(F.frame(60, header: 6, footer: 10), at: 4).state == .appended)
        #expect(buffer.frontier == 60 && !buffer.isLost)
    }
    @Test("Pinned interior zero and lazy relayout never authorize a positive append", arguments: [false, true])
    func contradictoryRows(relayout: Bool) throws {
        let pinned: Range<Int>? = relayout ? nil : 70..<90
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(
            first: F.frame(0, pinned: pinned), confirmation: F.frame(0, pinned: pinned), contentRows: 0..<F.height))
        let changed = F.frame(20, pinned: pinned, relayoutAt: relayout ? 100 : nil)
        _ = buffer.add(changed, at: 1)
        #expect(buffer.add(changed, at: 2).state != .appended)
        #expect(buffer.frontier == 0)
    }
    @Test("Unresolved capacity is bounded in bytes and recovery discards the queue")
    func exhaustion() throws {
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(
            first: F.frame(0, pinned: 70..<90), confirmation: F.frame(0, pinned: 70..<90),
            contentRows: 0..<F.height, maximumBufferedBytes: F.frame(0).byteCount * 4))
        _ = buffer.add(F.frame(20, pinned: 70..<90), at: 1)
        #expect(buffer.add(F.frame(20, pinned: 70..<90), at: 2).state == .pending)
        #expect(buffer.add(F.frame(20, pinned: 70..<90), at: 3).state == .lost)
        #expect(buffer.pendingCount == 0 && buffer.frontier == 0)
        buffer.discardUnresolved()
        #expect(!buffer.isLost && buffer.pendingCount == 0)
    }
    @Test("Older keyframes can bridge a pair whose immediate predecessor has no overlap")
    func olderKeyframe() throws {
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(
            first: F.frame(0), confirmation: F.frame(0), contentRows: 0..<F.height))
        _ = buffer.add(F.frame(150), at: 1)
        #expect(buffer.add(F.frame(150), at: 2).state == .appended)
        _ = buffer.add(F.frame(-50), at: 3)
        let back = buffer.add(F.frame(-50), at: 4)
        #expect(back.state == .pending && back.placements.last?.offset == -50)
        #expect(buffer.lastVerifiedOffset == -50 && buffer.frontier == 150)
    }
    @Test("Invalid dimensions and out-of-order sample indices preserve the frontier")
    func invalidSamples() throws {
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(
            first: F.frame(0), confirmation: F.frame(0), contentRows: 0..<F.height))
        #expect(buffer.add(F.frame(0), at: 0).failure == .invalidSample)
        #expect(buffer.frontier == 0)
        #expect(ScrollingCaptureRaster(width: Int.max, height: 2, pixels: []) == nil)
    }
    @Test("Known moving rows cannot later become the sole displacement witness")
    func temporarilyStillVideo() throws {
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(
            first: F.frame(0, phase: 1, video: 0..<F.height),
            confirmation: F.frame(0, phase: 2, video: 0..<F.height), contentRows: 0..<F.height))
        let still = F.frame(20, phase: 2, video: 0..<F.height)
        _ = buffer.add(still, at: 1)
        #expect(buffer.add(still, at: 2).state != .appended)
        #expect(buffer.frontier == 0)
    }
    @Test("A later exact keyframe resolves a queued sample without guessing its original offset")
    func resolvesBufferedSample() throws {
        let video = 20..<180
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(
            first: F.frame(0, phase: 1, video: video), confirmation: F.frame(0, phase: 2, video: video),
            contentRows: 0..<F.height))
        _ = buffer.add(F.frame(196, phase: 3, video: video), at: 1)
        #expect(buffer.add(F.frame(196, phase: 4, video: video), at: 2).state == .pending)
        #expect(buffer.pendingCount == 1)
        _ = buffer.add(F.frame(5, phase: 5, video: video), at: 3)
        let resolved = buffer.add(F.frame(5, phase: 6, video: video), at: 4)
        #expect(resolved.state == .appended)
        #expect(resolved.placements.map(\.offset) == [196, 5])
        #expect(resolved.placements.map(\.index) == [2, 4])
        #expect(buffer.pendingCount == 0 && buffer.frontier == 196 && buffer.lastVerifiedOffset == 5)
    }
    @Test("Full-size generated matching frames stay within the decoded byte budget")
    func fullSizeFrames() throws {
        let clock = ContinuousClock()
        let start = clock.now
        func view(_ offset: Int) -> ScrollingCaptureRaster {
            let width = 1600, height = 1000
            return ScrollingCaptureRaster(width: width, height: height,
                pixels: (0..<(width * height)).map { F.pixel(x: $0 % width, pageY: $0 / width + offset) })!
        }
        let first = view(0)
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(
            first: first, confirmation: first, contentRows: 0..<1000))
        let next = view(40)
        _ = buffer.add(next, at: 1)
        #expect(buffer.add(next, at: 2).placements.last?.offset == 40)
        #expect(buffer.bufferedBytes <= buffer.maximumBufferedBytes)
        print("WIDER 1600x1000 raster bytes", first.byteCount, "buffer bytes", buffer.bufferedBytes,
              "elapsed", start.duration(to: clock.now))
    }

    @Test("A settled flick with no overlap shows recovery after one second and can re-register")
    func missingOverlap() throws {
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(
            first: F.frame(0), confirmation: F.frame(0), contentRows: 0..<F.height))
        _ = buffer.add(F.frame(40), at: 1)
        #expect(buffer.add(F.frame(40), at: 2).state == .appended)
        _ = buffer.add(F.frame(400), at: 3)
        #expect(buffer.add(F.frame(400), at: 4).pendingReason == .noOverlap)
        #expect(buffer.add(F.frame(400), at: 24).failure == .noOverlap)
        buffer.discardUnresolved()
        _ = buffer.add(F.frame(40), at: 25)
        #expect(buffer.add(F.frame(40), at: 26).placements.last?.offset == 40)
        #expect(!buffer.isLost)
    }
}
