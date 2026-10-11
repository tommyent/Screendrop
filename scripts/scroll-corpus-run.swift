// Scores Scrolling Capture matchers against a seam-truth corpus. The corpus
// holds private screen content and lives outside the repo: one folder per
// page with NNNN.png frames and truth.json
// {source, selection, ignoredTrailingColumns, frames:[{index,time}],
//  seams:[{from,to,offset|null,truthKind:"scrollY"|"manual"|"unknown"}]}.
// A seam offset means content moved up: to[y] == from[y + offset]. The app's
// frame dump (ScrollingCaptureTrace.swift) is a page missing only truth.json:
// its page.json supplies selection and ignoredTrailingColumns.
//
// R7, the baseline, left the app; it's compiled from the commit before the rework:
// git show 3f9b9d3:Screendrop/ScrollingCaptureStitcher.swift > /tmp/r7-stitcher.swift
// swiftc -parse-as-library -default-isolation MainActor scripts/scroll-corpus-run.swift /tmp/r7-stitcher.swift \
//   Screendrop/ScrollingCapture{Feed,FrameStitcher,Raster,Region,Stream,Trace}.swift \
//   Screendrop/ScrollingCaptureOffset{Estimator,Verifier}.swift -o /tmp/scroll-corpus-run
// /tmp/scroll-corpus-run <corpus dir> --matcher r7|estimator|vision-verify|stitcher [--compare <matcher>]
//
// Each frame with a seam from its predecessor is one seam to score. A frame
// without one starts a new run with a fresh matcher. A matcher's claim is
// judged against the summed seam offsets from the frame it compared with;
// any "unknown" seam on that path leaves the seam unscored. Placing a frame
// where truth says nothing fits (a known seam with a null offset on the path,
// or a total at least the frame height) is wrong; refusing there is correct,
// and refusing elsewhere is skipped. A refusal is judged along the same path,
// from the frame the matcher kept as its reference.
// Pages are also totalled by name prefix (user-, fresh-) when there are several.
// Each unscored seam's claim is printed above the table, for reading only.
// Two more columns are output only. stuck: frames at the end of a run that
// got no claim, the reference never catching up. heightErr: stitched height
// minus the truth (frame height plus the run's summed offsets), "-" when a
// seam is unknown or the matcher doesn't stitch; totals sum |page heightErr|
// over the pages with one, "/Np".
// dupBlocks, output only: in each run's stitched output, the 32-row blocks of
// a column strip (8 strips, grid-aligned; at least 8 distinct rows, so not
// blank space, lines or rules) whose pixels also occur
// at another height at least 32 rows away: content copied twice, such as a
// fixed sidebar or card appended into every slice. Repeated content on the
// page itself counts too. "--dup-blocks <png>..." prints it for saved captures.
// --compare runs a second matcher too and prints, for both, the correct seams
// among those both score, and |heightErr| summed over the jump-free pages
// (no known seam with nothing fitting) where both have a height.
// For the stitcher, a second table counts the frames for which the capture bar
// would show a message, as back/changing ("Scroll back a little" / "Something
// on the page keeps changing"). Old rule: every refused frame, changing when
// its change from the frame before covers more than the feed's
// changingCoverage. New rule, after each delay: refused frames at least that
// long after the first refused frame of their run (by truth.json frame
// times), changing when Vision's candidate is one the verifier can confirm
// (cand), or when the bands' consensus alone is (bands: the whole-frame
// fallback proposes an offset for unrelated frames too).
// Fresh pages' frame times are a script's pauses, not a stream's.
import CoreGraphics
import Foundation
import ImageIO

/// The new frame's content moved up by `offset` device pixels from run frame
/// `against`: new[y] == against[y + offset]. A nil offset refuses, having
/// compared the frame with `against`.
struct Claim { let against: Int; let offset: Int? }

/// Sees one run's frames in order, the first at creation.
protocol CorpusMatcher: AnyObject {
    func place(_ frame: CGImage, index: Int) async -> Claim
    /// The output's height so far; nil for a matcher that doesn't stitch.
    var stitchedHeight: Int? { get async }
    /// The output so far, packed BGRA; nil for a matcher that doesn't stitch.
    var stitchedImage: (pixels: [UInt8], width: Int)? { get async }
}

/// R7 as the engine drives it: the stitcher alone, on the selection crop. It
/// compares each frame with the last one it appended.
final class R7Matcher: CorpusMatcher {
    let stitcher: ScrollingCaptureStitcher
    var reference: Int

    init?(first: CGImage, index: Int, ignoredTrailingColumns: Int) {
        guard let stitcher = ScrollingCaptureStitcher(firstFrame: first, ignoredTrailingColumns: ignoredTrailingColumns)
        else { return nil }
        self.stitcher = stitcher
        reference = index
    }

    func place(_ frame: CGImage, index: Int) async -> Claim {
        let base = await stitcher.stitchedHeight - frame.height
        let update = await stitcher.add(frame)
        guard update != .noMatch, let registration = await stitcher.registration else {
            return Claim(against: reference, offset: nil)
        }
        let claim = Claim(against: reference, offset: registration.offset - base)
        if update == .appended { reference = index }
        return claim
    }

    var stitchedHeight: Int? { get async { await stitcher.stitchedHeight } }
    var stitchedImage: (pixels: [UInt8], width: Int)? {
        get async { await stitcher.makeImage().flatMap { image in VisionMatcher.pixels(image).map { ($0, image.width) } } }
    }
}

/// Vision's candidate against the frame before, alone or confirmed by the
/// verifier. Every frame becomes the next reference, placed or not.
final class VisionMatcher: CorpusMatcher {
    let verify: Bool
    let ignoredTrailingColumns: Int
    var last: [UInt8]
    var reference: Int

    init?(first: CGImage, index: Int, ignoredTrailingColumns: Int, verify: Bool) {
        guard let pixels = Self.pixels(first) else { return nil }
        self.verify = verify
        self.ignoredTrailingColumns = ignoredTrailingColumns
        last = pixels
        reference = index
    }

    func place(_ frame: CGImage, index: Int) async -> Claim {
        guard let new = Self.pixels(frame) else { return Claim(against: reference, offset: nil) }
        defer { last = new; reference = index }
        let candidate = ScrollingCaptureOffsetEstimator.candidateOffset(from: last, to: new,
            width: frame.width, height: frame.height, ignoredTrailingColumns: ignoredTrailingColumns)
        guard verify, let candidate else { return Claim(against: reference, offset: candidate) }
        return Claim(against: reference, offset: ScrollingCaptureOffsetVerifier.verifiedOffset(candidate: candidate,
            from: last, to: new, width: frame.width, height: frame.height,
            ignoredTrailingColumns: ignoredTrailingColumns)?.offset)
    }

    var stitchedHeight: Int? { get async { nil } }
    var stitchedImage: (pixels: [UInt8], width: Int)? { get async { nil } }

    static func pixels(_ image: CGImage) -> [UInt8]? {
        ScrollingCapturePixels.bytes(of: image, in: ScrollingCapturePixels.colorSpace(of: image))
    }
}

/// vision-verify driven through the stitcher: a frame that isn't verified is
/// skipped, and the next is compared with the reference it kept.
final class StitcherMatcher: CorpusMatcher {
    /// `agreed`: the bands' consensus alone, without the whole-frame fallback.
    struct Logged { let index: Int; let skipped: Bool; let candidate: Int?; let agreed: Int?; let changed: Double }

    let stitcher: ScrollingCaptureFrameStitcher
    let width: Int
    let ignoredTrailingColumns: Int
    var reference: Int
    /// Every frame placed or skipped, for the bar-message table.
    var log: [Logged] = []
    private var previous: [UInt8]
    private var referencePixels: [UInt8]

    init?(first: CGImage, index: Int, ignoredTrailingColumns: Int) {
        guard let pixels = VisionMatcher.pixels(first), let stitcher = ScrollingCaptureFrameStitcher(firstFrame: pixels,
            width: first.width, height: first.height, ignoredTrailingColumns: ignoredTrailingColumns) else { return nil }
        self.stitcher = stitcher
        width = first.width
        self.ignoredTrailingColumns = ignoredTrailingColumns
        reference = index
        previous = pixels
        referencePixels = pixels
    }

    func place(_ frame: CGImage, index: Int) async -> Claim {
        guard let pixels = VisionMatcher.pixels(frame) else { return Claim(against: reference, offset: nil) }
        let (placement, candidate) = await stitcher.add(pixels)
        let skipped = placement == .skipped
        let agreed = skipped ? ScrollingCaptureOffsetEstimator.consensus(ScrollingCaptureOffsetEstimator.bandShifts(
            from: referencePixels, to: pixels, width: width, height: frame.height, ignoredTrailingColumns: ignoredTrailingColumns)) : nil
        log.append(Logged(index: index, skipped: skipped, candidate: candidate, agreed: agreed, changed: skipped
            ? ScrollingCaptureFeed.changedShare(previous, pixels, width: width, usableWidth:
                ScrollingCaptureOffsetVerifier.hashedWidth(width: width, ignoredTrailingColumns: ignoredTrailingColumns)) : 0))
        previous = pixels
        let claim = Claim(against: reference, offset: placement.offset)
        if placement.isReference { reference = index; referencePixels = pixels }
        return claim
    }

    var stitchedHeight: Int? { get async { await stitcher.stitchedHeight } }
    var stitchedImage: (pixels: [UInt8], width: Int)? { get async { (await stitcher.makeImage(), width) } }
}

/// Grid-aligned 32-row blocks of 8 column strips, with at least 8 distinct
/// rows, whose pixels also occur at least 32 rows above or below.
func dupBlocks(_ pixels: [UInt8], width: Int, usableWidth: Int) -> Int {
    let height = pixels.count / (width * 4), block = 32
    guard height >= 2 * block else { return 0 }
    let strips = (0..<8).map { ($0 * usableWidth / 8)..<(($0 + 1) * usableWidth / 8) }
    var count = 0
    pixels.withUnsafeBytes { bytes in
        for x in strips {
            var rowHash = [Int](repeating: 0, count: height)
            for y in 0..<height {
                var hasher = Hasher()
                hasher.combine(bytes: UnsafeRawBufferPointer(start: bytes.baseAddress! + (y * width + x.lowerBound) * 4,
                                                             count: x.count * 4))
                rowHash[y] = hasher.finalize()
            }
            var heights: [Int: [Int]] = [:]
            for y in 0...(height - block) {
                var hasher = Hasher()
                for row in y..<(y + block) { hasher.combine(rowHash[row]) }
                heights[hasher.finalize(), default: []].append(y)
            }
            // Blank space, lines and rules repeat anywhere: a block needs 8 distinct rows.
            for y in stride(from: 0, through: height - block, by: block) where Set(rowHash[y..<(y + block)]).count >= 8 {
                var hasher = Hasher()
                for row in y..<(y + block) { hasher.combine(rowHash[row]) }
                if heights[hasher.finalize()]!.contains(where: { abs($0 - y) >= block }) { count += 1 }
            }
        }
    }
    return count
}

let matchers: [String: (_ first: CGImage, _ index: Int, _ ignoredTrailingColumns: Int) -> CorpusMatcher?] = [
    "r7": { R7Matcher(first: $0, index: $1, ignoredTrailingColumns: $2) },
    "estimator": { VisionMatcher(first: $0, index: $1, ignoredTrailingColumns: $2, verify: false) },
    "vision-verify": { VisionMatcher(first: $0, index: $1, ignoredTrailingColumns: $2, verify: true) },
    "stitcher": { StitcherMatcher(first: $0, index: $1, ignoredTrailingColumns: $2) },
]

/// Delays, in seconds, after which the bar-message table counts.
let barDelays: [TimeInterval] = [0, 0.3, 0.5, 1, 2]

/// Refused frames; the old rule's back and changing; then, after each of
/// `barDelays`, back and changing by Vision's candidate, and back and changing
/// by the bands' consensus alone. A refusal run is consecutive refused frames.
func barCounts(_ log: [StitcherMatcher.Logged], times: [Int: TimeInterval], height: Int) -> [Int] {
    var counts = [Int](repeating: 0, count: 3 + 4 * barDelays.count)
    var runStart: TimeInterval = 0
    for (n, frame) in log.enumerated() where frame.skipped {
        if n == 0 || !log[n - 1].skipped || log[n - 1].index != frame.index - 1 { runStart = times[frame.index] ?? 0 }
        counts[0] += 1
        counts[frame.changed > ScrollingCaptureFeed.changingCoverage ? 2 : 1] += 1
        let changing = frame.candidate.map { ScrollingCaptureOffsetVerifier.canConfirm($0, height: height) } ?? false
        let agreed = frame.agreed.map { ScrollingCaptureOffsetVerifier.canConfirm($0, height: height) } ?? false
        let waited = (times[frame.index] ?? 0) - runStart
        for (d, delay) in barDelays.enumerated() where waited >= delay {
            counts[3 + 4 * d + (changing ? 1 : 0)] += 1
            counts[5 + 4 * d + (agreed ? 1 : 0)] += 1
        }
    }
    return counts
}

struct Truth: Decodable {
    struct Rect: Decodable { let columns: [Int]; let rows: [Int] }
    struct Frame: Decodable { let index: Int; let time: TimeInterval? }
    struct Seam: Decodable { let from: Int; let to: Int; let offset: Int?; let truthKind: String }
    let selection: Rect
    let ignoredTrailingColumns: Int
    let frames: [Frame]
    let seams: [Seam]
}

struct Tally {
    var pages = 0, seams = 0, scored = 0, correct = 0, wrong = 0, skipped = 0, unscored = 0, stuck = 0
    var offBy: [Int: Int] = [:]
    /// A page's signed height error; totals keep only the two sums below.
    var heightErr: Int?
    var heightAbs = 0, heightPages = 0
    /// Summed over runs and pages; nil when a matcher doesn't stitch.
    var dupBlocks: Int?
    /// A page's seams (by frame index) for --compare, and whether any known seam has nothing fitting.
    var scoredSeams = Set<Int>(), correctSeams = Set<Int>()
    var jumpFree = true
    /// `barCounts`, for the stitcher only.
    var bar: [Int] = []

    static func += (lhs: inout Tally, rhs: Tally) {
        lhs.pages += rhs.pages; lhs.seams += rhs.seams; lhs.scored += rhs.scored; lhs.correct += rhs.correct
        lhs.wrong += rhs.wrong; lhs.skipped += rhs.skipped; lhs.unscored += rhs.unscored; lhs.stuck += rhs.stuck
        lhs.heightAbs += rhs.heightAbs; lhs.heightPages += rhs.heightPages
        if let dup = rhs.dupBlocks { lhs.dupBlocks = (lhs.dupBlocks ?? 0) + dup }
        lhs.offBy.merge(rhs.offBy, uniquingKeysWith: +)
        if !rhs.bar.isEmpty { lhs.bar = lhs.bar.isEmpty ? rhs.bar : zip(lhs.bar, rhs.bar).map(+) }
    }

    var barRow: [String] {
        ["\(bar[0])"] + stride(from: 1, to: bar.count, by: 2).map { "\(bar[$0])/\(bar[$0 + 1])" }
    }

    var row: [String] {
        let histogram = offBy.keys.sorted().map { "\($0):\(offBy[$0]!)" }.joined(separator: " ")
        let off = offBy.values.reduce(0, +)
        return ["\(pages)", "\(seams)", "\(scored)", "\(correct)", off == 0 ? "0" : "\(off) (\(histogram))",
                "\(wrong)", "\(skipped)", "\(unscored)", "\(stuck)",
                pages == 1 ? heightErr.map(String.init) ?? "-" : "\(heightAbs)/\(heightPages)p",
                dupBlocks.map(String.init) ?? "-"]
    }
}

@main struct ScrollCorpusRun {
    static func main() async throws {
        let arguments = CommandLine.arguments
        if arguments.count > 2, arguments[1] == "--dup-blocks" {
            for path in arguments.dropFirst(2) {
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let pixels = VisionMatcher.pixels(image) else { print(path, "unreadable"); continue }
                print(path, "dupBlocks", dupBlocks(pixels, width: image.width, usableWidth:
                    ScrollingCaptureOffsetVerifier.hashedWidth(width: image.width, ignoredTrailingColumns: 40)))
            }
            return
        }
        let names = matchers.keys.sorted().joined(separator: "|")
        guard arguments.count == 4 || arguments.count == 6, arguments[2] == "--matcher", let make = matchers[arguments[3]],
              arguments.count == 4 || arguments[4] == "--compare" && matchers[arguments[5]] != nil else {
            print("usage: scroll-corpus-run <corpus dir> --matcher <\(names)> [--compare <\(names)>]")
            exit(2)
        }
        let other = arguments.count == 6 ? matchers[arguments[5]] : nil
        var common = 0, commonCorrect = (0, 0), jumpFreePages = 0, jumpFreeHeight = (0, 0)
        let corpus = URL(fileURLWithPath: arguments[1])
        let pages = try FileManager.default.contentsOfDirectory(atPath: corpus.path).sorted()
            .filter { FileManager.default.fileExists(atPath: corpus.appendingPathComponent("\($0)/truth.json").path) }
        var rows: [[String]] = [], barRows: [[String]] = []
        var total = Tally()
        var groups: [String: Tally] = [:]
        for page in pages {
            let folder = corpus.appendingPathComponent(page)
            let truth = try readTruth(folder)
            let tally = try await score(truth, folder: folder, make: make)
            if let other {
                let rival = try await score(truth, folder: folder, make: other, verbose: false)
                let both = tally.scoredSeams.intersection(rival.scoredSeams)
                common += both.count
                commonCorrect.0 += tally.correctSeams.intersection(both).count
                commonCorrect.1 += rival.correctSeams.intersection(both).count
                if tally.jumpFree, let a = tally.heightErr, let b = rival.heightErr {
                    jumpFreePages += 1
                    jumpFreeHeight.0 += abs(a); jumpFreeHeight.1 += abs(b)
                }
            }
            rows.append([page] + tally.row)
            if !tally.bar.isEmpty { barRows.append([page] + tally.barRow) }
            total += tally
            groups[String(page.prefix { $0 != "-" }), default: Tally()] += tally
        }
        if groups.count > 1 { rows += groups.keys.sorted().map { ["TOTAL \($0)"] + groups[$0]!.row } }
        rows.append(["TOTAL"] + total.row)
        if !total.bar.isEmpty {
            if groups.count > 1 { barRows += groups.keys.sorted().map { ["TOTAL \($0)"] + groups[$0]!.barRow } }
            barRows.append(["TOTAL"] + total.barRow)
        }
        print("matcher \(arguments[3]), corpus \(corpus.path)")
        defer {
            if other != nil {
                print("compare \(arguments[3]) vs \(arguments[5]): seams both score \(common), correct \(commonCorrect.0) vs \(commonCorrect.1); "
                    + "jump-free pages with heights \(jumpFreePages), sum |heightErr| \(jumpFreeHeight.0) vs \(jumpFreeHeight.1)")
            }
        }
        printTable(["page", "pages", "seams", "scored", "correct", "off-by-N (N:count)", "wrong", "skipped", "unscored", "stuck",
                    "heightErr", "dupBlocks"], rows)
        if !barRows.isEmpty {
            print("bar messages, frames back/changing: old rule, then new rule after each delay")
            printTable(["page", "refused", "old"] + barDelays.flatMap { ["cand@\($0.formatted())s", "bands@\($0.formatted())s"] },
                       barRows)
        }
    }

    static func printTable(_ header: [String], _ rows: [[String]]) {
        let table = [header] + rows
        let widths = header.indices.map { column in table.map { $0[column].count }.max()! }
        for row in table {
            print(row.indices.map { column in
                let pad = String(repeating: " ", count: widths[column] - row[column].count)
                return column == 0 ? row[column] + pad : pad + row[column]
            }.joined(separator: "  "))
        }
    }

    /// A frame dump's page.json holds selection and ignoredTrailingColumns, so its truth.json needn't.
    static func readTruth(_ folder: URL) throws -> Truth {
        func object(_ name: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(name))) as? [String: Any] ?? [:]
        }
        var truth = try object("truth.json")
        if let page = try? object("page.json") { truth.merge(page) { fromTruth, _ in fromTruth } }
        return try JSONDecoder().decode(Truth.self, from: JSONSerialization.data(withJSONObject: truth))
    }

    static func score(_ truth: Truth, folder: URL, make: (CGImage, Int, Int) -> CorpusMatcher?,
                      verbose: Bool = true) async throws -> Tally {
        var tally = Tally(pages: 1)
        let seamInto = Dictionary(uniqueKeysWithValues: truth.seams.map { ($0.to, $0) })
        let crop = CGRect(x: truth.selection.columns[0], y: truth.selection.rows[0],
                          width: truth.selection.columns[1] - truth.selection.columns[0],
                          height: truth.selection.rows[1] - truth.selection.rows[0])
        var matcher: CorpusMatcher?
        struct Run { var known = true, position = 0, trailingNil = 0 }
        var run = Run(), pageKnown = true, pageErr = 0
        var barLog: [StitcherMatcher.Logged]?
        func finishRun() async {
            guard let matcher else { return }
            tally.stuck += run.trailingNil
            if let stitcher = matcher as? StitcherMatcher { barLog = (barLog ?? []) + stitcher.log }
            if let image = await matcher.stitchedImage {
                tally.dupBlocks = (tally.dupBlocks ?? 0) + dupBlocks(image.pixels, width: image.width, usableWidth:
                    ScrollingCaptureOffsetVerifier.hashedWidth(width: image.width, ignoredTrailingColumns: truth.ignoredTrailingColumns))
            }
            if run.known, let height = await matcher.stitchedHeight {
                pageErr += height - (Int(crop.height) + run.position)
            } else { pageKnown = false }
        }
        for index in truth.frames.map(\.index).sorted() {
            let url = folder.appendingPathComponent(String(format: "%04d.png", index))
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let frame = image.cropping(to: crop) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]) }
            guard let seam = seamInto[index] else {
                await finishRun()
                matcher = make(frame, index, truth.ignoredTrailingColumns)
                run = Run()
                continue
            }
            tally.seams += 1
            run.known = run.known && seam.truthKind != "unknown" && seam.offset != nil
            run.position += seam.offset ?? 0
            let page = folder.lastPathComponent
            let claim = await matcher?.place(frame, index: index) ?? Claim(against: seam.from, offset: nil)
            run.trailingNil = claim.offset == nil ? run.trailingNil + 1 : 0
            // Walk back along the run to the frame the matcher compared with.
            var path: [Truth.Seam] = []
            var at = index
            while at != claim.against {
                guard let step = seamInto[at], step.from < at else { fatalError("\(folder.lastPathComponent): claim against \(claim.against) left the run at \(index)") }
                path.append(step)
                at = step.from
            }
            if path.contains(where: { $0.truthKind == "unknown" }) {
                tally.unscored += 1
                if verbose { print("unscored \(page) \(seam.from)->\(index): claim \(claim.offset.map(String.init) ?? "nil") against \(claim.against)") }
                continue
            }
            tally.scored += 1
            tally.scoredSeams.insert(index)
            let offsets = path.map(\.offset)
            let total: Int? = offsets.contains(nil) ? nil : offsets.reduce(0) { $0 + $1! }
            let nothingFits = total.map { abs($0) >= frame.height } ?? true
            guard let offset = claim.offset else {
                if nothingFits { tally.correct += 1; tally.correctSeams.insert(index) } else { tally.skipped += 1 }
                continue
            }
            guard let expected = total, !nothingFits else { tally.wrong += 1; continue }
            let error = abs(offset - expected)
            let wrongSign = offset != 0 && expected != 0 && (offset > 0) != (expected > 0)
            if error == 0 { tally.correct += 1; tally.correctSeams.insert(index) }
            else if error <= 3 && !wrongSign { tally.offBy[error, default: 0] += 1 }
            else { tally.wrong += 1 }
        }
        await finishRun()
        if let barLog {
            tally.bar = barCounts(barLog, times: Dictionary(uniqueKeysWithValues: truth.frames.compactMap { frame in
                frame.time.map { (frame.index, $0) } }), height: Int(crop.height))
        }
        tally.jumpFree = !truth.seams.contains { $0.truthKind != "unknown" && ($0.offset.map { abs($0) >= Int(crop.height) } ?? true) }
        if pageKnown { tally.heightErr = pageErr; tally.heightAbs = abs(pageErr); tally.heightPages = 1 }
        return tally
    }
}
