import CoreGraphics
import Testing

@Suite struct ScrollingEngineTests {
    private typealias F = ScrollingReworkFixture
    private let rect = ScrollingCaptureOutputRect(columns: 4..<44, rows: 60..<140)
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    @Test("Legacy redraw dispatch stops at two levels per channel", arguments: [2, 3])
    func redrawDispatch(level: Int) async throws {
        let first = SyntheticFixtures.list(offset: 0, redraw: 0)
        let next = SyntheticFixtures.list(offset: 664, redraw: level)
        let legacy = try #require(ScrollingCaptureStitcher(firstFrame: first, ignoredTrailingColumns: 40))
        let engine = try #require(ScrollingCaptureEngine(firstFrame: first, ignoredTrailingColumns: 40))
        #expect(await legacy.add(next) == .appended)
        let update = await engine.add(next)
        if level == 2 {
            #expect(update.state == .appended && update.engine == .legacy && update.height == 2322)
            let old = try #require(await legacy.makeImage()), new = try #require(await engine.makeImage())
            #expect(ScrollingCaptureRaster(image: old, colorSpace: space)?.pixels
                == ScrollingCaptureRaster(image: new, colorSpace: space)?.pixels)
        } else {
            #expect(update.state != .appended && update.engine == .buffered && update.height == first.height)
        }
    }

    @Test("Production static dispatch trims to the current box and resumes after a long flick")
    func staticDispatch() async throws {
        let engine = try #require(ScrollingCaptureEngine(firstFrame: F.frame(0).image(in: space)!,
            selection: rect, ignoredTrailingColumns: 0))
        for offset in [20, 40, 60, 40, 20, 5, 80] {
            let update = await engine.add(F.frame(offset).image(in: space)!)
            #expect(update.state != .lost && update.engine == .legacy)
            let image = try #require(await engine.makeImage())
            #expect(update.height == image.height && image.height == offset + 80)
            let output = try #require(ScrollingCaptureRaster(image: image, colorSpace: space))
            for y in 0..<output.height { for x in 0..<output.width {
                #expect(output.pixels[y * output.width + x] == F.pixel(x: x + 4, pageY: y + 60))
            } }
        }
        var update = await engine.add(F.frame(500).image(in: space)!)
        for _ in 0..<25 { update = await engine.add(F.frame(500).image(in: space)!) }
        #expect(update.state == .lost && update.height == 160)
        update = await engine.add(F.frame(80).image(in: space)!)
        #expect(update.state != .lost && update.height == 160)
    }

    @Test("Production dispatch never publishes R7's changing slices and freezes the entire video", arguments: [100, 160])
    func videoDispatch(videoStart: Int) async throws {
        let video = videoStart..<(videoStart + 120)
        let engine = try #require(ScrollingCaptureEngine(firstFrame: F.frame(0, video: video).image(in: space)!,
            selection: rect, ignoredTrailingColumns: 0))
        for (step, offset) in stride(from: 20, through: 240, by: 20).enumerated() {
            for phase in 0..<2 {
                let update = await engine.add(F.frame(offset, phase: step * 2 + phase + 1, video: video).image(in: space)!)
                #expect(update.state != .lost)
                #expect(await engine.makeImage() != nil)
            }
        }
        let image = try #require(await engine.makeImage())
        let output = try #require(ScrollingCaptureRaster(image: image, colorSpace: space))
        #expect(output.height == 320)
        #expect(await engine.engine == .buffered)
        var phases = Set<UInt32>()
        for y in 0..<output.height { for x in 0..<output.width {
            let pageY = y + 60, sourceX = x + 4, pixel = output.pixels[y * output.width + x]
            if video.contains(pageY) { phases.insert((pixel & 0xffffff) - UInt32(sourceX * 107 + pageY * 53)) }
            else { #expect(pixel == F.pixel(x: sourceX, pageY: pageY)) }
        } }
        #expect(phases.count == 1)
        var update = await engine.add(F.frame(600, phase: 50, video: video).image(in: space)!)
        for _ in 0..<25 { update = await engine.add(F.frame(600, phase: 50, video: video).image(in: space)!) }
        #expect(update.state == .lost)
        let recovery = videoStart == 160 ? 80 : 160
        _ = await engine.add(F.frame(recovery, phase: 60, video: video).image(in: space)!)
        update = await engine.add(F.frame(recovery, phase: 61, video: video).image(in: space)!)
        #expect(update.state != .lost && update.height == recovery + 80 && update.engine == .buffered)
    }

    @Test("Hover changes before scrolling remain silent and Done stays available")
    func hoverDispatch() async throws {
        let engine = try #require(ScrollingCaptureEngine(firstFrame: F.frame(0).image(in: space)!,
            selection: rect, ignoredTrailingColumns: 0))
        for phase in 1...40 {
            let update = await engine.add(F.frame(0, phase: phase, video: 60..<100).image(in: space)!)
            #expect(update.state == .pending && update.height == 80)
            #expect(await engine.makeImage()?.height == 80)
        }
    }

    @Test("A previously redrawn gutter stays excluded after static legacy frames")
    func retainedChromeColumns() async throws {
        let video = 180..<300
        func frame(_ offset: Int, phase: Int, gutter: UInt32) -> CGImage {
            let base = F.frame(offset, phase: phase, video: video)
            var pixels = base.pixels
            for y in 0..<F.height { pixels[y * F.width + 43] = gutter }
            return ScrollingCaptureRaster(width: F.width, height: F.height, pixels: pixels)!.image(in: space)!
        }
        let engine = try #require(ScrollingCaptureEngine(firstFrame: frame(0, phase: 0, gutter: 0xff111111),
            selection: rect, ignoredTrailingColumns: 0))
        for (step, offset) in stride(from: 20, through: 360, by: 20).enumerated() {
            for sample in 0..<2 {
                let gutter: UInt32 = step < 7 ? 0xff222222 : step % 2 == 0 ? 0xff333333 : 0xff444444
                let update = await engine.add(frame(offset, phase: step * 2 + sample + 1, gutter: gutter))
                #expect(update.state != .lost)
            }
        }
        let image = try #require(await engine.makeImage())
        let output = try #require(ScrollingCaptureRaster(image: image, colorSpace: space))
        print("RETAINED GUTTER", output.height, await engine.engine)
        try #require(output.height == 440)
        var phases = Set<UInt32>()
        for y in 0..<output.height { for x in 0..<(output.width - 1) {
            let pageY = y + 60, sourceX = x + 4, pixel = output.pixels[y * output.width + x]
            if video.contains(pageY) { phases.insert((pixel & 0xffffff) - UInt32(sourceX * 107 + pageY * 53)) }
            else { #expect(pixel == F.pixel(x: sourceX, pageY: pageY)) }
        } }
        #expect(phases.count == 1)
    }

    @Test("Wider geometry is display-clipped and ambiguous/occluded windows fall back to selection")
    func geometry() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let selection = CGRect(x: 200, y: 300, width: 300, height: 100)
        let window = CGRect(x: 100, y: -100, width: 700, height: 1000)
        let wide = ScrollingCaptureRegion.matching(selection: selection, display: display, frontToBackWindows: [window])
        #expect(wide == CGRect(x: 200, y: 0, width: 300, height: 800))
        let output = ScrollingCaptureRegion.output(selection: selection, matching: wide, scale: 2)
        #expect(output.columns == 0..<600 && output.rows == 600..<800)
        for windows in [[], [CGRect(x: 200, y: 300, width: 30, height: 100), window],
                        [CGRect(x: 200, y: 50, width: 100, height: 100), window]] {
            #expect(ScrollingCaptureRegion.matching(selection: selection, display: display,
                frontToBackWindows: windows) == selection)
        }
    }

    @Test("Scrollbar pixels and changing browser chrome never vote or tear the video", arguments: [false, true])
    func scrollbarAndChrome(narrow: Bool) async throws {
        let video = 100..<220
        func frame(_ offset: Int, _ phase: Int) -> CGImage {
            let base = F.frame(offset, phase: phase, video: video, header: 12, footer: 10)
            var pixels = base.pixels
            for y in 0..<F.height { for x in 44..<48 {
                pixels[y * F.width + x] = F.pixel(x: x, pageY: phase * 301 + y)
            } }
            pixels[3 * F.width + 20] = F.pixel(x: 20, pageY: narrow ? phase : phase < 3 ? 0 : phase)
            return ScrollingCaptureRaster(width: F.width, height: F.height, pixels: pixels)!.image(in: space)!
        }
        let selection = ScrollingCaptureOutputRect(columns: 0..<48, rows: narrow ? 60..<140 : 0..<200)
        let engine = try #require(ScrollingCaptureEngine(firstFrame: frame(0, 0), selection: selection, ignoredTrailingColumns: 4))
        for (step, offset) in stride(from: 20, through: 240, by: 20).enumerated() {
            for phase in 1...2 {
                let update = await engine.add(frame(offset, step * 2 + phase))
                print("SCROLLBAR", offset, phase, update.state, update.engine, update.height)
                #expect(update.state != .lost)
            }
        }
        let image = try #require(await engine.makeImage())
        let output = try #require(ScrollingCaptureRaster(image: image, colorSpace: space))
        try #require(output.height == 240 + selection.rows.count)
        var phases = Set<UInt32>()
        for y in 0..<output.height { for x in 0..<44 {
            let pageY = y + selection.rows.lowerBound
            guard pageY >= 12, pageY < 430 else { continue }
            let pixel = output.pixels[y * F.width + x]
            if video.contains(pageY) { phases.insert((pixel & 0xffffff) - UInt32(x * 107 + pageY * 53)) }
            else { #expect(pixel == F.pixel(x: x, pageY: pageY)) }
        } }
        #expect(phases.count == 1)
        if !narrow {
            for y in 430..<440 { for x in 0..<44 {
                #expect(output.pixels[y * F.width + x] == F.pixel(x: x, pageY: y - 240 + 50_000))
            } }
        }
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

    @Test("Done at a handoff never pastes a changed badge and thin toolbar at the seam")
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
}
