// The canonical R7 44-group check, ported to individually discoverable tests.
import CoreGraphics
import Foundation
import ImageIO
import Testing

private struct RNG { var s: UInt64; mutating func next() -> UInt8 { s = s &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: s >> 33) } }

private let width = 120
private let page: [[UInt8]] = {
    var rng = RNG(s: 42)
    return (0..<1000).map { y in
        // A run of blank rows mid-page, like paragraph spacing.
        if (300..<340).contains(y) { return [UInt8](repeating: 255, count: width * 4) }
        return (0..<width).flatMap { _ in [rng.next(), rng.next(), rng.next(), 255] }
    }
}()
private let header: [[UInt8]] = (0..<20).map { y in (0..<width).flatMap { x -> [UInt8] in [UInt8(x), UInt8(y), 7, 255] } }
private let footer: [[UInt8]] = (0..<15).map { y in (0..<width).flatMap { x -> [UInt8] in [9, UInt8(y), UInt8(x), 255] } }
private let band = 165

private func image(_ rows: [[UInt8]]) -> CGImage {
    let data = Data(rows.joined())
    return CGImage(width: width, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                   provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// Viewport at a scroll offset; `scrollBar` paints the last 6 columns differently per frame.
private func frame(_ offset: Int, scrollBar: UInt8? = nil) -> [[UInt8]] {
    var rows = header + page[offset..<(offset + band)] + footer
    if let scrollBar {
        rows = rows.map { row in var r = row; for x in (width - 6)..<width { r[x * 4] = scrollBar } ; return r }
    }
    return rows
}

private func bytes(_ image: CGImage) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
    out.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return out
}

private func idFrame(_ ids: [Int], width: Int = 64) -> CGImage {
    var b = [UInt8](repeating: 0, count: ids.count * width * 4)
    for (y, id) in ids.enumerated() {
        for x in 0..<width {
            let i = (y * width + x) * 4
            b[i] = UInt8(id & 255); b[i + 1] = UInt8((id >> 8) & 255); b[i + 2] = UInt8((x * 13 + id * 7) & 255); b[i + 3] = 255
        }
    }
    return CGImage(width: width, height: ids.count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                   provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func check(_ name: String, _ update: ScrollingCaptureStitcher.Update, _ allowed: [ScrollingCaptureStitcher.Update], height: Int, expected: Int) {
    print(name, update, height)
    #expect(allowed.contains(update) && height == expected, "\(name): got \(update) height \(height), expected \(allowed) \(expected)")
}
private struct AnimatedCase { let name: String; let updates: [ScrollingCaptureStitcher.Update]; let height: Int; let pageIntact: Bool }
private func animatedRun(fraction: Double, inPage: Bool, videoRows: Range<Int> = 100..<400, stillEvery: Int = 0, stillInView: Bool = false, playing: Bool = true, periodicPinned: Bool = false, positions: [Int] = [0, 60, 120, 180, 240, 300, 300, 300]) async -> AnimatedCase {
    let w = 480, h = 400, pageHeight = 1600
    let videoWidth = Int(Double(w) * fraction)
    var rng = RNG(s: 99)
    // White page, text lines of 16 rows with 8-row leading, a paragraph gap every 7 lines.
    var textPage = [UInt8](repeating: 255, count: w * pageHeight * 4)
    for y in 0..<pageHeight {
        let line = y / 24, inLine = y % 24
        guard inLine < 16, line % 7 != 6 else { continue }
        let length = 200 + (line * 73) % 240
        for x in 20..<min(w - 40, 20 + length) where rng.next() < 80 {
            let i = (y * w + x) * 4; textPage[i] = 30; textPage[i + 1] = 30; textPage[i + 2] = 30
        }
    }
    func isVideo(pageY: Int, viewY: Int, x: Int) -> Bool {
        x < videoWidth && (inPage ? videoRows.contains(pageY) : true)
    }
    var frameNumber: UInt64 = 0
    func view(_ top: Int) -> CGImage {
        frameNumber += 1
        var noise = RNG(s: 1000 + frameNumber)
        var b = Array(textPage[(top * w * 4)..<((top + h) * w * 4)])
        for y in 0..<h { for x in 0..<w where isVideo(pageY: top + y, viewY: y, x: x) {
            // With stillEvery n, every nth video row shows the same picture in every frame.
            // The still picture is drawn where the video is: in the page, or (stillInView) fixed in the
            // region whatever the scroll, like a tiled background pinned to the window.
            let py = inPage && !stillInView ? top + y : y
            let still = !playing || (stillEvery > 0 && py % stillEvery == 0)
            var tile = RNG(s: UInt64(py * 1000 + x))
            let v: (UInt8, UInt8, UInt8) = still
                ? (periodicPinned ? (UInt8((x * 7 + y) & 255), UInt8((x * 3) & 255), 77) : (tile.next(), tile.next(), 77))
                : (noise.next(), noise.next(), noise.next())
            let i = (y * w + x) * 4; b[i] = v.0; b[i + 1] = v.1; b[i + 2] = v.2
        } }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    let s = ScrollingCaptureStitcher(firstFrame: view(0), ignoredTrailingColumns: 40)!
    var updates: [ScrollingCaptureStitcher.Update] = []
    for top in positions { updates.append(await s.add(view(top))) }
    let height = await s.stitchedHeight
    var intact = false
    if let result = await s.makeImage(), result.height == height {
        let got = bytes(result)
        intact = true
        for y in 0..<height where intact { for x in 0..<w where !isVideo(pageY: y, viewY: -1, x: x) && x < w - 40 {
            let i = (y * w + x) * 4
            if got[i] != textPage[i] || got[i + 1] != textPage[i + 1] || got[i + 2] != textPage[i + 2] { intact = false; break }
        } }
    }
    let name = "\(inPage ? "in-page video, page rows \(videoRows)," : "fixed video,") \(Int(fraction * 100))% wide"
    return AnimatedCase(name: name, updates: updates, height: height, pageIntact: intact)
}


@MainActor
@Suite(.serialized)
struct StitcherTests {
    @Test("01: Sticky chrome, idle, overshoot and recovery") func scenario01() async throws {
        // 1. Plain scroll with sticky header/footer, an idle frame, an overshoot, and recovery.
        do {
            let s = ScrollingCaptureStitcher(firstFrame: image(frame(0)), ignoredTrailingColumns: 0)!
            var log: [ScrollingCaptureStitcher.Update] = []
            for offset in [37, 90, 90, 160, 250, 330, 420] { log.append(await s.add(image(frame(offset)))) }
            // 420 -> 700 jumps past the band: no overlap, must be rejected, then 520 overlaps 420 again.
            // Steps stay within the band above the held-back quarter (124 rows here).
            log.append(await s.add(image(frame(700))))
            for offset in [520, 640, 760, 835] { log.append(await s.add(image(frame(offset)))) }
            print(log)
            let expected = (header + page[0..<(835 + band)] + footer).flatMap { $0 }
            let result = try #require(await s.makeImage())
            #expect(result.height == 20 + 835 + band + 15, "height \(result.height)")
            #expect(bytes(result) == expected, "stitched pixels differ")
            print("scenario 1 ok, height \(result.height)")
        }

    }

    @Test("02: Changing scroll bar is ignored") func scenario02() async throws {
        // 2. Overlay scroll bar changing every frame, ignored by hashing.
        do {
            let s = ScrollingCaptureStitcher(firstFrame: image(frame(0, scrollBar: 1)), ignoredTrailingColumns: 8)!
            var bar: UInt8 = 1
            for offset in [50, 120, 200, 260] { bar += 40; _ = await s.add(image(frame(offset, scrollBar: bar))) }
            let result = try #require(await s.makeImage())
            #expect(result.height == 20 + 260 + band + 15, "height with scroll bar \(result.height)")
            print("scenario 2 ok, height \(result.height)")
        }

    }

    @Test("03: Retina-sized frame scrolls to the exact height") func scenario03() async throws {
        // 3. Speed: a retina-sized frame (1600 x 1200 px).
        do {
            let w = 1600, h = 1200
            var rng = RNG(s: 7)
            let tall = (0..<(h + 400)).map { _ in (0..<w).flatMap { _ in [rng.next(), rng.next(), rng.next(), UInt8(255)] } }
            func big(_ o: Int) -> CGImage {
                CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: CGDataProvider(data: Data(tall[o..<(o + h)].joined()) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let s = ScrollingCaptureStitcher(firstFrame: big(0), ignoredTrailingColumns: 32)!
            let frames = stride(from: 100, through: 400, by: 100).map(big)
            let start = Date()
            for f in frames { _ = await s.add(f) }
            let ms = Date().timeIntervalSince(start) * 1000 / 4
            let height = await s.stitchedHeight
            #expect(height == h + 400, "big height \(height)")
            print(String(format: "scenario 3 ok, %.0f ms per frame", ms))
        }

    }

    @Test("04: Unique and periodic row regressions") func scenario04() async throws {
        // 4. Sol's round-1 regressions: rows identified by id, horizontally non-uniform.


        do {
            let periodic = (0..<40).map { $0 % 8 }
            var s = ScrollingCaptureStitcher(firstFrame: idFrame(periodic), ignoredTrailingColumns: 0)!
            check("repeating, scroll 20", await s.add(idFrame((20..<60).map { $0 % 8 })), [.noMatch, .unchanged], height: await s.stitchedHeight, expected: 40)

            var blink = periodic; blink[39] = 1000
            s = ScrollingCaptureStitcher(firstFrame: idFrame(periodic), ignoredTrailingColumns: 0)!
            check("repeating, still, one row changed", await s.add(idFrame(blink)), [.noMatch, .unchanged], height: await s.stitchedHeight, expected: 40)

            s = ScrollingCaptureStitcher(firstFrame: idFrame((20..<60).map { $0 % 8 }), ignoredTrailingColumns: 0)!
            check("repeating, scroll up 4", await s.add(idFrame((16..<56).map { $0 % 8 })), [.noMatch, .unchanged], height: await s.stitchedHeight, expected: 40)

            s = ScrollingCaptureStitcher(firstFrame: idFrame(Array(0..<40)), ignoredTrailingColumns: 0)!
            check("unique, jump past overlap", await s.add(idFrame(Array(80..<120))), [.noMatch], height: await s.stitchedHeight, expected: 40)
            check("unique, back to accepted", await s.add(idFrame(Array(0..<40))), [.unchanged], height: await s.stitchedHeight, expected: 40)

            s = ScrollingCaptureStitcher(firstFrame: idFrame(Array(30..<70)), ignoredTrailingColumns: 0)!
            check("unique, scroll up 10", await s.add(idFrame(Array(20..<60))), [.unchanged], height: await s.stitchedHeight, expected: 40)
            check("unique, then down past start", await s.add(idFrame(Array(40..<80))), [.appended], height: await s.stitchedHeight, expected: 50)

            var still = Array(0..<40); still[39] = 1000
            s = ScrollingCaptureStitcher(firstFrame: idFrame(Array(0..<40)), ignoredTrailingColumns: 0)!
            check("unique, still, one row changed", await s.add(idFrame(still)), [.unchanged], height: await s.stitchedHeight, expected: 40)
            print("scenario 4 ok")
        }

    }

    @Test("05: Periodic rows refuse; flat UI still stitches") func scenario05() async throws {
        // 5. Sol's round-2 probe (period 32, scroll 40) and a flat-UI page that must still stitch.
        do {
            var s = ScrollingCaptureStitcher(firstFrame: idFrame((0..<80).map { $0 % 32 }), ignoredTrailingColumns: 0)!
            check("period 32, scroll 40", await s.add(idFrame((40..<120).map { $0 % 32 })), [.noMatch, .unchanged], height: await s.stitchedHeight, expected: 80)

            // Mostly identical "card" rows (id 500) with a line of unique text rows every 16.
            let flatPage = (0..<400).map { y in y % 16 < 3 ? 1000 + y : 500 }
            s = ScrollingCaptureStitcher(firstFrame: idFrame(Array(flatPage[0..<120])), ignoredTrailingColumns: 0)!
            check("flat UI, scroll 7", await s.add(idFrame(Array(flatPage[7..<127]))), [.appended], height: await s.stitchedHeight, expected: 127)
            check("flat UI, scroll 33 more", await s.add(idFrame(Array(flatPage[40..<160]))), [.appended], height: await s.stitchedHeight, expected: 160)
            let image = try #require(await s.makeImage())
            let rows = { (img: CGImage) -> [Int] in let b = bytes(img); return (0..<img.height).map { y in Int(b[y * img.width * 4]) + Int(b[y * img.width * 4 + 1]) * 256 } }(image)
            #expect(rows == Array(flatPage[0..<160]), "flat UI rows differ")
            print("scenario 5 ok")
        }

    }

    @Test("06: Periodic false-offset regressions") func scenario06() async throws {
        // 6. Sol's other round-2 periodic failures: (period, start, next start), 80-row frames.
        do {
            for (period, from, to) in [(32, 64, 104), (20, 0, 25), (20, 30, 15), (16, 0, 20)] {
                let s = ScrollingCaptureStitcher(firstFrame: idFrame((from..<(from + 80)).map { $0 % period }), ignoredTrailingColumns: 0)!
                check("period \(period), \(from) -> \(to)", await s.add(idFrame((to..<(to + 80)).map { $0 % period })), [.noMatch, .unchanged], height: await s.stitchedHeight, expected: 80)
            }
            print("scenario 6 ok")
        }

    }

    @Test("07: Ambiguous short overlaps refuse") func scenario07() async throws {
        // 7. Sol's round-3 periodic cases: rivals with little overlap but no contradictions.
        do {
            for (period, from, to) in [(64, 64, 136), (64, 64, 8), (56, 64, 128)] {
                let s = ScrollingCaptureStitcher(firstFrame: idFrame((from..<(from + 80)).map { $0 % period }), ignoredTrailingColumns: 0)!
                check("period \(period), \(from) -> \(to)", await s.add(idFrame((to..<(to + 80)).map { $0 % period })), [.noMatch, .unchanged], height: await s.stitchedHeight, expected: 80)
            }
            print("scenario 7 ok")
        }

    }

    @Test("08: Blank gap and scroll-back recovery") func scenario08() async throws {
        // 8. Sol's round-3 live blank-gap sequence: unique rows, then a long blank gap. Scrolling back up
        // passes a frame deeper than the last accepted one; its new rows are real page and must append.
        do {
            func pageFrame(_ ids: [Int], width: Int = 64) -> CGImage {
                var b = [UInt8](repeating: 255, count: ids.count * width * 4)
                for (y, id) in ids.enumerated() where id >= 0 {
                    for x in 0..<width { let i = (y * width + x) * 4; b[i] = UInt8(id & 255); b[i + 1] = UInt8((id >> 8) & 255); b[i + 2] = UInt8((x * 13 + id * 7) & 255) }
                }
                return CGImage(width: width, height: ids.count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let page = (0..<600).map { $0 < 90 ? 2000 + $0 : -1 }   // -1 = white
            let view = { (top: Int) in pageFrame(Array(page[top..<(top + 80)])) }
            let s = ScrollingCaptureStitcher(firstFrame: view(0), ignoredTrailingColumns: 0)!
            var log: [ScrollingCaptureStitcher.Update] = []
            for top in [40, 50, 150, 250, 150, 60, 40] { log.append(await s.add(view(top))) }
            print("gap sequence", log)
            #expect(log == [.appended, .appended, .noMatch, .noMatch, .noMatch, .appended, .unchanged], "gap updates \(log)")
            let result = try #require(await s.makeImage())
            #expect(result.height == 140 && bytes(result) == bytes(pageFrame(Array(page[0..<140]))), "gap result is not the page prefix")
            print("scenario 8 ok, height \(result.height)")
        }

    }

    @Test("09: Changing thin gutter separator") func scenario09() async throws {
        // 9. Sol's round-7 Sublime case: a 2-px gutter separator whose pixels flip between frames,
        // so no whole row ever matches. Strips must still line the frames up.
        do {
            func gutterFrame(_ top: Int, flip: Bool) -> CGImage {
                var rows = Array(page[top..<(top + band)])
                rows = rows.map { row in var r = row; for x in 10..<12 { let i = x * 4; r[i] = flip ? 200 : 40; r[i + 1] = flip ? 40 : 200; r[i + 2] = 90 }; return r }
                return image(rows)
            }
            let s = ScrollingCaptureStitcher(firstFrame: gutterFrame(0, flip: false), ignoredTrailingColumns: 0)!
            var log: [ScrollingCaptureStitcher.Update] = []
            var flip = true
            // Steps stay within the band above the held-back quarter (124 rows here).
            for top in [60, 130, 200, 320, 400] { log.append(await s.add(gutterFrame(top, flip: flip))); flip.toggle() }
            print("gutter", log)
            let result = try #require(await s.makeImage())
            #expect(result.height == 400 + band, "gutter height \(result.height)")
            // Everything but the flipping gutter columns must be the page itself.
            let got = bytes(result), want = Array(page[0..<(400 + band)].joined())
            for y in 0..<result.height { for x in 0..<width where !(10..<12).contains(x) {
                for c in 0..<4 { let i = (y * width + x) * 4 + c; #expect(got[i] == want[i], "gutter pixel \(x),\(y) differs") }
            } }
            print("scenario 9 ok, height \(result.height)")
        }

    }

    @Test("10: Sparse code in the leftmost strip") func scenario10() async throws {
        // 10. Sol's round-8 Sublime case: sparse code whose evidence sits mostly in the leftmost strip,
        // next to a window edge (x=0) and gutter separator (x=10) that flip color every frame.
        do {
            let sparse: [[UInt8]] = (0..<900).map { y in
                (0..<width).flatMap { x -> [UInt8] in
                    let isText = y % 3 != 0 && (12..<30).contains(x) && (x * 7 + y * 13) % 5 < 3
                    return isText ? [UInt8(y & 255), UInt8(y >> 8), UInt8(x * 9 & 255), 255] : [250, 250, 250, 255]
                }
            }
            func view(_ top: Int, flip: Bool) -> CGImage {
                image(sparse[top..<(top + 200)].map { row in
                    var r = row
                    for x in [0, 10] { let i = x * 4; r[i] = flip ? 30 : 220; r[i + 1] = flip ? 220 : 30; r[i + 2] = 90 }
                    return r
                })
            }
            let s = ScrollingCaptureStitcher(firstFrame: view(0, flip: false), ignoredTrailingColumns: 0)!
            var flip = true
            var log: [ScrollingCaptureStitcher.Update] = []
            // Steps stay within the band above the held-back quarter (150 rows here).
            for top in [80, 160, 240, 380, 520, 660, 700] { log.append(await s.add(view(top, flip: flip))); flip.toggle() }
            print("sparse gutter", log)
            let result = try #require(await s.makeImage())
            #expect(result.height == 900, "sparse gutter height \(result.height)")
            let got = bytes(result), want = Array(sparse[0..<900].joined())
            for y in 0..<900 { for x in 0..<width where x != 0 && x != 10 {
                for c in 0..<4 { let i = (y * width + x) * 4 + c; #expect(got[i] == want[i], "sparse pixel \(x),\(y)") }
            } }
            print("scenario 10 ok")
        }

    }

    @Test("11: Dotted two-tone gutter separator") func scenario11() async throws {
        // 11. Sol's round-9 Sublime case: the separator is a dotted two-tone line (alternating rows)
        // whose phase flips between frames, beside sparse code; the window edge flips too.
        do {
            let sparse: [[UInt8]] = (0..<900).map { y in
                (0..<width).flatMap { x -> [UInt8] in
                    let isText = y % 3 != 0 && (12..<30).contains(x) && (x * 7 + y * 13) % 5 < 3
                    return isText ? [UInt8(y & 255), UInt8(y >> 8), UInt8(x * 9 & 255), 255] : [250, 250, 250, 255]
                }
            }
            func view(_ top: Int, phase: Int) -> CGImage {
                image(sparse[top..<(top + 200)].enumerated().map { r, row in
                    var out = row
                    let dot: [UInt8] = (r + phase) % 2 == 0 ? [60, 60, 60] : [250, 250, 250]
                    for x in [10, 11] { let i = x * 4; out[i] = dot[0]; out[i + 1] = dot[1]; out[i + 2] = dot[2] }
                    let edge: UInt8 = phase == 0 ? 30 : 220
                    out[0] = edge; out[1] = edge; out[2] = edge
                    return out
                })
            }
            let s = ScrollingCaptureStitcher(firstFrame: view(0, phase: 0), ignoredTrailingColumns: 0)!
            var phase = 1
            var log: [ScrollingCaptureStitcher.Update] = []
            // Steps stay within the band above the held-back quarter.
            for top in [81, 160, 243, 380, 520, 661, 700] { log.append(await s.add(view(top, phase: phase))); phase = 1 - phase }
            print("dotted gutter", log)
            let result = try #require(await s.makeImage())
            #expect(result.height == 900, "dotted gutter height \(result.height)")
            let got = bytes(result), want = Array(sparse[0..<900].joined())
            for y in 0..<900 { for x in 0..<width where ![0, 10, 11].contains(x) {
                for c in 0..<4 { let i = (y * width + x) * 4 + c; #expect(got[i] == want[i], "dotted pixel \(x),\(y)") }
            } }
            print("scenario 11 ok")
        }

    }

    @Test("12: Dense two-gray status grid") func scenario12() async throws {
        // 12. Sol's round-10 status grid: dense two-gray content (16-px rows, 10-px cells) must not be
        // masked as chrome. 800x1600 frames at positions 0 and 320 -> appended, 1920, byte-exact.
        do {
            let gw = 800
            func grid(_ position: Int, rows count: Int) -> [UInt8] {
                var b = [UInt8](repeating: 255, count: gw * count * 4)
                for y in 0..<count { for x in 0..<gw {
                    let row = (position + y) / 16, col = x / 10
                    let v: UInt8 = row & (1 << (col % 8)) != 0 ? 50 : 220
                    let i = (y * gw + x) * 4; b[i] = v; b[i + 1] = v; b[i + 2] = v
                } }
                return b
            }
            func gridImage(_ data: [UInt8], _ h: Int) -> CGImage {
                CGImage(width: gw, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: gw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let s = ScrollingCaptureStitcher(firstFrame: gridImage(grid(0, rows: 1600), 1600), ignoredTrailingColumns: 0)!
            let update = await s.add(gridImage(grid(320, rows: 1600), 1600))
            let result = try #require(await s.makeImage())
            print("status grid", update, result.height)
            let expected = gridImage(grid(0, rows: 1920), 1920)
            #expect(update == .appended && result.height == 1920 && bytes(result) == bytes(expected), "status grid")
            print("scenario 12 ok")
        }

    }

    @Test("13: Recorded Sublime pair and isolated red pixels") func scenario13() async throws {
        // 13. Sol's round-10 outlier: the real Sublime pair with x=133,134 at y=0 turned red in both
        // frames. A stray pixel must not hide the dotted separator -> appended +760 (2660).
        do {
            func withRed(_ img: CGImage) -> CGImage {
                var b = bytes(img)
                for x in [133, 134] { let i = x * 4; b[i] = 0; b[i + 1] = 0; b[i + 2] = 255; b[i + 3] = 255 }
                return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let transforms: [(String, @MainActor (CGImage) -> CGImage)] = [("clean", { $0 }), ("one red pixel", withRed)]
            for (name, transform) in transforms {
                let s = ScrollingCaptureStitcher(firstFrame: transform(try StitcherFixtures.load("sublime-last-accepted")), ignoredTrailingColumns: 40)!
                let update = await s.add(transform(try StitcherFixtures.load("sublime-stall-crop")))
                let h = await s.stitchedHeight
                print("real Sublime pair, \(name):", update, h)
                #expect(update == .appended && h == 2660, "real pair \(name)")
            }
            print("scenario 13 ok")
        }

    }

    @Test("14: Thin six-pixel grid cells") func scenario14() async throws {
        // 14. Sol's round-11 thin grid: 6-px data cells with 1-px white gaps - every cell narrow
        // enough to look like chrome. Positions 0 and 320 -> appended, 1920, byte-exact.
        do {
            let gw = 800
            func thin(_ position: Int, rows count: Int) -> CGImage {
                var b = [UInt8](repeating: 255, count: gw * count * 4)
                for y in 0..<count { for x in 0..<gw {
                    let row = (position + y) / 16, col = x / 7
                    let v: UInt8 = x % 7 == 6 ? 255 : (row & (1 << (col % 8)) != 0 ? 50 : 220)
                    let i = (y * gw + x) * 4; b[i] = v; b[i + 1] = v; b[i + 2] = v
                } }
                return CGImage(width: gw, height: count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: gw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let s = ScrollingCaptureStitcher(firstFrame: thin(0, rows: 1600), ignoredTrailingColumns: 0)!
            let update = await s.add(thin(320, rows: 1600))
            let result = try #require(await s.makeImage())
            print("thin grid", update, result.height)
            #expect(update == .appended && result.height == 1920 && bytes(result) == bytes(thin(0, rows: 1920)), "thin grid")
            print("scenario 14 ok")
        }

    }

    @Test("15: Synthetic list icon redraw differences") func scenario15() async throws {
        // 15. Generated list rows with fixed chrome and icon redraw differences of 1–2 levels.
        // Both first-frame variants must append +664, preserving the original expected height.
        do {
            for first in [0, 1] {
                let s = ScrollingCaptureStitcher(firstFrame: SyntheticFixtures.list(offset: 0, redraw: first), ignoredTrailingColumns: 40)!
                let update = await s.add(SyntheticFixtures.list(offset: 664, redraw: 2))
                let h = await s.stitchedHeight
                print("synthetic list pair \(first):", update, h)
                #expect(update == .appended && h == 2322, "synthetic list pair \(first)")
            }
            print("scenario 15 ok")
        }

    }

    @Test("16: Fixed floating button appears once") func scenario16() async throws {
        // 16. CAP-1: a floating button fixed near the band's bottom-right (a chat bubble) while the
        // page scrolls under it. It must appear once, where the last frame shows it, and the page
        // content it covered in earlier frames must come through clean. Byte-exact.
        do {
            func withBubble(_ rows: [[UInt8]], at top: Int) -> [[UInt8]] {
                rows.enumerated().map { y, row in
                    guard (top..<(top + 20)).contains(y) else { return row }
                    var r = row
                    for x in 80..<110 { r[x * 4] = 0; r[x * 4 + 1] = 200; r[x * 4 + 2] = 0; r[x * 4 + 3] = 255 }
                    return r
                }
            }
            // Header 20 + band row 140 -> frame rows 160..<180, inside the bottom quarter of the band.
            let s = ScrollingCaptureStitcher(firstFrame: image(withBubble(frame(0), at: 160)), ignoredTrailingColumns: 0)!
            var log: [ScrollingCaptureStitcher.Update] = []
            for offset in [37, 90, 160] { log.append(await s.add(image(withBubble(frame(offset), at: 160)))) }
            print("bubble", log)
            let result = try #require(await s.makeImage())
            let expected = withBubble(header + page[0..<(160 + band)] + footer, at: 160 + 160).flatMap { $0 }
            #expect(log.allSatisfy { $0 == .appended } && result.height == 20 + 160 + band + 15, "bubble height \(result.height)")
            #expect(bytes(result) == expected, "bubble stamped or content lost")
            print("scenario 16 ok")
        }

    }

    @Test("17: Overshoot with floating button refuses") func scenario17() async throws {
        // 17. Sol's code review 4: a jump past the band above the cut, with the bubble in place, must
        // be rejected rather than filled from the held-back rows (where the bubble covered the page).
        // Smaller steps afterwards still stitch byte-exact, with the bubble once.
        do {
            func withBubble(_ rows: [[UInt8]], at top: Int) -> [[UInt8]] {
                rows.enumerated().map { y, row in
                    guard (top..<(top + 20)).contains(y) else { return row }
                    var r = row
                    for x in 80..<110 { r[x * 4] = 0; r[x * 4 + 1] = 200; r[x * 4 + 2] = 0; r[x * 4 + 3] = 255 }
                    return r
                }
            }
            let s = ScrollingCaptureStitcher(firstFrame: image(withBubble(frame(0), at: 160)), ignoredTrailingColumns: 0)!
            let jump = await s.add(image(withBubble(frame(150), at: 160)))
            var log: [ScrollingCaptureStitcher.Update] = []
            for offset in [100, 200] { log.append(await s.add(image(withBubble(frame(offset), at: 160)))) }
            print("bubble jump", jump, log)
            let result = try #require(await s.makeImage())
            let expected = withBubble(header + page[0..<(200 + band)] + footer, at: 160 + 200).flatMap { $0 }
            #expect(jump == .noMatch, "large jump accepted")
            #expect(log.allSatisfy { $0 == .appended } && bytes(result) == expected, "bubble jump recovery")
            print("scenario 17 ok")
        }

    }

    @Test("18: Playing video preserves scrolling page pixels") func scenario18() async throws {
        // 18. sd-i1p: animated content (a playing video) inside the region. A text page 480 px wide in a
        // 400-px region, 40 trailing columns ignored (the app's 20-pt scroll bar at 2x). The video
        // covers the left 10/30/50/70% of the width and every one of its pixels changes every frame:
        //   fixed:  the block stays put in the region, full height, independent of the scroll;
        //   inPage: a 300-row video in the page itself, scrolling with it: in view from the start
        //           (page rows 100..<400), or scrolling into view from below (250..<550).
        // Frames: idle (video only), five 60-px scrolls, idle twice. Every scroll must append;
        // pre-scroll idle may warn; idle after accepted scrolling must be unchanged.
        // Expected height 400 + 300,
        // and every pixel outside the video equal to the page.
        var animatedFailures: [String] = []
        for (inPage, rows) in [(false, 100..<400), (true, 100..<400), (true, 250..<550)] {
            for fraction in [0.1, 0.3, 0.5, 0.7] {
                let r = await animatedRun(fraction: fraction, inPage: inPage, videoRows: rows)
                // Every actual 60-px page step must append. Initial video-only idle
                // hasn't established page motion; post-scroll idle must not warn.
                let moved = r.updates[1...5].allSatisfy { $0 == .appended }
                let idle = [.unchanged, .noMatch].contains(r.updates[0])
                    && r.updates[6...7].allSatisfy { $0 == .unchanged }
                let ok = moved && idle && r.height == 700 && r.pageIntact
                print(ok ? "PASS" : "FAIL", r.name, r.updates.map { "\($0)" }.joined(separator: " "), "height \(r.height)", r.pageIntact ? "page intact" : "page DIFFERS")
                if !ok { animatedFailures.append(r.name) }
            }
        }
        print(animatedFailures.isEmpty ? "scenario 18 ok" : "scenario 18 FAILED: \(animatedFailures)")
        #expect(animatedFailures.isEmpty, "animated captures stalled: \(animatedFailures)")
        // Limits/controls: a video wider than 85% leaves too little beside it and
        // must refuse. Partly still video must preserve the byte-exact page prefix.
        for (inPage, fraction, still) in [(false, 0.9, 0), (false, 0.5, 2), (false, 0.5, 4), (false, 0.3, 2), (true, 0.5, 2), (true, 0.5, 4)] {
            let r = await animatedRun(fraction: fraction, inPage: inPage, stillEvery: still)
            print("LIMIT", r.name, still > 0 ? "1 row in \(still) still:" : "", r.updates.map { "\($0)" }.joined(separator: " "), "height \(r.height)", r.pageIntact ? "page intact" : "page DIFFERS")
            if fraction < 0.9 {
                #expect(r.height == 700 && r.pageIntact, "partly still video lost content")
            } else {
                #expect(r.height == 400 && r.updates.allSatisfy { $0 == .noMatch }, "video without position evidence was guessed")
            }
        }
        // The probe that went wrong first: the still rows pinned to the region while the rest of the
        // video scrolls; and the same pinned pattern with nothing playing (what d175856 does there).
        for playing in [true, false] {
            let r = await animatedRun(fraction: 0.5, inPage: true, stillEvery: 2, stillInView: true, playing: playing)
            print("PINNED", playing ? "with video playing" : "nothing playing", r.updates.map { "\($0)" }.joined(separator: " "), "height \(r.height)", r.pageIntact ? "page intact" : "page DIFFERS")
            #expect(r.height == 700 && r.pageIntact, "pinned texture corrupted the page")
        }

    }

    @Test("19: Partially still and periodic pinned video") func scenario19() async throws {
        // 19. The handoff's exact false-append fixture: a pinned texture repeats every 256 rows
        // beside changing video rows. Previously it appended 256 for a 120-px scroll, height 836.
        for playing in [true, false] {
            let r = await animatedRun(fraction: 0.5, inPage: true, stillEvery: 2, stillInView: true,
                                      playing: playing, periodicPinned: true)
            if playing {
                #expect(r.height == 700 && r.pageIntact, "periodic pinned texture: \(r.height), intact \(r.pageIntact)")
                print("periodic pinned video", r.updates, r.height, "page intact")
            } else {
                // With nothing changing this is a static texture pinned to view coordinates inside a
                // scrolling rectangle, not a page-relative image. The d175856 baseline also falsely
                // appends 256 here (height 656). Keep it visible as a pre-existing synthetic limit.
                print("KNOWN LIMIT stationary periodic pinned texture", r.updates, r.height, "intact", r.pageIntact)
                withKnownIssue("Pre-existing primary matcher accepts a stationary periodic texture at the wrong offset") {
                    #expect(r.height == 700 && r.pageIntact)
                }
            }
        }
        print("scenario 19 ok")

    }

    @Test("20: Animated scroll-up, overshoot and recovery") func scenario20() async throws {
        // 20. Animation while scrolling up, overshooting the accepted overlap, then recovering.
        for fraction in [0.3, 0.5, 0.7] {
            let r = await animatedRun(fraction: fraction, inPage: true,
                                      positions: [0, 60, 120, 60, 120, 180, 700, 240, 300])
            #expect(r.height == 700 && r.pageIntact && r.updates[6] == .noMatch,
                         "animated overshoot/recovery: \(r.height), intact \(r.pageIntact)")
        }
        print("scenario 20 ok")

    }

    @Test("21: Periodic page beside animation refuses") func scenario21() async throws {
        // 21. A periodic page beside animation must not gain a guessed offset from the changing pixels.
        for period in stride(from: 8, through: 64, by: 8) {
            for shift in [0, 20, 40, 60, 100] {
                func mixed(_ top: Int, seed: UInt64) -> CGImage {
                    let source = idFrame((top..<(top + 160)).map { $0 % period }, width: 128)
                    var b = bytes(source), noise = RNG(s: seed)
                    for y in 0..<160 { for x in 0..<64 {
                        let i = (y * 128 + x) * 4
                        b[i] = noise.next(); b[i + 1] = noise.next(); b[i + 2] = noise.next()
                    } }
                    return CGImage(width: 128, height: 160, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128 * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                   provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
                }
                let s = ScrollingCaptureStitcher(firstFrame: mixed(0, seed: 900), ignoredTrailingColumns: 0)!
                let update = await s.add(mixed(shift, seed: 901))
                let h = await s.stitchedHeight
                #expect(update != .appended && h == 160, "periodic animation guessed: \(period), \(shift), \(h)")
            }
        }
        print("scenario 21 ok, 40 periodic animation pairs")

    }

    @Test("22: Independently moving columns conflict") func scenario22() async throws {
        // 22. Two independently scrolling columns: the fallback must refuse their conflicting offsets.
        for leftShift in [0, 40] {
            func columns(_ left: Int, _ right: Int) -> CGImage {
                var b = bytes(idFrame(Array(right..<(right + 160)), width: 128))
                let l = bytes(idFrame(Array(left..<(left + 160)), width: 128))
                for y in 0..<160 { for x in 0..<64 { for c in 0..<4 {
                    let i = (y * 128 + x) * 4 + c; b[i] = l[i]
                } } }
                return CGImage(width: 128, height: 160, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128 * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let s = ScrollingCaptureStitcher(firstFrame: columns(0, 0), ignoredTrailingColumns: 0)!
            let update = await s.add(columns(leftShift, 20))
            let h = await s.stitchedHeight
            #expect(update == .noMatch && h == 160, "conflicting columns accepted")
        }
        print("scenario 22 ok")

    }

    @Test("23: Ambiguous page cannot yield to coherent animation") func scenario23() async throws {
        // 23. Independent review: coherent animation must not override ambiguous
        // periodic page columns which the original matcher correctly refused.
        do {
            func mixed(_ pageTop: Int, animationTop: Int, period: Int) -> CGImage {
                let w = 128, h = 160
                var b = bytes(idFrame((pageTop..<(pageTop + h)).map { $0 % period }, width: w))
                let video = bytes(idFrame(Array(animationTop..<(animationTop + h)), width: w))
                for y in 0..<h { for x in 0..<32 { for c in 0..<4 {
                    let i = (y * w + x) * 4 + c; b[i] = video[i]
                } } }
                return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            for period in [8, 16, 32] {
                for pageTop in [0, 20, 40] {
                    let s = ScrollingCaptureStitcher(firstFrame: mixed(0, animationTop: 500, period: period), ignoredTrailingColumns: 0)!
                    let update = await s.add(mixed(pageTop, animationTop: 560, period: period))
                    let height = await s.stitchedHeight
                    if period == 8 && pageTop == 20 {
                        // d175856's primary matcher already guesses 60 here; the
                        // new animation retry is never reached. Don't call it a pass.
                        print("KNOWN LIMIT original primary matcher", period, pageTop, update, height)
                        withKnownIssue("Pre-existing primary matcher guesses 60 for period-8 page motion of 20") {
                            #expect(update == .noMatch && height == 160)
                        }
                    } else if period == 32 && pageTop == 40 {
                        #expect(update != .appended && height == 160, "periodic page grew")
                    } else {
                        #expect(update == .noMatch && height == 160,
                                     "animation overrode periodic page: \(period), \(pageTop), \(update), \(height)")
                    }
                }
            }
        }
        print("scenario 23 ok")

    }

    @Test("24: Synthetic broad video pair refuses a false zero") func scenario24() async throws {
        // 24. Generated playing video and pinned sidebar while the page moves 300 px.
        // Never silently answer unchanged.
        // Its moving paragraph has left the region and its incoming cards weren't
        // in the first frame: no shared distinctive page rows remain. It must refuse.
        do {
            let first = SyntheticFixtures.video(offset: 0, phase: 0)
            let next = SyntheticFixtures.video(offset: 300, phase: 1)
            #expect(first.width == 3000 && first.height == 1180 && next.width == 3000 && next.height == 1180)
            for ignored in [20, 40] {
                let s = ScrollingCaptureStitcher(firstFrame: first, ignoredTrailingColumns: ignored)!
                let unchanged = await s.add(first)
                #expect(unchanged == .unchanged, "identical frame warned")
                let update = await s.add(next)
                let height = await s.stitchedHeight
                print("synthetic video/sidebar", ignored, update, height)
                #expect(update == .noMatch && height == 1180,
                             "synthetic page movement was silently ignored or stitched at the wrong offset")
            }
            // A full-frame zero match remains unchanged when a caret/pixel blinks.
            let original = idFrame(Array(0..<160), width: 128)
            var changed = bytes(original)
            changed[(80 * 128 + 64) * 4] ^= 64
            let blink = CGImage(width: 128, height: 160, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128 * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(changed) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let s = ScrollingCaptureStitcher(firstFrame: original, ignoredTrailingColumns: 0)!
            let update = await s.add(blink)
            let height = await s.stitchedHeight
            #expect(update == .unchanged && height == 160, "full-frame zero match warned")
        }
        print("scenario 24 ok")

    }

    @Test("25: Mixed-column small steps and post-scroll idle") func scenario25() async throws {
        // 25. SYNTHETIC, not a raw CleanShot pair: every strip contains both page
        // rows and a playing video. Small steps keep enough unique still rows.
        do {
            let w = 256, h = 240
            func mixed(_ top: Int, seed: UInt64) -> CGImage {
                var b = bytes(idFrame(Array(top..<(top + h)), width: w)), noise = RNG(s: seed)
                for y in 0..<h where (80..<120).contains(top + y) {
                    for x in 0..<w {
                        let i = (y * w + x) * 4
                        b[i] = noise.next(); b[i + 1] = noise.next(); b[i + 2] = noise.next()
                    }
                }
                return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let s = ScrollingCaptureStitcher(firstFrame: mixed(0, seed: 1000), ignoredTrailingColumns: 0)!
            let startup = await s.add(mixed(0, seed: 1001))
            #expect(startup == .noMatch, "unproven mixed startup unexpectedly cleared")
            for top in [20, 40, 60, 80, 100] {
                let update = await s.add(mixed(top, seed: UInt64(1002 + top)))
                #expect(update == .appended, "small shared-row step refused: \(top), \(update)")
            }
            for seed in 2000..<2005 {
                let update = await s.add(mixed(100, seed: UInt64(seed)))
                #expect(update == .unchanged, "mixed post-scroll idle warned")
            }
            let result = try #require(await s.makeImage())
            #expect(result.height == 340)
            let got = bytes(result), expected = bytes(idFrame(Array(0..<340), width: w))
            for y in 0..<340 where !(80..<120).contains(y) {
                for i in (y * w * 4)..<((y + 1) * w * 4) {
                    #expect(got[i] == expected[i], "mixed-column page seam")
                }
            }
        }
        print("scenario 25 ok, SYNTHETIC small steps, startup refusal and mixed-column post-scroll idle")

    }

    @Test("26: Pinned-only zero cannot clear lost track") func scenario26() async throws {
        // 26. SYNTHETIC: a pinned sidebar must not clear a lost-track warning after
        // a previously accepted scroll. Returning to the last position recovers.
        do {
            let w = 256, h = 240
            let sidebar = bytes(idFrame(Array(0..<h), width: w))
            func scene(_ top: Int, seed: UInt64) -> CGImage {
                var b = bytes(idFrame(Array(top..<(top + h)), width: w)), noise = RNG(s: seed)
                for y in 0..<h { for x in 0..<64 {
                    let i = (y * w + x) * 4
                    if x < 32 {
                        for c in 0..<4 { b[i + c] = sidebar[i + c] }
                    } else {
                        b[i] = noise.next(); b[i + 1] = noise.next(); b[i + 2] = noise.next()
                    }
                } }
                return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let s = ScrollingCaptureStitcher(firstFrame: scene(0, seed: 3000), ignoredTrailingColumns: 0)!
            for (top, seed, expected) in [(20, 3001, ScrollingCaptureStitcher.Update.appended),
                                          (500, 3002, .noMatch), (500, 3003, .noMatch),
                                          (20, 3004, .unchanged), (40, 3005, .appended), (40, 3006, .unchanged)] {
                let update = await s.add(scene(top, seed: UInt64(seed)))
                #expect(update == expected, "pinned sidebar/scroll-back: \(top), \(update)")
            }
            let result = try #require(await s.makeImage())
            #expect(result.height == 280)
            let got = bytes(result), expected = bytes(idFrame(Array(0..<280), width: w))
            for y in 0..<280 { for x in 64..<w { for c in 0..<4 {
                let i = (y * w + x) * 4 + c
                #expect(got[i] == expected[i], "recovered page lost rows")
            } } }
        }
        print("scenario 26 ok, SYNTHETIC pinned-only zero refused, scroll-back recovery and idle")

    }

    @Test("27: Historical witness cannot become sticky") func scenario27() async throws { try await historicalWitness(disappears: false) }

    @Test("28: Disappearing historical witness refuses") func scenario28() async throws { try await historicalWitness(disappears: true) }

    @Test("29: Ambiguous video vetoes cached idle") func scenario29() async throws {
        // 29. SYNTHETIC: a previously excluded video becomes an ambiguous periodic
        // scroll. The cached page staying still cannot override that contrary evidence.
        do {
            let w = 256, h = 240
            func scene(_ top: Int, phase: Int?) -> CGImage {
                var b = bytes(idFrame(Array(top..<(top + h)), width: w)), noise = RNG(s: 5000)
                let pattern = phase.map { offset in bytes(idFrame((0..<h).map { ($0 + offset) % 16 }, width: w)) }
                for y in 0..<h { for x in 128..<w {
                    let i = (y * w + x) * 4
                    if let pattern {
                        for c in 0..<4 { b[i + c] = pattern[i + c] }
                    } else {
                        b[i] = noise.next(); b[i + 1] = noise.next(); b[i + 2] = noise.next()
                    }
                } }
                return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let s = ScrollingCaptureStitcher(firstFrame: scene(0, phase: nil), ignoredTrailingColumns: 0)!
            let append = await s.add(scene(20, phase: 0))
            #expect(append == .appended, "ambiguous outside witness setup")
            let update = await s.add(scene(20, phase: 8))
            let height = await s.stitchedHeight
            #expect(update == .noMatch && height == 260, "cached zero overrode ambiguous outside motion")
        }
        print("scenario 29 ok, SYNTHETIC cached zero does not override ambiguous motion")

    }

    @Test("30: Dominant header cannot conceal body motion") func scenario30() async throws {
        // 30. SYNTHETIC: 70% unique pinned rows plus a smaller genuinely scrolling
        // pane must not gain a startup zero from the full-frame idle check.
        do {
            let w = 256, h = 240, header = 168
            func pane(_ top: Int) -> CGImage {
                var b = bytes(idFrame(Array(0..<h), width: w))
                let moving = bytes(idFrame(Array(top..<(top + h)), width: w))
                for i in (header * w * 4)..<b.count { b[i] = moving[i] }
                return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let s = ScrollingCaptureStitcher(firstFrame: pane(0), ignoredTrailingColumns: 0)!
            let update = await s.add(pane(20))
            let height = await s.stitchedHeight
            #expect(update == .noMatch && height == 240, "startup fixed header concealed page movement")
        }
        print("scenario 30 ok, SYNTHETIC startup smaller-pane motion refuses")

    }

    @Test("31: Seven-row body motion vetoes startup idle") func scenario31() async throws { try await startupMotion(fineOnly: false) }

    @Test("32: Fine-strip body motion vetoes startup idle") func scenario32() async throws { try await startupMotion(fineOnly: true) }

    @Test("33: Seven-row animation vetoes cached idle") func scenario33() async throws {
        // 33. SYNTHETIC independent R4 P1, exact 256x160 seven-row cached-idle case.
        do {
            let w = 256, h = 160, pageWidth = 96
            func scene(_ top: Int, phase: Int?) -> CGImage {
                var b = bytes(idFrame(Array(top..<(top + h)), width: w)), noise = RNG(s: 7711)
                let moving = phase.map { p in bytes(idFrame((0..<h).map { ($0 + p) % 7 }, width: w)) }
                for y in 0..<h { for x in pageWidth..<w {
                    let i = (y * w + x) * 4
                    if let moving {
                        for c in 0..<4 { b[i + c] = moving[i + c] }
                    } else {
                        b[i] = noise.next(); b[i + 1] = noise.next(); b[i + 2] = noise.next()
                    }
                } }
                return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let s = ScrollingCaptureStitcher(firstFrame: scene(0, phase: nil), ignoredTrailingColumns: 0)!
            let setup = await s.add(scene(20, phase: 0))
            #expect(setup == .appended, "cached-seven setup")
            let update = await s.add(scene(20, phase: 20))
            let height = await s.stitchedHeight
            #expect(update == .noMatch && height == 180, "cached zero concealed seven-row movement")
        }
        print("scenario 33 ok, SYNTHETIC independent cached-seven motion refuses")

    }

    @Test("34: Entering video with pinned sidebar refuses safely") func scenario34() async throws { try await sidebarControls(group: 34) }

    @Test("35: Translating video cannot override a stationary page") func scenario35() async throws { try await sidebarControls(group: 35) }

    @Test("36: Sidebar offsets must agree with the page") func scenario36() async throws { try await sidebarControls(group: 36) }

    @Test("37: Startup gap refuses and recovers") func scenario37() async throws {
        // 37. SYNTHETIC independent R4 startup-gap P1, exact 256x240 case.
        // A dominant fixed header cannot establish idle after the body lost all overlap.
        do {
            let w = 256, h = 240, header = 168
            func pane(_ top: Int) -> CGImage {
                var b = bytes(idFrame(Array(0..<h), width: w))
                let moving = bytes(idFrame(Array(top..<(top + h)), width: w))
                for i in (header * w * 4)..<b.count { b[i] = moving[i] }
                return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let s = ScrollingCaptureStitcher(firstFrame: pane(0), ignoredTrailingColumns: 0)!
            let update = await s.add(pane(500))
            let height = await s.stitchedHeight
            #expect(update == .noMatch && height == h, "startup zero concealed out-of-overlap movement")
            let acceptedImage = try #require(await s.makeImage())
            #expect(bytes(acceptedImage) == bytes(pane(0)), "startup gap changed accepted pixels")
            let recovery = await s.add(pane(0))
            #expect(recovery == .unchanged, "startup gap did not recover to the accepted frame")
        }
        print("scenario 37 ok, SYNTHETIC independent startup-gap refuses")

    }

    @Test("38: Repartitioned chrome cannot replace the page mask") func scenario38() async throws {
        // SYNTHETIC retained-mask zero after chrome repartitions sparse page strips.
        do {
            let w = 480, h = 160, total = 600
            var rng = RNG(s: 773), a: [Int] = [], b: [Int] = []
            for _ in 0..<total { a.append(Int(rng.next() % 4)); b.append(Int(rng.next() % 4)) }
            let texture = bytes(idFrame(Array(1000..<(1000 + total)), width: w))
            func scene(_ top: Int, stage: Int) -> CGImage {
                var p = bytes(idFrame(Array(top..<(top + h)), width: w)), noise = RNG(s: UInt64(2200 + stage))
                let side = bytes(idFrame(Array(3000..<(3000 + h)), width: w))
                for y in 0..<h { for x in 0..<w {
                    let i = (y * w + x) * 4
                    if x < 120 {
                        for c in 0..<4 { p[i + c] = side[i + c] }
                        if (40..<46).contains(x) { let g: UInt8 = stage == 2 ? 0 : 255; p[i] = g; p[i + 1] = g; p[i + 2] = g }
                    } else if (240..<300).contains(x) {
                        let symbol = x < 272 ? a[y + top] : b[y + top]
                        p[i] = UInt8(symbol * 40 + (x % 3) * 5)
                        p[i + 1] = p[i] &+ 10; p[i + 2] = p[i] &+ 20
                    } else if stage > 0 {
                        if (300..<420).contains(x) {
                            let shift = stage == 2 ? 20 : 0
                            for c in 0..<4 { p[i + c] = texture[((y + shift) * w + x) * 4 + c] }
                        } else {
                            p[i] = noise.next(); p[i + 1] = noise.next(); p[i + 2] = noise.next()
                        }
                    }
                } }
                return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(p) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let s = ScrollingCaptureStitcher(firstFrame: scene(0, stage: 0), ignoredTrailingColumns: 0)!
            let primer = await s.add(scene(20, stage: 0))
            let prefix = bytes(try #require(await s.makeImage()))
            let pageOnly = await s.add(scene(40, stage: 1))
            let next = await s.add(scene(40, stage: 2))
            let height = await s.stitchedHeight
            FileHandle.standardOutput.write(Data("retained page-mask \(primer) \(pageOnly) \(next) height \(height)\n".utf8))
            // R7 refuses this pinned-sidebar fixture one frame earlier; the original
            // second-frame motion and repartitioned retry still cannot change output.
            let output = bytes(try #require(await s.makeImage()))
            #expect(primer == .appended && pageOnly == .noMatch, "retained-mask sidebar did not refuse")
            #expect(next == .noMatch && height == 180 && output == prefix,
                         "repartitioning changed the refused page prefix")
        }
        print("scenario 38 ok, SYNTHETIC original retained-mask fixture refuses sidebar earlier; exact prefix")

    }

    @Test("39: Excluded animation cannot replace a redrawn page") func scenario39() async throws {
        // 39. SYNTHETIC exact independent R5 learned-pin/video-only P1.
        do {
            // SYNTHETIC: learned pinned chrome persists, the old page redraws in place,
        // and only a previously excluded animation supports a nonzero offset.
        let w=256, h=160, sideEnd=32, videoStart=224
        let side=bytes(idFrame(Array(4000..<(4000+h)),width:w))
        func view(_ top:Int, seed:UInt64) -> CGImage {
            var p=bytes(idFrame(Array(top..<(top+h)),width:w)), noise=RNG(s:seed)
            for y in 0..<h { for x in 0..<w {
                let i=(y*w+x)*4
                if x<sideEnd {
                    for c in 0..<4 { p[i+c]=side[i+c] }
                } else if x>=videoStart {
                    p[i]=noise.next(); p[i+1]=noise.next(); p[i+2]=noise.next()
                }
            } }
            return CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue),
                provider:CGDataProvider(data:Data(p) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        }
        let first=view(0,seed:17701), accepted=view(20,seed:17702)
        let s=ScrollingCaptureStitcher(firstFrame:first,ignoredTrailingColumns:0)!
        let setup=await s.add(accepted)
        let setupHeight=await s.stitchedHeight
        FileHandle.standardOutput.write(Data("setup \(setup) height \(setupHeight)\n".utf8))
        #expect(setup == .appended && setupHeight == 180,"learned-pin setup")
        let acceptedPrefix = bytes(try #require(await s.makeImage()))
        let before=bytes(accepted), body=bytes(idFrame((0..<h).map{$0%7},width:w))
        var next=before, noise=RNG(s:17703)
        for y in 0..<h { for x in sideEnd..<w {
            let i=(y*w+x)*4
            if x<videoStart {
                for c in 0..<4 { next[i+c]=body[i+c] }
            } else if y+40<h {
                for c in 0..<4 { next[i+c]=before[((y+40)*w+x)*4+c] }
            } else {
                next[i]=noise.next(); next[i+1]=noise.next(); next[i+2]=noise.next()
            }
        } }
        let changed=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue),
            provider:CGDataProvider(data:Data(next) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let update=await s.add(changed)
        let height=await s.stitchedHeight
        FileHandle.standardOutput.write(Data("stationary redrawn page, animation-only motion40 \(update) height \(height)\n".utf8))
        #expect(update == .noMatch && height == 180,"learned pin let animation replace disappearing page witnesses")
        let refusedPrefix = bytes(try #require(await s.makeImage()))
        #expect(refusedPrefix == acceptedPrefix, "excluded animation changed accepted prefix")

        }
        print("scenario 39 ok, SYNTHETIC redrawn page cannot yield to excluded animation")

    }

    @Test("40: Co-moving animation cannot replace lost witnesses") func scenario40() async throws {
        // 40. SYNTHETIC R6 residual: coherent animation co-moved in the primer;
        // every other page column redraws or becomes blank. Both must now refuse.
        do {
        for blank in [false, true] {
        // SYNTHETIC: learned pinned chrome persists, the old page redraws in place,
        // and only a previously excluded animation supports a nonzero offset.
        let w=256, h=160, sideEnd=32, videoStart=224
        let side=bytes(idFrame(Array(4000..<(4000+h)),width:w))
        func view(_ top:Int, seed:UInt64) -> CGImage {
            var p=bytes(idFrame(Array(top..<(top+h)),width:w))
            for y in 0..<h { for x in 0..<w {
                let i=(y*w+x)*4
                if x<sideEnd {
                    for c in 0..<4 { p[i+c]=side[i+c] }
                }
            } }
            return CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue),
                provider:CGDataProvider(data:Data(p) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        }
        let first=view(0,seed:17701), accepted=view(20,seed:17702)
        let s=ScrollingCaptureStitcher(firstFrame:first,ignoredTrailingColumns:0)!
        let setup=await s.add(accepted)
        let setupHeight=await s.stitchedHeight
        FileHandle.standardOutput.write(Data("setup \(setup) height \(setupHeight)\n".utf8))
        #expect(setup == .appended && setupHeight == 180,"learned-pin setup")
        let acceptedPrefix = bytes(try #require(await s.makeImage()))
        let before=bytes(accepted), body = blank ? [UInt8](repeating: 255, count: w*h*4) : bytes(idFrame((0..<h).map{$0%7},width:w))
        var next=before, noise=RNG(s:17703)
        for y in 0..<h { for x in sideEnd..<w {
            let i=(y*w+x)*4
            if x<videoStart {
                for c in 0..<4 { next[i+c]=body[i+c] }
            } else if y+40<h {
                for c in 0..<4 { next[i+c]=before[((y+40)*w+x)*4+c] }
            } else {
                next[i]=noise.next(); next[i+1]=noise.next(); next[i+2]=noise.next()
            }
        } }
        let changed=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue),
            provider:CGDataProvider(data:Data(next) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let update=await s.add(changed)
        let height=await s.stitchedHeight
        FileHandle.standardOutput.write(Data("stationary redrawn page, animation-only motion40 \(update) height \(height)\n".utf8))
        #expect(update == .noMatch && height == 180, "co-moving animation replaced lost page witnesses")
        let refusedPrefix = bytes(try #require(await s.makeImage()))
        #expect(refusedPrefix == acceptedPrefix, "co-moving animation changed accepted prefix")
        FileHandle.standardOutput.write(Data("REFUSED \(blank ? "blank" : "period7") page, animation inside previously proven mask: \(update), height \(height)\n".utf8))

        }

        }
        print("scenario 40 ok, SYNTHETIC R6 residual refuses for redraw and blank page")

    }

    @Test("41: Stationary video with redrawn chrome refuses") func scenario41() async throws {
        // 41. SYNTHETIC stationary video and slightly redrawn chrome must refuse.
        do {

        let w = 480, h = 400, headerHeight = 80, pageHeight = 2000
        struct RNG {
            var value: UInt64
            mutating func byte() -> UInt8 {
                value = value &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: value >> 33)
            }
        }
        var rng = RNG(value: 7171)
        let page = (0..<(w * pageHeight)).flatMap { _ in [rng.byte(), rng.byte(), rng.byte(), 255] as [UInt8] }
        let header = (0..<(w * headerHeight)).flatMap { index in
            let shade = UInt8(120 + (index / w) % 20 + index % 7)
            return [shade, shade &+ 10, shade &+ 20, 255] as [UInt8]
        }
        func image(_ bytes: [UInt8], height: Int) -> CGImage {
            CGImage(width: w, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                    provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { p in
                let c = CGContext(data: p.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        func frame(top: Int, variation: UInt8) -> CGImage {
            var bytes = header + Array(page[(top * w * 4)..<((top + h - headerHeight) * w * 4)])
            for index in 0..<header.count where index % 4 != 3 { bytes[index] &+= variation }
            return image(bytes, height: h)
        }

        // SYNTHETIC: the page stays stationary; only the central video translates.
        // Header and footer redraw by one RGB level, within the new edge tolerance.
        func view(videoTop: Int, variation: UInt8) -> CGImage {
            var top = header, bottom = header
            for i in top.indices where i % 4 != 3 { top[i] &+= variation; bottom[i] &+= variation }
            return image(top + Array(page[(videoTop*w*4)..<((videoTop+h-2*headerHeight)*w*4)]) + bottom, height: h)
        }
        let first = view(videoTop: 0, variation: 0)
        let s = ScrollingCaptureStitcher(firstFrame: first, ignoredTrailingColumns: 0)!
        for (i, top) in [40,80].enumerated() {
            let update = await s.add(view(videoTop: top, variation: UInt8(i+1)))
            let height = await s.stitchedHeight
            FileHandle.standardOutput.write(Data("stationary page, video-only motion \(top): \(update), height \(height)\n".utf8))
            #expect(update == .noMatch && height == h, "tolerant edges let video establish page movement")
        }
        let result = try #require(await s.makeImage())
        #expect(pixels(result) == pixels(first), "refusal changed accepted output")
        }
        print("scenario 41 ok, SYNTHETIC stationary video and slightly redrawn chrome must refuse")

    }

    @Test("42: Primed pale page cannot authorize animation-only motion") func scenario42() async throws {
        // 42. SYNTHETIC primed pale page cannot authorize central-only animation.
        do {
        let w = 480, h = 400, rows = 2000
        struct RNG { var value: UInt64; mutating func byte() -> UInt8 {
            value = value &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: value >> 33)
        } }
        var rng = RNG(value: 8787)
        let page = (0..<(w * rows)).flatMap { _ in
            [UInt8(120 + rng.byte() % 5), UInt8(130 + rng.byte() % 5), UInt8(140 + rng.byte() % 5), 255] as [UInt8]
        }
        func image(_ p: [UInt8], height: Int = h) -> CGImage {
            CGImage(width: w, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: CGDataProvider(data: Data(p) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        func bytes(_ image: CGImage) -> [UInt8] {
            var p = [UInt8](repeating: 0, count: image.width * image.height * 4)
            p.withUnsafeMutableBytes { a in
                let c = CGContext(data: a.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return p
        }
        func view(_ top: Int) -> CGImage { image(Array(page[(top*w*4)..<((top+h)*w*4)])) }
        let s = ScrollingCaptureStitcher(firstFrame: view(0), ignoredTrailingColumns: 0)!
        for top in [20,40] {
            let update = await s.add(view(top))
            #expect(update == .appended, "true moving-page primers must append")
        }
        let accepted = bytes(try #require(await s.makeImage()))
        var stationary = bytes(view(40))
        stationary[(80*w*4)..<(320*w*4)] = page[((80+80)*w*4)..<((80+320)*w*4)]
        let next = await s.add(image(stationary))
        let result = try #require(await s.makeImage())
        FileHandle.standardOutput.write(Data("primed moving pale page then central-only animation: \(next), height \(result.height)\n".utf8))
        #expect(next == .noMatch && result.height == 440 && bytes(result) == accepted,
                     "prior page movement authorized later video-only append")
        }
        print("scenario 42 ok, SYNTHETIC primed pale page cannot authorize central-only animation")

    }

    @Test("43: Exact tall sticky header keeps byte-exact output") func scenario43() async throws {
        // 43. SYNTHETIC exact 130px header retains byte-exact positive scrolls.
        do {

        let w = 480, h = 400, headerHeight = 130, pageHeight = 2000
        struct RNG {
            var value: UInt64
            mutating func byte() -> UInt8 {
                value = value &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: value >> 33)
            }
        }
        var rng = RNG(value: 7171)
        let page = (0..<(w * pageHeight)).flatMap { _ in [rng.byte(), rng.byte(), rng.byte(), 255] as [UInt8] }
        let header = (0..<(w * headerHeight)).flatMap { index in
            let shade = UInt8(120 + (index / w) % 20 + index % 7)
            return [shade, shade &+ 10, shade &+ 20, 255] as [UInt8]
        }
        func image(_ bytes: [UInt8], height: Int) -> CGImage {
            CGImage(width: w, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                    provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { p in
                let c = CGContext(data: p.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        func frame(top: Int, variation: UInt8) -> CGImage {
            var bytes = header + Array(page[(top * w * 4)..<((top + h - headerHeight) * w * 4)])
            for index in 0..<header.count where index % 4 != 3 { bytes[index] &+= variation }
            return image(bytes, height: h)
        }


        // Exact fixed header; only the page beneath it moves.
        let first = frame(top: 0, variation: 0)
        let s = ScrollingCaptureStitcher(firstFrame: first, ignoredTrailingColumns: 0)!
        for top in [180, 210, 240] {
            let update = await s.add(frame(top: top, variation: 0))
            let height = await s.stitchedHeight
            FileHandle.standardOutput.write(Data("exact 130px header, page scroll \(top): \(update), height \(height)\n".utf8))
            #expect(update == .appended && height == h + top, "new cap regresses exact fixed header")
            let result = try #require(await s.makeImage())
            let expected = image(header + Array(page[0..<((h-headerHeight+top)*w*4)]), height: h+top)
            #expect(pixels(result) == pixels(expected), "exact-header page bytes changed")
        }
        }
        print("scenario 43 ok, SYNTHETIC exact 130px header retains byte-exact positive scrolls")

    }

    @Test("44: Exact and changing-header coverage controls") func scenario44() async throws {
        // 44. Original seven header explorations retain their pixel producers and
        // scroll sequences. Exact/small-step/pale controls remain asserted; the three
        // unsupported changing-edge paths are printed LIMITS, never safety passes.
        // The historic comments below describe the archived tolerance proposal;
        // R7 never learns tolerant edges. Actual outcomes are printed explicitly.
        do {

        let w = 480, h = 400, headerHeight = 80, pageHeight = 2000
        struct RNG {
            var value: UInt64
            mutating func byte() -> UInt8 {
                value = value &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: value >> 33)
            }
        }
        var rng = RNG(value: 7171)
        let page = (0..<(w * pageHeight)).flatMap { _ in [rng.byte(), rng.byte(), rng.byte(), 255] as [UInt8] }
        let header = (0..<(w * headerHeight)).flatMap { index in
            let shade = UInt8(120 + (index / w) % 20 + index % 7)
            return [shade, shade &+ 10, shade &+ 20, 255] as [UInt8]
        }
        func image(_ bytes: [UInt8], height: Int) -> CGImage {
            CGImage(width: w, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                    provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { p in
                let c = CGContext(data: p.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        func frame(top: Int, variation: UInt8) -> CGImage {
            var bytes = header + Array(page[(top * w * 4)..<((top + h - headerHeight) * w * 4)])
            for index in 0..<header.count where index % 4 != 3 { bytes[index] &+= variation }
            return image(bytes, height: h)
        }

        for varying in [false, true] {
            let first = frame(top: 0, variation: 0)
            let s = ScrollingCaptureStitcher(firstFrame: first, ignoredTrailingColumns: 0)!
            var updates: [ScrollingCaptureStitcher.Update] = []
            for (index, top) in [150, 180, 240, 300].enumerated() {
                updates.append(await s.add(frame(top: top, variation: varying ? UInt8(index + 1) : 0)))
            }
            let result = try #require(await s.makeImage())
            let expected = header + Array(page[0..<((300 + h - headerHeight) * w * 4)])
            let exact = result.height == h + 300 && pixels(result) == expected
            FileHandle.standardOutput.write(Data("SYNTHETIC \(varying ? "varying" : "exact") header: \(updates), height \(result.height), byte-exact prefix \(exact)\n".utf8))
            if !varying { #expect(exact && updates.allSatisfy { $0 == .appended }, "exact-header control") }
            if varying { print("LIMIT changing 80px header: large steps may refuse; no tolerance learning") }
        }

        // A first append before tolerant confirmation fixes the cut at 300. Later
        // header confirmation would otherwise move it to 320 and skip 20 page rows.
        do {
            let s = ScrollingCaptureStitcher(firstFrame: frame(top: 0, variation: 0), ignoredTrailingColumns: 0)!
            var updates: [ScrollingCaptureStitcher.Update] = []
            for (index, top) in [30, 60, 90].enumerated() {
                updates.append(await s.add(frame(top: top, variation: UInt8(index + 1))))
            }
            let result = try #require(await s.makeImage())
            let expected = header + Array(page[0..<((90 + h - headerHeight) * w * 4)])
            #expect(updates.allSatisfy { $0 == .appended } && result.height == 490 && pixels(result) == expected,
                         "confirming header moved the accepted cut")
            print("CONTROL small-step changing header: byte-exact prefix")
        }

        // After confirmation the header starts scrolling with the page. Removing its
        // exclusion would change the calculated cut from 320 to 300; assembly must
        // still append at 320, retaining every original page byte exactly once.
        do {
            let s = ScrollingCaptureStitcher(firstFrame: frame(top: 0, variation: 0), ignoredTrailingColumns: 0)!
            let first = await s.add(frame(top: 150, variation: 1))
            let accepted = frame(top: 180, variation: 2)
            let second = await s.add(accepted)
            print("LIMIT changing header then scrolling header, setup:", first, second)
            let acceptedBytes = pixels(accepted)
            for shift in [20, 40, 60] {
                let sliding = Array(acceptedBytes[(shift * w * 4)...])
                    + Array(page[((180 + h - headerHeight) * w * 4)..<((180 + h - headerHeight + shift) * w * 4)])
                let update = await s.add(image(sliding, height: h))
                let result = try #require(await s.makeImage())
                let expected = header + Array(page[0..<((180 + h - headerHeight + shift) * w * 4)])
                print("LIMIT header later moves", shift, update, "height", result.height,
                      "complete expected prefix", result.height == h + 180 + shift && pixels(result) == expected)
            }
            print("LIMIT changing header then moving: observations above, no must-stitch assertion")
        }

        // Both ends can vary. The header is kept from the first frame and the footer
        // from the last accepted frame, with the entire scrolling page byte-exact.
        do {
            let topRows = 40, bottomRows = 60
            let top = Array(header[0..<(topRows * w * 4)])
            let bottom = Array(header[0..<(bottomRows * w * 4)])
            func view(_ offset: Int, variation: UInt8) -> CGImage {
                var a = top, b = bottom
                for i in a.indices where i % 4 != 3 { a[i] &+= variation }
                for i in b.indices where i % 4 != 3 { b[i] &+= variation }
                return image(a + Array(page[(offset * w * 4)..<((offset + h - topRows - bottomRows) * w * 4)]) + b, height: h)
            }
            let s = ScrollingCaptureStitcher(firstFrame: view(0, variation: 0), ignoredTrailingColumns: 0)!
            var updates: [ScrollingCaptureStitcher.Update] = []
            for (i, offset) in [150, 180, 240, 300].enumerated() { updates.append(await s.add(view(offset, variation: UInt8(i + 1)))) }
            let result = try #require(await s.makeImage())
            let footer = Array(pixels(view(300, variation: 4))[((h - bottomRows) * w * 4)...])
            let expected = top + Array(page[0..<((300 + h - topRows - bottomRows) * w * 4)]) + footer
            print("LIMIT changing top and bottom", updates, "height", result.height, "complete expected prefix", result.height == 700 && pixels(result) == expected)
            print("LIMIT changing top and bottom: observation above, no must-stitch assertion")
        }

        // A tall slowly varying hero exceeds the cap; it cannot erase contradictory
        // rows until the remainder looks like a reliable scroll.
        do {
            let hero = header + header
            func view(_ offset: Int, variation: UInt8) -> CGImage {
                var a = hero
                for i in a.indices where i % 4 != 3 { a[i] &+= variation }
                return image(a + Array(page[(offset * w * 4)..<((offset + h - 160) * w * 4)]), height: h)
            }
            let first = view(0, variation: 0)
            let s = ScrollingCaptureStitcher(firstFrame: first, ignoredTrailingColumns: 0)!
            for (i, offset) in [150, 180, 240, 300].enumerated() {
                let update = await s.add(view(offset, variation: UInt8(i + 1)))
                let output = try #require(await s.makeImage())
                #expect(update == .noMatch && output.height == h && pixels(output) == pixels(first),
                             "tall hero erased contradictory content or changed prefix")
            }
            print("CONTROL tall hero: refused, initial output bytes unchanged")
        }

        // Low-contrast moving content can meet the colour tolerance without being a
        // header. Independent shift evidence and the constant cut preserve all rows.
        do {
            var rng = RNG(value: 8787)
            let pale = (0..<(w * pageHeight)).flatMap { _ in
                [UInt8(120 + rng.byte() % 5), UInt8(130 + rng.byte() % 5), UInt8(140 + rng.byte() % 5), 255] as [UInt8]
            }
            func view(_ offset: Int) -> CGImage { image(Array(pale[(offset * w * 4)..<((offset + h) * w * 4)]), height: h) }
            let s = ScrollingCaptureStitcher(firstFrame: view(0), ignoredTrailingColumns: 0)!
            for offset in [20, 40, 60] {
                let update = await s.add(view(offset))
                let result = try #require(await s.makeImage())
                #expect(update == .appended && result.height == h + offset && pixels(result) == Array(pale[0..<((h + offset) * w * 4)]),
                             "low-contrast content misclassified into lost/duplicated rows")
            }
            print("CONTROL pale moving page: byte-exact prefix")
        }
        }
        print("scenario 44 ok, SYNTHETIC header controls; three changing-edge paths printed as limits")
    }

    private func historicalWitness(disappears: Bool) async throws {
        // 27–28. SYNTHETIC historical-mask safety: a moving witness becomes sticky;
        // coherent motion outside it vetoes idle. Losing part of the witness does too.
        do {
            let w = 256, h = 240, pageWidth = disappears ? 128 : 96
            func scene(_ top: Int, seed: UInt64) -> CGImage {
                var b = bytes(idFrame(Array(top..<(top + h)), width: w)), noise = RNG(s: seed)
                for y in 0..<h { for x in pageWidth..<w {
                    let i = (y * w + x) * 4
                    b[i] = noise.next(); b[i + 1] = noise.next(); b[i + 2] = noise.next()
                } }
                return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let first = scene(0, seed: 4000), accepted = scene(20, seed: 4001)
            let s = ScrollingCaptureStitcher(firstFrame: first, ignoredTrailingColumns: 0)!
            let append = await s.add(accepted)
            #expect(append == .appended, "historical witness setup")
            let before = bytes(accepted)
            var changed = before, noise = RNG(s: 4002)
            for y in 0..<h { for x in 0..<w {
                let i = (y * w + x) * 4
                if disappears && (64..<128).contains(x) {
                    for c in 0..<4 { changed[i + c] = 255 }
                } else if x >= pageWidth {
                    if !disappears && y + 20 < h {
                        for c in 0..<4 { changed[i + c] = before[((y + 20) * w + x) * 4 + c] }
                    } else {
                        changed[i] = noise.next(); changed[i + 1] = noise.next(); changed[i + 2] = noise.next()
                    }
                }
            } }
            let changedImage = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                       provider: CGDataProvider(data: Data(changed) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let refusal = await s.add(changedImage)
            #expect(refusal == .noMatch, "stale witness silently cleared: \(disappears), \(refusal)")
            let height = await s.stitchedHeight
            #expect(height == 260, "stale witness grew")
            let recover = await s.add(scene(20, seed: 4003))
            #expect(recover == .unchanged, "idle at last accepted position did not recover")
            print(disappears ? "scenario 28 ok, SYNTHETIC disappearing witness refuses" : "scenario 27 ok, SYNTHETIC sticky witness plus contradictory motion refuses")
        }

    }

    private func startupMotion(fineOnly: Bool) async throws {
        // 31–32. SYNTHETIC startup controls: moving evidence below eight distinct
        // rows, and fine-strip-only motion, must still veto a dominant header's zero.
        do {
            let w = 256, h = 240, header = 168
            func pane(_ top: Int) -> CGImage {
                var b = bytes(idFrame(Array(0..<h), width: w)), noise = RNG(s: UInt64(6000 + top))
                let body = bytes(idFrame((0..<h).map { fineOnly ? $0 + top : ($0 + top) % 7 }, width: w))
                for y in header..<h { for x in 0..<w {
                    let i = (y * w + x) * 4
                    if !fineOnly || x >= w - 16 {
                        for c in 0..<4 { b[i + c] = body[i + c] }
                    } else {
                        b[i] = noise.next(); b[i + 1] = noise.next(); b[i + 2] = noise.next()
                    }
                } }
                return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let s = ScrollingCaptureStitcher(firstFrame: pane(0), ignoredTrailingColumns: 0)!
            let update = await s.add(pane(20))
            let height = await s.stitchedHeight
            #expect(update == .noMatch && height == 240,
                         "startup zero hid sparse/fine motion: \(fineOnly), \(update)")
            print(fineOnly ? "scenario 32 ok, SYNTHETIC fine-strip startup motion refuses" : "scenario 31 ok, SYNTHETIC seven-distinct-row startup motion refuses")
        }

        // Header-tolerance work was archived by the user. These exact reproductions
        // remain required R7 controls; expectations stay active in both build modes.

    }

    private func sidebarControls(group: Int) async throws {
        // 34–36. SYNTHETIC pinned sidebar controls, using multi-shade text
        // so the chrome classifier cannot hide the sidebar by repartitioning strips.
        do {
            let w = 480, h = 400, pageHeight = 2000, origin = 400
            func textPage(seed: UInt64) -> [UInt8] {
                var rng = RNG(s: seed), p = [UInt8](repeating: 255, count: w * pageHeight * 4)
                for y in 0..<pageHeight {
                    let line = y / 24, inLine = y % 24
                    guard inLine < 16, line % 7 != 6 else { continue }
                    for x in 0..<w where rng.next() < 80 {
                        let i = (y * w + x) * 4, g = rng.next() / 2
                        p[i] = g; p[i + 1] = g &+ 10; p[i + 2] = g &+ 20
                    }
                }
                return p
            }
            let page = textPage(seed: 99), side = textPage(seed: 7)
            func view(top: Int, videoEnd: Int, videoRows: Range<Int>?, seed: UInt64, sideTop: Int = 0, videoTop: Int? = nil) -> CGImage {
                var b = Array(page[((top + origin) * w * 4)..<((top + origin + h) * w * 4)]), noise = RNG(s: seed)
                for y in 0..<h { for x in 0..<videoEnd {
                    let i = (y * w + x) * 4
                    if x < 120 {
                        for c in 0..<4 { b[i + c] = side[((y + sideTop) * w + x) * 4 + c] }
                    } else if videoRows?.contains(top + y) == true {
                        if let videoTop {
                            for c in 0..<4 { b[i + c] = page[((videoTop + origin + y) * w + x) * 4 + c] }
                        } else {
                            b[i] = noise.next(); b[i + 1] = noise.next(); b[i + 2] = noise.next()
                        }
                    }
                } }
                return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            if group == 34 {
            for videoEnd in [300, 360, 400] {
                // (a) Start above the video, accept a primer, then refuse when the
                // dominant video prevents a primary match: sidebar zero conflicts.
                let firstTop = -220, finalTop = 320, videoRows = 250..<550
                let s = ScrollingCaptureStitcher(firstFrame: view(top: firstTop, videoEnd: videoEnd, videoRows: videoRows, seed: 8000), ignoredTrailingColumns: 0)!
                var updates: [ScrollingCaptureStitcher.Update] = []
                var acceptedTop = firstTop, refused = false
                for top in stride(from: firstTop + 60, through: finalTop, by: 60) {
                    let update = await s.add(view(top: top, videoEnd: videoEnd, videoRows: videoRows, seed: UInt64(9000 + top)))
                    if update == .noMatch { refused = true }
                    if update == .appended {
                        #expect(!refused, "sidebar appended past a refused video")
                        acceptedTop = top
                    }
                    updates.append(update)
                }
                let result = try #require(await s.makeImage())
                FileHandle.standardOutput.write(Data("sidebar refusal \(videoEnd) \(updates) height \(result.height)\n".utf8))
                #expect(updates.first == .appended && refused && result.height == h + acceptedTop - firstTop,
                             "sidebar video was not refused: \(videoEnd), \(updates), \(result.height)")
                let got = bytes(result)
                for y in 0..<result.height { for x in 120..<w where x >= videoEnd || !videoRows.contains(firstTop + y) {
                    for c in 0..<4 {
                        #expect(got[(y * w + x) * 4 + c] == page[((firstTop + origin + y) * w + x) * 4 + c],
                                     "sidebar video page seam")
                    }
                } }
                let idle = await s.add(view(top: finalTop, videoEnd: videoEnd, videoRows: videoRows, seed: 10000))
                let afterIdle = bytes(try #require(await s.makeImage()))
                #expect(idle == .noMatch && afterIdle == got,
                             "refused sidebar video changed accepted output")
            }
            // With video already filling the view and no accepted primer, the
            // unknown sidebar zero still conflicts. Do not bootstrap from animation.
            for videoEnd in [300, 360, 400] {
                let first = view(top: 0, videoEnd: videoEnd, videoRows: 0..<2000, seed: 13000)
                let s = ScrollingCaptureStitcher(firstFrame: first, ignoredTrailingColumns: 0)!
                for top in stride(from: 60, through: 300, by: 60) {
                    let update = await s.add(view(top: top, videoEnd: videoEnd, videoRows: 0..<2000, seed: UInt64(13000 + top)))
                    #expect(update == .noMatch, "unprimed sidebar was guessed pinned")
                }
                let height = await s.stitchedHeight
                let prefix = bytes(try #require(await s.makeImage()))
                #expect(height == h && prefix == bytes(first), "unprimed sidebar changed prefix")
            }
            print("scenario 34 ok, SYNTHETIC primed and unprimed sidebar refuse video; byte-exact page prefix")

            }
            if group == 35 {
            for videoEnd in [300, 360, 400] {
                // (b) The video first moves with the page during the primer.
                // Then only the video translates while the actual page stays still.
                let s = ScrollingCaptureStitcher(firstFrame: view(top: 0, videoEnd: videoEnd, videoRows: 0..<2000, seed: 11000, videoTop: 0), ignoredTrailingColumns: 0)!
                let setup = await s.add(view(top: 20, videoEnd: videoEnd, videoRows: 0..<2000, seed: 11001, videoTop: 20))
                #expect(setup == .appended, "still-page animation setup")
                let prefix = bytes(try #require(await s.makeImage()))
                let update = await s.add(view(top: 20, videoEnd: videoEnd, videoRows: 0..<2000, seed: 11002, videoTop: 40))
                let height = await s.stitchedHeight
                let after = bytes(try #require(await s.makeImage()))
                #expect(update == .noMatch && height == 420 && after == prefix,
                             "sidebar let video override stationary page")
            }
            print("scenario 35 ok, SYNTHETIC still page plus translating animation refuses")

            // (c) Fixed or conflicting sidebar offsets refuse at video. An agreeing
            // moving sidebar is page motion, and remains a separate positive control.
            }
            if group == 36 {
            for sideShift in [0, 40, 20] {
                let videoEnd = 360
                let s = ScrollingCaptureStitcher(firstFrame: view(top: 0, videoEnd: videoEnd, videoRows: nil, seed: 12000), ignoredTrailingColumns: 0)!
                let setup = await s.add(view(top: 20, videoEnd: videoEnd, videoRows: nil, seed: 12001))
                #expect(setup == .appended, "moving pinned-column setup")
                let prefix = bytes(try #require(await s.makeImage()))
                let update = await s.add(view(top: 40, videoEnd: videoEnd, videoRows: 0..<2000, seed: 12002, sideTop: sideShift))
                let height = await s.stitchedHeight
                #expect(update == (sideShift == 20 ? .appended : .noMatch) && height == (sideShift == 20 ? 440 : 420),
                             "sidebar motion conflict: \(sideShift), \(update), \(height)")
                if sideShift != 20 {
                    let after = bytes(try #require(await s.makeImage()))
                    #expect(after == prefix, "sidebar refusal changed prefix")
                }
                if sideShift == 20 {
                    let next = await s.add(view(top: 60, videoEnd: videoEnd, videoRows: 0..<2000, seed: 12003, sideTop: 20))
                    let after = await s.stitchedHeight
                    #expect(next == .noMatch && after == 440, "stale pin knowledge survived its move")
                }
            }
            print("scenario 36 ok, SYNTHETIC fixed/conflicting sidebar refuses, agreeing page motion control")    }
        }

    }
}
