import CoreGraphics
import Foundation
import Testing

@Suite struct ScrollingBandsTests {
    private typealias F = ScrollingReworkFixture
    private let selection = ScrollingCaptureOutputRect(columns: 4..<44, rows: 60..<140)

    @Test("Changed recovery chrome narrows new owners and preserves Done on incomplete video")
    func narrowedOwners() throws {
        let video = 100..<220
        var output = try #require(ScrollingCaptureBandCompositor(initial: F.placement(0, index: 0, video: video), selection: selection))
        for (index, offset) in [20, 40].enumerated() {
            #expect(output.add(F.placement(offset, index: index + 1, phase: index + 2, video: video)).state != .lost)
        }
        let before = try #require(output.finish())
        output.narrowOwnerSourcingToSelection()
        let result = output.add(F.placement(60, index: 3, phase: 4, video: video))
        #expect(result.state == .lost && result.failure == .noCompleteOwner)
        #expect(output.finish() == before)
    }

    @Test("A whole video has one source frame; every static/output pixel and trim is exact")
    func wholeVideo() throws {
        let video = 100..<220
        var registration = try #require(ScrollingCaptureRegistrationBuffer(
            first: F.frame(0, phase: 0, video: video), confirmation: F.frame(0, phase: 1, video: video),
            contentRows: 0..<F.height))
        var output = try #require(ScrollingCaptureBandCompositor(initial: registration.initial, selection: selection))
        var sources = [0: registration.initial]
        var previousHeight = 0
        for (step, offset) in stride(from: 20, through: 240, by: 20).enumerated() {
            _ = registration.add(F.frame(offset, phase: step * 2 + 2, video: video), at: step * 2 + 1)
            let event = registration.add(F.frame(offset, phase: step * 2 + 3, video: video), at: step * 2 + 2)
            #expect(event.state == .appended)
            for placed in event.placements {
                sources[placed.index] = placed
                #expect(output.add(placed).state != .lost)
            }
            #expect(output.confirmedHeight >= previousHeight)
            #expect(output.confirmedHeight <= (try #require(output.finish())).height)
            previousHeight = output.confirmedHeight
        }
        let image = try #require(output.finish())
        #expect(image.width == 40 && image.height == 320)
        let band = try #require(output.bands.first)
        #expect(output.bands.count == 1 && band.locked)
        let owner = try #require(band.owner)
        let source = try #require(sources[owner.index])
        #expect(source.offset == 80, "owner changed after the band's top exited")
        for y in 0..<image.height { for x in 0..<image.width {
            let pageY = y + selection.rows.lowerBound
            let sourceX = x + selection.columns.lowerBound
            let expected = video.contains(pageY)
                ? source.frame.pixels[(pageY - source.offset) * F.width + sourceX]
                : F.pixel(x: sourceX, pageY: pageY)
            #expect(image.pixels[y * image.width + x] == expected)
        } }
    }

    @Test("Done before any scroll or while an owner is pending returns one coherent selected frame")
    func initialDone() throws {
        let initial = F.placement(0, index: 0, phase: 3, video: 100..<300)
        let output = try #require(ScrollingCaptureBandCompositor(initial: initial, selection: selection))
        let image = try #require(output.finish())
        #expect(output.confirmedHeight == 0 && output.recoveryRows(20) == nil)
        for y in 0..<image.height { for x in 0..<image.width {
            #expect(image.pixels[y * image.width + x]
                == initial.frame.pixels[(y + 60) * F.width + x + 4])
        } }
    }

    @Test("Lookahead never leaks into output; final stop is the selected bottom, including scroll-back")
    func exactCrop() throws {
        let rect = ScrollingCaptureOutputRect(columns: 7..<19, rows: 60..<120)
        var output = try #require(ScrollingCaptureBandCompositor(initial: F.placement(0, index: 0), selection: rect))
        for (index, offset) in [20, 40, 80, 40].enumerated() {
            #expect(output.add(F.placement(offset, index: index + 1)).state != .lost)
        }
        let image = try #require(output.finish())
        #expect(image.width == 12 && image.height == 100)
        for y in 0..<image.height { for x in 0..<image.width {
            #expect(image.pixels[y * image.width + x] == F.pixel(x: x + 7, pageY: y + 60))
        } }
        let recovery = try #require(output.recoveryRows(7))
        #expect(recovery.width == 12 && recovery.height == 7)
        let firstY = 60 + output.confirmedHeight - 7
        #expect(recovery.pixels.first == F.pixel(x: 7, pageY: firstY))
    }

    @Test("Over-tall motion stops transactionally; Done preserves a coherent confirmed prefix/tail")
    func tooTall() throws {
        var output = try #require(ScrollingCaptureBandCompositor(
            initial: F.placement(0, index: 0, video: 100..<440), selection: selection))
        for (index, offset) in [20, 40, 60, 80].enumerated() {
            #expect(output.add(F.placement(offset, index: index + 1, phase: index + 2, video: 100..<440)).state != .lost)
        }
        let before = try #require(output.finish())
        let confirmed = output.confirmedHeight
        let failure = output.add(F.placement(100, index: 5, phase: 9, video: 100..<440))
        #expect(failure.state == .lost && failure.failure == .noCompleteOwner)
        #expect(output.finish() == before && output.confirmedHeight == confirmed)
        #expect(output.lastVerifiedOffset == 80)
        let tail = F.frame(80, phase: 6, video: 100..<440)
        for pageY in 100..<220 {
            #expect(before.row(pageY - 60).elementsEqual(tail.row(pageY - 80).dropFirst(4).prefix(40)))
        }
    }

    @Test("Interior pinned pixels veto ownership instead of tiling down the output")
    func pinned() throws {
        var output = try #require(ScrollingCaptureBandCompositor(
            initial: F.placement(0, index: 0, pinned: 90..<94), selection: selection))
        let before = output.finish()
        let event = output.add(F.placement(20, index: 1, pinned: 90..<94))
        #expect(event.state == .lost && event.failure == .pinnedOverlay)
        #expect(output.finish() == before && output.confirmedHeight == 0)
    }

    @Test("Split animation bands and late controls share the newest complete owner")
    func splitBands() throws {
        func placed(_ offset: Int, index: Int, phase: Int, controls: Bool) -> ScrollingCapturePlacement {
            let base = F.frame(offset)
            var pixels = base.pixels
            let changing = controls ? [110..<116, 150..<156] : [110..<116]
            var motion = Set<Int>()
            for range in changing { for pageY in range where (offset..<(offset + F.height)).contains(pageY) {
                let y = pageY - offset
                motion.insert(y)
                for x in 0..<F.width { pixels[y * F.width + x] = 0xff000000 | UInt32(phase * 1000 + x) }
            } }
            return ScrollingCapturePlacement(index: index, offset: offset,
                frame: ScrollingCaptureRaster(width: F.width, height: F.height, pixels: pixels)!,
                stableRows: Set(0..<F.height).subtracting(motion), motionRows: motion, contentRows: 0..<F.height)
        }
        var output = try #require(ScrollingCaptureBandCompositor(
            initial: placed(0, index: 0, phase: 1, controls: false), selection: selection))
        for (index, offset) in [20, 40, 60, 80, 100, 120, 140].enumerated() {
            #expect(output.add(placed(offset, index: index + 1, phase: index + 2, controls: true)).state != .lost)
        }
        #expect(output.bands.count == 1)
        let owner = try #require(output.bands.first?.owner)
        let source = placed(100, index: 5, phase: 6, controls: true).frame
        #expect(owner.index == 5)
        for pageY in [111, 151] {
            #expect(owner.pixels[(pageY - owner.rows.lowerBound) * 40] == source.pixels[(pageY - 100) * F.width + 4])
        }
    }

    @Test("Lazy pixels settle to the latest complete owner before locking")
    func lazyImage() throws {
        var output = try #require(ScrollingCaptureBandCompositor(
            initial: F.placement(0, index: 0, phase: 0, video: 100..<160), selection: selection))
        for (index, offset) in [20, 40, 60, 80, 100, 120, 140].enumerated() {
            #expect(output.add(F.placement(offset, index: index + 1, phase: min(index + 1, 3), video: 100..<160)).state != .lost)
        }
        let owner = try #require(output.bands.first?.owner)
        let final = try #require(output.finish())
        let loaded = F.frame(80, phase: 4, video: 100..<160)
        #expect(owner.index == 4)
        for y in 100..<160 {
            #expect(final.row(y - 60).elementsEqual(loaded.row(y - 80).dropFirst(4).prefix(40)))
        }
    }

    @Test("Frozen ownership survives eviction of its full matching frame")
    func ownerEviction() throws {
        var output = try #require(ScrollingCaptureBandCompositor(
            initial: F.placement(0, index: 0, video: 100..<160), selection: selection,
            maximumBufferedBytes: F.frame(0).byteCount * 2))
        for (index, offset) in stride(from: 20, through: 400, by: 20).enumerated() {
            #expect(output.add(F.placement(offset, index: index + 1, phase: index + 1, video: 100..<160)).state != .lost)
            #expect(output.bufferedBytes <= output.maximumBufferedBytes)
        }
        #expect(output.bands.first?.locked == true)
        #expect(output.bands.first?.owner?.index == 4)
        #expect(output.finish()?.height == 480)
    }

    @Test("Output cap and invalid geometry preserve the last savable image")
    func caps() throws {
        var output = try #require(ScrollingCaptureBandCompositor(
            initial: F.placement(0, index: 0), selection: selection, maximumOutputRows: 100))
        #expect(output.add(F.placement(20, index: 1)).state != .lost)
        let saved = output.finish()
        #expect(output.add(F.placement(40, index: 2)).failure == .outputLimit)
        #expect(output.finish() == saved)
        #expect(ScrollingCaptureBandCompositor(initial: F.placement(0, index: 0),
            selection: ScrollingCaptureOutputRect(columns: 0..<49, rows: 0..<100)) == nil)
    }

    @Test("Actual R7 slices the video; registered single-owner output uses exactly one moment")
    func r7VideoNegativeControl() async throws {
        func image(_ raster: ScrollingCaptureRaster) -> CGImage {
            let data = raster.pixels.withUnsafeBytes { Data($0) }
            return CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: raster.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let video = 220..<260
        var registration = try #require(ScrollingCaptureRegistrationBuffer(
            first: F.frame(0), confirmation: F.frame(0), contentRows: 0..<F.height))
        var output = try #require(ScrollingCaptureBandCompositor(initial: registration.initial,
            selection: ScrollingCaptureOutputRect(columns: 0..<48, rows: 0..<200)))
        let old = try #require(ScrollingCaptureStitcher(firstFrame: image(F.frame(0)), ignoredTrailingColumns: 0))
        for (step, offset) in stride(from: 20, through: 300, by: 20).enumerated() {
            for i in 0..<2 {
                let frame = F.frame(offset, phase: step * 2 + i + 1, video: video)
                let event = registration.add(frame, at: step * 2 + i + 1)
                for placed in event.placements { #expect(output.add(placed).state != .lost) }
                _ = await old.add(image(frame))
            }
        }
        let new = try #require(output.finish())
        let previous = try #require(await old.makeImage())
        #expect(previous.height == new.height)
        let data = try #require(previous.dataProvider?.data) as Data
        let words = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self) }
        }
        func phases(_ pixels: [UInt32]) -> Set<UInt32> {
            Set(video.map { y in (pixels[y * 48] & 0xffffff) - UInt32(y * 53) })
        }
        #expect(phases(new.pixels).count == 1)
        #expect(phases(words).count > 1, "negative control did not reproduce R7's torn video")
        print("VIDEO PIXEL CONTROL R7 moments", phases(words).count, "new moments", phases(new.pixels).count)
    }
    @Test("Buffered backfill is atomic and cannot extend the final selected stop")
    func bufferedBatch() throws {
        let video = 20..<180
        var registration = try #require(ScrollingCaptureRegistrationBuffer(
            first: F.frame(0, phase: 1, video: video), confirmation: F.frame(0, phase: 2, video: video),
            contentRows: 0..<F.height))
        var output = try #require(ScrollingCaptureBandCompositor(initial: registration.initial, selection: selection))
        _ = registration.add(F.frame(196, phase: 3, video: video), at: 1)
        _ = registration.add(F.frame(196, phase: 4, video: video), at: 2)
        _ = registration.add(F.frame(5, phase: 5, video: video), at: 3)
        let resolved = registration.add(F.frame(5, phase: 6, video: video), at: 4)
        #expect(resolved.placements.map(\.offset) == [196, 5])
        #expect(output.add(resolved.placements).state != .lost)
        let image = try #require(output.finish())
        #expect(image.width == 40 && image.height == 85)
        #expect(output.confirmedHeight <= image.height)
        for y in 0..<image.height { for x in 0..<image.width {
            #expect(image.pixels[y * image.width + x] == registration.initial.frame.pixels[(y + 60) * F.width + x + 4])
        } }
    }
    @Test("Controls appearing outside a locked band cannot silently gain a second owner")
    func lateControlsAfterLock() throws {
        var output = try #require(ScrollingCaptureBandCompositor(
            initial: F.placement(0, index: 0, video: 110..<116), selection: selection))
        for (index, offset) in [20, 40, 60, 80, 100, 120].enumerated() {
            #expect(output.add(F.placement(offset, index: index + 1, phase: index, video: 110..<116)).state != .lost)
        }
        #expect(output.bands.first?.locked == true)
        let before = output.finish()
        let event = output.add(F.placement(140, index: 7, phase: 8, video: 180..<186))
        #expect(event.state == .lost && event.failure == .noCompleteOwner)
        #expect(output.finish() == before)
    }
    @Test("A viewport full of motion still permits Done before the first scroll")
    func fullViewportInitialDone() throws {
        let initial = F.placement(0, index: 0, video: 0..<400)
        let full = ScrollingCaptureOutputRect(columns: 4..<44, rows: 0..<200)
        var output = try #require(ScrollingCaptureBandCompositor(initial: initial, selection: full))
        let before = try #require(output.finish())
        #expect(before.height == 200 && before.width == 40 && output.confirmedHeight == 0)
        #expect(output.add(F.placement(20, index: 1, phase: 2, video: 0..<400)).state == .lost)
        #expect(output.finish() == before)
    }

    @Test("Backscroll above confirmed rows trims Done and forward capture resumes")
    func reversePastConfirmed() throws {
        let rect = ScrollingCaptureOutputRect(columns: 4..<44, rows: 16..<48)
        var output = try #require(ScrollingCaptureBandCompositor(initial: F.placement(0, index: 0), selection: rect))
        for (index, offset) in [20, 40, 60, 40, 20, 5, 80].enumerated() {
            #expect(output.add(F.placement(offset, index: index + 1)).state != .lost)
            let image = try #require(output.finish())
            #expect(image.height == offset + 32 && image.height == output.outputHeight)
            for y in 0..<image.height { for x in 0..<image.width {
                #expect(image.pixels[y * image.width + x] == F.pixel(x: x + 4, pageY: y + 16))
            } }
            if output.confirmedHeight > 0 { #expect(output.recoveryRows(20) != nil) }
        }
        #expect(!output.isLost && output.outputHeight == 112)
    }

    @Test("Selected chrome appears once, while the caption equals Done's complete height")
    func selectedChrome() throws {
        var output = try #require(ScrollingCaptureBandCompositor(
            initial: F.placement(0, index: 0, header: 12, footer: 10),
            selection: ScrollingCaptureOutputRect(columns: 0..<48, rows: 0..<200)))
        #expect(output.outputHeight == 200 && output.confirmedHeight < 200)
        #expect(output.add(F.placement(20, index: 1, header: 12, footer: 10)).state != .lost)
        let image = try #require(output.finish())
        #expect(image.height == 220 && output.outputHeight == 220)
        for y in 0..<image.height {
            let pageY = y < 12 ? y + 50_000 : y >= 210 ? y - 20 + 50_000 : y
            #expect(image.row(y).elementsEqual((0..<48).map { F.pixel(x: $0, pageY: pageY) }))
        }
    }
}
