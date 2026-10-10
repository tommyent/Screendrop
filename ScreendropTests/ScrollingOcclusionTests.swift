// Generated pixels only: no captured screens or third-party content.
import CoreGraphics
import Foundation
import ImageIO
import Testing

@Suite struct ScrollingOcclusionTests {
    private typealias F = ScrollingReworkFixture
    private typealias Cover = (rows: Range<Int>, columns: Range<Int>)
    private static let button: Cover = (100..<130, 0..<4)
    private static let video = 8..<40

    /// One view of a generated page at `offset`, with a fixed white cover in
    /// screen cells, page-anchored video and an optional blank left rail.
    private func frame(_ offset: Int, phase: Int = 0, cover: Cover? = button, video: Range<Int>? = nil,
                       rail: Bool = false, dark: Bool = false, coverColor: UInt32 = 0xffffffff) -> ScrollingCaptureRaster {
        var pixels: [UInt32] = []
        for y in 0..<F.height { for x in 0..<F.width {
            pixels.append(cover.map { $0.rows.contains(y) && $0.columns.contains(x) } == true ? coverColor
                : page(offset + y, x, phase: phase, video: video, rail: rail, dark: dark))
        } }
        return ScrollingCaptureRaster(width: F.width, height: F.height, pixels: pixels)!
    }
    private func page(_ pageY: Int, _ x: Int, phase: Int = 0, video: Range<Int>? = nil, rail: Bool = false,
                      dark: Bool = false) -> UInt32 {
        // Short text lines on black: rows through a fixed button match in place across a scroll.
        if dark { return pageY % 10 < 5 && (8..<44).contains(x) ? F.pixel(x: x, pageY: pageY) : 0xff000000 }
        if rail && x < 4 { return 0xff202020 }
        if let video, video.contains(pageY), Self.video.contains(x) { return 0xff000000 | UInt32((phase * 701 + x * 107 + pageY * 53) & 0xffffff) }
        return F.pixel(x: x, pageY: pageY)
    }

    /// Registration then composition, as the engine runs them after hand-over.
    private func compose(_ frames: [ScrollingCaptureRaster]) throws
        -> (ScrollingCaptureBandCompositor, [ScrollingCaptureBandCompositor.Event], [(offset: Int, frame: ScrollingCaptureRaster)]) {
        var buffer = try #require(ScrollingCaptureRegistrationBuffer(first: frames[0], confirmation: frames[0],
            contentRows: 0..<F.height, pageWitnessRows: Set(0..<F.height)))
        var compositor = try #require(ScrollingCaptureBandCompositor(initial: buffer.initial,
            selection: .init(columns: 0..<F.width, rows: 0..<F.height)))
        var events: [ScrollingCaptureBandCompositor.Event] = []
        var placed = [(offset: 0, frame: frames[0])]
        for (index, frame) in frames.enumerated().dropFirst() {
            let registered = buffer.add(frame, at: index, time: Double(index) * 0.05)
            guard !registered.placements.isEmpty else { continue }
            events.append(compositor.add(registered.placements))
            placed += registered.placements.map { ($0.offset, $0.frame) }
        }
        return (compositor, events, placed)
    }

    /// Every output row is one real view of its page row: nothing fabricated from mixed frames.
    private func everyRowIsAView(_ output: ScrollingCaptureRaster, _ placed: [(offset: Int, frame: ScrollingCaptureRaster)]) -> Bool {
        (0..<output.height).allSatisfy { p in
            placed.contains { p - $0.offset >= 0 && p - $0.offset < F.height && $0.frame.row(p - $0.offset).elementsEqual(output.row(p)) }
        }
    }

    @Test("A fixed edge button on a still page: clean page pixels everywhere it scrolled past, the button once")
    func fixedEdgeButton() throws {
        let offsets = [0, 16, 42, 76, 124]
        let (compositor, events, placed) = try compose(offsets.map { frame($0) })
        #expect(events.allSatisfy { $0.state != .lost } && placed.map(\.offset) == offsets)
        #expect(compositor.occlusion?.rows == Self.button.rows && compositor.occlusion?.columns == Self.button.columns)
        let output = try #require(compositor.finish())
        #expect(output.width == F.width && output.height == F.height + 124)
        for p in 0..<output.height {
            let expected = p < 124 ? (0..<F.width).map { page(p, $0) } : Array(frame(124).row(p - 124))
            #expect(output.row(p).elementsEqual(expected), "row \(p)")
        }
        // Only the final view shows it: 30 rows, not one per cut.
        #expect((0..<output.height).filter { p in (0..<4).allSatisfy { output.pixels[p * F.width + $0] == 0xffffffff } }.count == 30)
    }

    @Test("Boundaries keep real single views: no scroll, one displacement, and backscroll before Done",
          arguments: [[0], [0, 16], [0, 16, 42, 76, 30]])
    func boundaries(_ offsets: [Int]) throws {
        let (compositor, _, placed) = try compose(offsets.map { frame($0) })
        let output = try #require(compositor.finish())
        #expect(output.height == F.height + (placed.last?.offset ?? 0))
        #expect(everyRowIsAView(output, placed))
        if offsets == [0] { #expect(output.pixels == frame(0).pixels) }
    }

    @Test("Beside a playing video, the video keeps one complete owner and the button still clears")
    func besideVideo() throws {
        let offsets = [0, 16, 42, 76, 124]
        let (compositor, events, placed) = try compose(offsets.enumerated().map { frame($1, phase: $0, video: 40..<70) })
        #expect(events.allSatisfy { $0.state != .lost })
        #expect(compositor.occlusion != nil)
        let output = try #require(compositor.finish())
        // One source frame supplies every video row: no mixed moments.
        #expect(placed.contains { source in
            (40..<70).allSatisfy { p in p - source.offset >= 0 && p - source.offset < F.height
                && source.frame.row(p - source.offset).elementsEqual(output.row(p)) }
        })
        #expect(everyRowIsAView(output, placed))
    }

    @Test("A cover that moves, grows or lies over real motion is revoked, and nothing is fabricated",
          arguments: ["moves", "grows", "over video"])
    func revoked(_ change: String) throws {
        let late: Cover = change == "moves" ? (110..<140, 0..<4) : change == "grows" ? (100..<130, 0..<6) : Self.button
        let video: Range<Int>? = change == "over video" ? 150..<190 : nil
        let frames = [0, 16, 42].enumerated().map { frame($1, phase: $0, video: video) }
            + [76, 124].enumerated().map { frame($1, phase: $0 + 3, cover: late, video: video) }
        let (compositor, _, placed) = try compose(frames)
        #expect(compositor.occlusion == nil)
        let output = try #require(compositor.finish())
        #expect(everyRowIsAView(output, placed))
    }

    @Test("A covered row that leaves the view with only one clean view breaks instead of guessing")
    func onlyOneCleanView() throws {
        let (compositor, events, placed) = try compose([0, 16, 42, 140].map { frame($0) })
        #expect(events.last?.state == .lost && events.last?.failure == .missingCoverage)
        // Done keeps the last coherent output.
        let output = try #require(compositor.finish())
        #expect(everyRowIsAView(output, placed.filter { $0.offset != 140 }))
    }

    @Test("A blank rail that matches the page proves no cover and changes nothing")
    func blankRail() throws {
        let offsets = [0, 16, 42, 76, 124]
        let (compositor, _, _) = try compose(offsets.map { frame($0, cover: nil, rail: true) })
        #expect(compositor.occlusion == nil)
        let output = try #require(compositor.finish())
        #expect((0..<output.height).allSatisfy { p in output.row(p).elementsEqual((0..<F.width).map { page(p, $0, rail: true) }) })
    }

    /// Rows whose left cells are all the cover's white.
    private func buttonRows(_ output: ScrollingCaptureRaster) -> Int {
        (0..<output.height).filter { p in (0..<4).allSatisfy { output.pixels[p * F.width + $0] == 0xffffffff } }.count
    }

    @Test("On a dark page the button's rows match in place: the first scroll waits for proof instead of failing")
    func darkPage() throws {
        let offsets = [0, 16, 42, 76, 124]
        let (compositor, events, placed) = try compose(offsets.map { frame($0, dark: true) })
        #expect(events.allSatisfy { $0.state != .lost })
        #expect(placed.map(\.offset) == offsets)
        #expect(compositor.occlusion?.rows == Self.button.rows && compositor.occlusion?.columns == Self.button.columns)
        let output = try #require(compositor.finish())
        #expect(output.width == F.width && output.height == F.height + 124)
        for p in 0..<output.height {
            let expected = p < 124 ? (0..<F.width).map { page(p, $0, dark: true) } : Array(frame(124, dark: true).row(p - 124))
            #expect(output.row(p).elementsEqual(expected), "row \(p)")
        }
        #expect(buttonRows(output) == 30)
    }

    @Test("Done after only the first scroll of a dark page saves real views and the button once")
    func darkPageFirstDisplacement() throws {
        let (compositor, events, placed) = try compose([0, 16].map { frame($0, dark: true) })
        #expect(events.allSatisfy { $0.state != .lost } && placed.count == 2)
        let output = try #require(compositor.finish())
        #expect(output.height == F.height + 16 && everyRowIsAView(output, placed))
        #expect(buttonRows(output) == 30)
    }

    @Test("Waiting for proof never locks a band: a top-edge cover after a large step still fails")
    func darkPageTopEdge() throws {
        let top: Cover = (0..<20, 0..<4)
        let (compositor, events, _) = try compose([0, 24, 50].map { frame($0, cover: top, dark: true) })
        #expect(events.first?.failure == .pinnedOverlay)
        let output = try #require(compositor.finish())
        #expect(output.pixels == frame(0, cover: top, dark: true).pixels)
    }

    /// "small steps" discloses a conservative refusal: under a cover taller than the
    /// steps, no cell disagrees in four pairs, so nothing is proved.
    @Test("A pinned element that never proves to be a cover still fails, keeping the earlier output",
          arguments: ["changes", "mid-row", "small steps"])
    func darkPageNoProof(_ kind: String) throws {
        let cover: Cover = kind == "mid-row" ? (100..<130, 20..<24) : Self.button
        let frames = kind == "small steps" ? [0, 10, 20].map { frame($0, dark: true) }
            : [0, 16].map { frame($0, cover: cover, dark: true) }
                + (kind == "changes" ? [frame(42, dark: true, coverColor: 0xff808080)] : [])
        let (compositor, events, placed) = try compose(frames)
        #expect(events.last?.state == .lost && events.last?.failure == .pinnedOverlay)
        #expect(compositor.occlusion == nil)
        let earlier = try compose(Array(frames.prefix(kind == "mid-row" ? 1 : 2))).0
        let output = try #require(compositor.finish())
        #expect(output.pixels == earlier.finish()?.pixels)
        #expect(placed.count == frames.count)
    }

    @Test("Placements that repeat an offset are not another displacement")
    func darkPageRepeatedOffset() throws {
        let placements = [0, 16, 16, 42].enumerated().map { index, offset in
            ScrollingCapturePlacement(index: index, offset: offset, frame: frame(offset, dark: true),
                stableRows: Set(0..<F.height), motionRows: [], contentRows: 0..<F.height)
        }
        var compositor = try #require(ScrollingCaptureBandCompositor(initial: placements[0],
            selection: .init(columns: 0..<F.width, rows: 0..<F.height)))
        for placement in placements.dropFirst() {
            let event = compositor.add(placement)
            #expect(event.state != .lost, "placement \(placement.index): \(String(describing: event.failure))")
        }
        #expect(compositor.occlusion?.rows == Self.button.rows)
    }

    @Test("Rendered dark page with a fixed edge button: one button, never lost",
          .enabled(if: ProcessInfo.processInfo.environment["SUKUSHO_SCROLL_DARK_FRAMES"] != nil))
    func renderedDarkPage() async throws {
        // WebKit renders of checks/occlusion-page.html at 2644x1802, kept outside git.
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SUKUSHO_SCROLL_DARK_FRAMES"]))
        func image(_ offset: Int) throws -> CGImage {
            let url = folder.appendingPathComponent(String(format: "frame-%05d.png", offset))
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)?.cropping(to: CGRect(x: 0, y: 0, width: 1482, height: 1802)))
        }
        let selection = ScrollingCaptureOutputRect(columns: 0..<1482, rows: 180..<1626)
        let engine = try #require(ScrollingCaptureEngine(firstFrame: try image(0), selection: selection,
            ignoredTrailingColumns: 40, traceDirectory: nil))
        var time = 0.0
        for _ in 0..<2 { time += 0.05; _ = await engine.add(try image(0), at: time) }
        while time < 1 { time += 0.05; _ = await engine.noteIdle(at: time) }
        for step in 1...12 {
            time += 0.05
            let update = await engine.add(try image(step * 90), at: time)
            #expect(update.state != .lost, "lost at \(step * 90)pt")
            for _ in 0..<10 { time += 0.05; _ = await engine.noteIdle(at: time) }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(await engine.makeImage())
        let output = try #require(ScrollingCaptureRaster(image: image, colorSpace: space))
        #expect(output.height == selection.rows.count + 12 * 180)
        // The half-circle (56 pt tall, 112 px) sits on the left edge: its white rows form one run.
        let white = (0..<output.height).filter { output.pixels[$0 * output.width] & 0xffffff == 0xffffff }
        #expect(!white.isEmpty && white.count <= 112 && white.last! - white.first! == white.count - 1, "\(white.count) rows from \(white.first ?? -1) to \(white.last ?? -1)")
    }

    @Test("Private user-2347 trace passes the fixed button with clean page pixels",
          .enabled(if: ProcessInfo.processInfo.environment["SUKUSHO_SCROLL_HANDOFF_TRACE"] != nil))
    func externalFixedButton() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SUKUSHO_SCROLL_HANDOFF_TRACE"])
        let document = try ScrollingCaptureTrace.read(URL(fileURLWithPath: path))
        let space = document.colorProfile.flatMap { CGColorSpace(iccData: $0 as CFData) } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let first = try document.first.decoded()
        let engine = try #require(ScrollingCaptureEngine(firstFrame: first.image(in: space)!,
            selection: .init(columns: document.selectionColumns, rows: document.selectionRows),
            ignoredTrailingColumns: document.ignoredTrailingColumns, maximumHeight: document.maximumHeight,
            traceDirectory: nil))
        var placed = [(offset: 0, frame: first)]
        for record in document.records {
            let frame = try record.input.decoded()
            let update = await engine.add(frame.image(in: space)!, at: record.time)
            #expect(update.state != .lost, "lost at \(record.index)")
            if update.state == .appended { placed.append((update.height - document.selectionRows.count, frame)) }
        }
        let image = try #require(await engine.makeImage())
        let output = try #require(ScrollingCaptureRaster(image: image, colorSpace: space))
        // Each row must equal its newest view in the top 600 rows of a frame, well above the
        // button in this trace, or the final view itself: covered cells were really replaced.
        let last = try #require(placed.last), columns = document.selectionColumns
        for p in 0..<output.height {
            let source = p >= last.offset + 600 ? last : try #require(placed.last { (0..<600).contains(p - $0.offset) })
            #expect(output.row(p).elementsEqual(source.frame.row(p - source.offset).dropFirst(columns.lowerBound).prefix(columns.count)),
                    "row \(p)")
        }
    }
}
