import CoreGraphics
import Foundation
import Testing

@Suite struct ScrollingEngineTests {
    private typealias F = ScrollingReworkFixture
    private let rect = ScrollingCaptureOutputRect(columns: 4..<44, rows: 60..<140)
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    @Test("A startup redraw waits silently through idle, then accepts the first scroll", arguments: [1, 3])
    func startupRedraw(level: Int) async throws {
        func frame(_ offset: Int, redraw: Int) -> CGImage {
            let pixels = (0..<F.height).flatMap { y in (0..<F.width).map { x -> UInt32 in
                let pageY = offset + y
                if x == 0 { return redraw == 0 ? 0xff111111 : 0xff222222 }
                if pageY % 20 >= 12 { return 0xffffffff }
                if pageY % 20 == 0 { return x % 4 == 0 ? 0xff555555 : 0xffeeeeee }
                let pixel = F.pixel(x: x, pageY: pageY)
                if (17..<34).contains(pageY), (8..<14).contains(x) {
                    return (pixel & 0xffffff00) | UInt32(min(255, Int(pixel & 255) + redraw))
                }
                return pixel
            } }
            return ScrollingCaptureRaster(width: F.width, height: F.height, pixels: pixels)!.image(in: space)!
        }
        let first = frame(0, redraw: 0), redrawn = frame(0, redraw: level)
        let legacy = try #require(ScrollingCaptureStitcher(firstFrame: first, ignoredTrailingColumns: 0))
        #expect(await legacy.add(redrawn) == .unchanged)
        let position = try #require(await legacy.registration)
        #expect(position.offset == 0 && !position.isStatic)
        let engine = try #require(ScrollingCaptureEngine(firstFrame: first, ignoredTrailingColumns: 0))
        #expect(await engine.add(redrawn, at: 1).state == .pending)
        for time in [1.2, 1.4, 1.8, 2.2, 2.6, 5.0] {
            #expect(await engine.noteIdle(at: time).state == .pending)
            #expect(await engine.makeImage()?.height == F.height)
        }
        for (index, offset) in [20, 40].enumerated() {
            let update = await engine.add(frame(offset, redraw: level), at: 6 + Double(index) * 0.05)
            #expect(update.state == .appended && update.height == F.height + offset)
        }
    }

    @Test("Production static dispatch trims to the current box and resumes after a long flick")
    func staticDispatch() async throws {
        let engine = try #require(ScrollingCaptureEngine(firstFrame: F.frame(0).image(in: space)!,
            selection: rect, ignoredTrailingColumns: 0))
        for (index, offset) in [20, 40, 60, 40, 20, 5, 80].enumerated() {
            let update = await engine.add(F.frame(offset).image(in: space)!, at: Double(index + 1) * 0.05)
            #expect(update.state != .lost)
            let image = try #require(await engine.makeImage())
            #expect(update.height == image.height && image.height == offset + 80)
            let output = try #require(ScrollingCaptureRaster(image: image, colorSpace: space))
            for y in 0..<output.height { for x in 0..<output.width {
                #expect(output.pixels[y * output.width + x] == F.pixel(x: x + 4, pageY: y + 60))
            } }
        }
        var update = await engine.add(F.frame(500).image(in: space)!, at: 1)
        for index in 1...25 { update = await engine.add(F.frame(500).image(in: space)!, at: 1 + Double(index) * 0.05) }
        #expect(update.state == .lost && update.height == 160)
        update = await engine.add(F.frame(80).image(in: space)!, at: 3)
        #expect(update.state != .lost && update.height == 160)
    }

    @Test("Hover changes before scrolling remain silent and Done stays available")
    func hoverDispatch() async throws {
        let engine = try #require(ScrollingCaptureEngine(firstFrame: F.frame(0).image(in: space)!,
            selection: rect, ignoredTrailingColumns: 0, scrollInput: quietInput()))
        for phase in 1...40 {
            let update = await engine.add(F.frame(0, phase: phase, video: 60..<100).image(in: space)!)
            #expect(update.state == .pending && update.height == 80)
            #expect(await engine.makeImage()?.height == 80)
        }
    }

    @Test("Wider geometry is display-clipped, and a covered selection or no window falls back to the selection")
    func geometry() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let selection = CGRect(x: 200, y: 300, width: 300, height: 100)
        let window = (frame: CGRect(x: 100, y: -100, width: 700, height: 1000), isTarget: true)
        let wide = ScrollingCaptureRegion.matching(selection: selection, display: display, frontToBackWindows: [window])
        #expect(wide == .init(rect: CGRect(x: 200, y: 0, width: 300, height: 800), reason: .expanded, obstacles: [], target: 0))
        let output = ScrollingCaptureRegion.output(selection: selection, matching: wide.rect, scale: 2)
        #expect(output.columns == 0..<600 && output.rows == 600..<800)
        #expect(ScrollingCaptureRegion.matching(selection: selection, display: display, frontToBackWindows: [])
            == .init(rect: selection, reason: .selectionNotInWindow, obstacles: []))
        let covering = (frame: CGRect(x: 200, y: 300, width: 30, height: 100), isTarget: false)
        #expect(ScrollingCaptureRegion.matching(selection: selection, display: display, frontToBackWindows: [covering, window])
            == .init(rect: selection, reason: .frontNotTarget, obstacles: [0]))
    }

    @Test("The recovery panel stays off the selection while there's room on screen")
    func recoveryPanelPlacement() {
        // AppKit points: a bar 404x76 (12 pt margins) under a region, a strip 404x208.
        let visible = CGRect(x: 0, y: 80, width: 1470, height: 843), size = CGSize(width: 404, height: 208)
        func origin(_ region: CGRect, visible: CGRect = visible) -> CGPoint {
            let bar = CGRect(x: region.midX - 202, y: region.minY - 76, width: 404, height: 76)
            return ScrollingCaptureRegion.recoveryPanelOrigin(size: size, bar: bar, region: region, visible: visible, margin: 12)
        }
        // Room under the bar: the strip goes there, glass 8 pt below the bar's.
        #expect(origin(CGRect(x: 100, y: 400, width: 800, height: 400)) == CGPoint(x: 298, y: 132))
        // user-163: the bar sits just above the Dock, so the strip used to go
        // above the bar, inside the selection. Now it goes beside the region.
        #expect(origin(CGRect(x: 100, y: 200, width: 800, height: 660)) == CGPoint(x: 896, y: 188))
        // A region filling the screen leaves no room: the old near-side spot.
        #expect(origin(CGRect(x: 20, y: 200, width: 1430, height: 700)) == CGPoint(x: 533, y: 184))
    }

    @Test("A static backscroll keeps the current footer once instead of overshoot content")
    func backscrollFooter() async throws {
        let first = F.frame(0, header: 12, footer: 10)
        let engine = try #require(ScrollingCaptureEngine(firstFrame: first.image(in: space)!, ignoredTrailingColumns: 0))
        for offset in [20, 40, 60, 5] {
            let update = await engine.add(F.frame(offset, header: 12, footer: 10).image(in: space)!)
            let image = try #require(await engine.makeImage())
            let output = try #require(ScrollingCaptureRaster(image: image, colorSpace: space))
            #expect(update.height == offset + F.height && output.height == update.height)
            for y in 0..<output.height { for x in 0..<output.width {
                let pageY = y < 12 ? y + 50_000 : y >= offset + 190 ? y - offset + 50_000 : y
                #expect(output.pixels[y * output.width + x] == F.pixel(x: x, pageY: pageY))
            } }
        }
    }

    @Test("Done never pastes a changed badge and thin toolbar at the seam")
    func badgeSeam() async throws {
        let video = 200..<320
        func frame(_ offset: Int, phase: Int) -> CGImage {
            let base = F.frame(offset, phase: phase, video: video, header: 12, footer: 10)
            var pixels = base.pixels
            pixels[5 * F.width + 20] = F.pixel(x: 20, pageY: phase)
            return ScrollingCaptureRaster(width: F.width, height: F.height, pixels: pixels)!.image(in: space)!
        }
        let engine = try #require(ScrollingCaptureEngine(firstFrame: frame(0, phase: 0), selection: rect, ignoredTrailingColumns: 0))
        for (phase, offset) in [20, 40, 60, 80, 80].enumerated() {
            let update = await engine.add(frame(offset, phase: phase + 1))
            #expect(update.state != .lost)
            let image = try #require(await engine.makeImage())
            let output = try #require(ScrollingCaptureRaster(image: image, colorSpace: space))
            #expect(image.height == update.height)
            for y in 0..<output.height where y + 60 < video.lowerBound { for x in 0..<output.width {
                #expect(output.pixels[y * output.width + x] == F.pixel(x: x + 4, pageY: y + 60))
            } }
        }
    }

    @Test("A translating middle that comes to rest cannot discard the proven stationary page")
    func translatingMiddle() async throws {
        let engine = try #require(ScrollingCaptureEngine(firstFrame: F.frame(0).image(in: space)!, ignoredTrailingColumns: 0))
        for offset in [20, 40] { _ = await engine.add(F.frame(offset).image(in: space)!) }
        let before = try #require(await engine.makeImage())
        var pixels = F.frame(40).pixels
        let moved = F.frame(80)
        for y in 60..<140 {
            pixels.replaceSubrange((y * F.width)..<((y + 1) * F.width), with: moved.row(y))
        }
        let animated = ScrollingCaptureRaster(width: F.width, height: F.height, pixels: pixels)!.image(in: space)!
        for _ in 0..<4 {
            let update = await engine.add(animated)
            #expect(update.state != .appended && update.height == before.height)
            let image = try #require(await engine.makeImage())
            #expect(ScrollingCaptureRaster(image: image, colorSpace: space)?.pixels
                == ScrollingCaptureRaster(image: before, colorSpace: space)?.pixels)
        }
    }

    // MARK: - R7 everywhere: wait before a scroll, a new part after one

    /// A session whose scroll monitor runs and has heard no scroll yet.
    private func quietInput() -> ScrollingCaptureScrollInput {
        let input = ScrollingCaptureScrollInput()
        input.monitorStarted()
        return input
    }

    /// A fixed 20-row header over a sparse page, or over a low-contrast one: a
    /// jump of 1000 rows takes either past any overlap.
    private func jumpPage(_ offset: Int, lowContrast: Bool) -> CGImage {
        let pixels = (0..<F.height).flatMap { y in (0..<F.width).map { x -> UInt32 in
            let pageY = offset + y
            if y < 20 { return F.pixel(x: x, pageY: y + 50_000) }
            if lowContrast {
                let raw = F.pixel(x: x, pageY: pageY)
                let red = (raw & 255) % 12 + 100, green = ((raw >> 8) & 255) % 12 + 100, blue = ((raw >> 16) & 255) % 12 + 100
                return 0xff000000 | red | green << 8 | blue << 16
            }
            return (40..<60).contains(pageY % 1000) || (120..<140).contains(pageY % 1000) ? F.pixel(x: x, pageY: pageY) : 0xffffffff
        } }
        return ScrollingCaptureRaster(width: F.width, height: F.height, pixels: pixels)!.image(in: space)!
    }

    @Test("Every frame R7 places is published with R7's exact pixels, a playing video included")
    func r7Everywhere() async throws {
        let video = 100..<180
        let first = F.frame(0, video: video).image(in: space)!
        let legacy = try #require(ScrollingCaptureStitcher(firstFrame: first, ignoredTrailingColumns: 0))
        let engine = try #require(ScrollingCaptureEngine(firstFrame: first, ignoredTrailingColumns: 0))
        for (index, offset) in stride(from: 20, through: 200, by: 20).enumerated() {
            let frame = F.frame(offset, phase: index + 1, video: video).image(in: space)!
            let expected = await legacy.add(frame)
            let update = await engine.add(frame, at: Double(index) * 0.05)
            #expect(update.state == (expected == .appended ? .appended : update.state))
        }
        let old = try #require(await legacy.makeImage()), new = try #require(await engine.makeImage())
        #expect(new.height == F.height + 200)
        #expect(ScrollingCaptureRaster(image: old, colorSpace: space)?.pixels == ScrollingCaptureRaster(image: new, colorSpace: space)?.pixels)
    }

    @Test("Before any scroll, a video playing at rest waits through idle and is never lost; the first scroll is accepted")
    func waitsBeforeScroll() async throws {
        let video = 60..<100
        let first = F.frame(0, video: video).image(in: space)!
        let legacy = try #require(ScrollingCaptureStitcher(firstFrame: first, ignoredTrailingColumns: 0))
        #expect(await legacy.add(F.frame(0, phase: 1, video: video).image(in: space)!) == .noMatch)
        let input = quietInput()
        let engine = try #require(ScrollingCaptureEngine(firstFrame: first, ignoredTrailingColumns: 0,
            scrollInput: input))
        var time = 1.0
        for phase in 1...60 {
            #expect(await engine.add(F.frame(0, phase: phase, video: video).image(in: space)!, at: time).state == .pending)
            time += 0.05
        }
        for _ in 0..<20 { time += 0.1; #expect(await engine.noteIdle(at: time).state == .pending) }
        #expect(await engine.makeImage()?.height == F.height)
        input.noteScroll()
        var height = 0
        for (index, offset) in [20, 40, 60].enumerated() {
            let update = await engine.add(F.frame(offset, phase: 61 + index, video: video).image(in: space)!, at: time + Double(index + 1) * 0.05)
            #expect(update.state != .lost)
            height = update.height
        }
        #expect(height == F.height + 60)
    }

    @Test("After a scroll, a jump R7 can't place is lost at once; with none heard it waits (keyboard, scroll bar, script)",
          arguments: [false, true], [false, true])
    func jumpAfterScroll(lowContrast: Bool, scrolled: Bool) async throws {
        let input = quietInput()
        let engine = try #require(ScrollingCaptureEngine(firstFrame: jumpPage(0, lowContrast: lowContrast),
            ignoredTrailingColumns: 0, scrollInput: input))
        if scrolled { input.noteScroll() }
        let state = await engine.add(jumpPage(1000, lowContrast: lowContrast), at: 1).state
        #expect(state == (scrolled ? .lost : .pending))
        for time in [1.2, 2.31, 5.0] { #expect(await engine.noteIdle(at: time).state == state) }
    }

    @Test("A scroll heard after the frame it moved waited decides that frame on the next idle tick")
    func lateScroll() async throws {
        let input = quietInput()
        let engine = try #require(ScrollingCaptureEngine(firstFrame: jumpPage(0, lowContrast: false),
            ignoredTrailingColumns: 0, scrollInput: input))
        #expect(await engine.add(jumpPage(1000, lowContrast: false), at: 1).state == .pending)
        #expect(await engine.noteIdle(at: 1.2).state == .pending)
        input.noteScroll()
        #expect(await engine.noteIdle(at: 1.3).state == .lost)
    }

    @Test("Once a part has placed a frame, a video at rest waits again until the next scroll")
    func waitsAgainAfterPlacing() async throws {
        let video = 100..<140
        let input = quietInput()
        let engine = try #require(ScrollingCaptureEngine(firstFrame: F.frame(0, video: video).image(in: space)!,
            ignoredTrailingColumns: 0, scrollInput: input))
        input.noteScroll()
        #expect(await engine.add(F.frame(20, phase: 1, video: video).image(in: space)!, at: 1).state == .appended)
        for phase in 2...30 {
            #expect(await engine.add(F.frame(20, phase: phase, video: video).image(in: space)!, at: 1 + Double(phase) * 0.05).state != .lost)
        }
    }

    @Test("Without a running scroll monitor, a frame R7 can't place is lost", arguments: [false, true])
    func unmonitored(hasInput: Bool) async throws {
        let engine = try #require(ScrollingCaptureEngine(firstFrame: jumpPage(0, lowContrast: false), ignoredTrailingColumns: 0,
            scrollInput: hasInput ? ScrollingCaptureScrollInput() : nil))
        #expect(await engine.add(jumpPage(1000, lowContrast: false), at: 1).state == .lost)
    }
}
