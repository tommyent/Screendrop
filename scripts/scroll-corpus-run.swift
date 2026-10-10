// Scores Scrolling Capture matchers against a seam-truth corpus. The corpus
// holds private screen content and lives outside the repo: one folder per
// page with NNNN.png frames and truth.json
// {source, selection, ignoredTrailingColumns, frames:[{index,time}],
//  seams:[{from,to,offset|null,truthKind:"scrollY"|"manual"|"unknown"}]}.
// A seam offset means content moved up: to[y] == from[y + offset]. The app's
// frame dump (ScrollingCaptureTrace.swift) is a page missing only truth.json:
// its page.json supplies selection and ignoredTrailingColumns.
//
// swiftc -parse-as-library -default-isolation MainActor scripts/scroll-corpus-run.swift \
//   Screendrop/ScrollingCapture{Stitcher,FrameStitcher,Registration}.swift Screendrop/ScrollingCaptureOffset{Estimator,Verifier}.swift \
//   -o /tmp/scroll-corpus-run
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
// --compare runs a second matcher too and prints, for both, the correct seams
// among those both score, and |heightErr| summed over the jump-free pages
// (no known seam with nothing fitting) where both have a height.
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

    /// Packed BGRA, drawn as R7 draws it.
    static func pixels(_ image: CGImage) -> [UInt8]? {
        ScrollingCaptureStitcher.pixels(of: image, colorSpace: image.colorSpace.flatMap {
            $0.model == .rgb && $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

/// vision-verify driven through the stitcher: a frame that isn't verified is
/// skipped, and the next is compared with the reference it kept.
final class StitcherMatcher: CorpusMatcher {
    let stitcher: ScrollingCaptureFrameStitcher
    var reference: Int

    init?(first: CGImage, index: Int, ignoredTrailingColumns: Int) {
        guard let pixels = VisionMatcher.pixels(first), let stitcher = ScrollingCaptureFrameStitcher(firstFrame: pixels,
            width: first.width, height: first.height, ignoredTrailingColumns: ignoredTrailingColumns) else { return nil }
        self.stitcher = stitcher
        reference = index
    }

    func place(_ frame: CGImage, index: Int) async -> Claim {
        guard let pixels = VisionMatcher.pixels(frame) else { return Claim(against: reference, offset: nil) }
        let placement = await stitcher.add(pixels).placement
        let claim = Claim(against: reference, offset: placement.offset)
        if placement.isReference { reference = index }
        return claim
    }

    var stitchedHeight: Int? { get async { await stitcher.stitchedHeight } }
}

let matchers: [String: (_ first: CGImage, _ index: Int, _ ignoredTrailingColumns: Int) -> CorpusMatcher?] = [
    "r7": { R7Matcher(first: $0, index: $1, ignoredTrailingColumns: $2) },
    "estimator": { VisionMatcher(first: $0, index: $1, ignoredTrailingColumns: $2, verify: false) },
    "vision-verify": { VisionMatcher(first: $0, index: $1, ignoredTrailingColumns: $2, verify: true) },
    "stitcher": { StitcherMatcher(first: $0, index: $1, ignoredTrailingColumns: $2) },
]

struct Truth: Decodable {
    struct Rect: Decodable { let columns: [Int]; let rows: [Int] }
    struct Frame: Decodable { let index: Int }
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
    /// A page's seams (by frame index) for --compare, and whether any known seam has nothing fitting.
    var scoredSeams = Set<Int>(), correctSeams = Set<Int>()
    var jumpFree = true

    static func += (lhs: inout Tally, rhs: Tally) {
        lhs.pages += rhs.pages; lhs.seams += rhs.seams; lhs.scored += rhs.scored; lhs.correct += rhs.correct
        lhs.wrong += rhs.wrong; lhs.skipped += rhs.skipped; lhs.unscored += rhs.unscored; lhs.stuck += rhs.stuck
        lhs.heightAbs += rhs.heightAbs; lhs.heightPages += rhs.heightPages
        lhs.offBy.merge(rhs.offBy, uniquingKeysWith: +)
    }

    var row: [String] {
        let histogram = offBy.keys.sorted().map { "\($0):\(offBy[$0]!)" }.joined(separator: " ")
        let off = offBy.values.reduce(0, +)
        return ["\(pages)", "\(seams)", "\(scored)", "\(correct)", off == 0 ? "0" : "\(off) (\(histogram))",
                "\(wrong)", "\(skipped)", "\(unscored)", "\(stuck)",
                pages == 1 ? heightErr.map(String.init) ?? "-" : "\(heightAbs)/\(heightPages)p"]
    }
}

@main struct ScrollCorpusRun {
    static func main() async throws {
        let arguments = CommandLine.arguments
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
        var rows: [[String]] = []
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
            total += tally
            groups[String(page.prefix { $0 != "-" }), default: Tally()] += tally
        }
        if groups.count > 1 { rows += groups.keys.sorted().map { ["TOTAL \($0)"] + groups[$0]!.row } }
        rows.append(["TOTAL"] + total.row)
        print("matcher \(arguments[3]), corpus \(corpus.path)")
        defer {
            if other != nil {
                print("compare \(arguments[3]) vs \(arguments[5]): seams both score \(common), correct \(commonCorrect.0) vs \(commonCorrect.1); "
                    + "jump-free pages with heights \(jumpFreePages), sum |heightErr| \(jumpFreeHeight.0) vs \(jumpFreeHeight.1)")
            }
        }
        let header = ["page", "pages", "seams", "scored", "correct", "off-by-N (N:count)", "wrong", "skipped", "unscored", "stuck", "heightErr"]
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
        func finishRun() async {
            guard let matcher else { return }
            tally.stuck += run.trailingNil
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
        tally.jumpFree = !truth.seams.contains { $0.truthKind != "unknown" && ($0.offset.map { abs($0) >= Int(crop.height) } ?? true) }
        if pageKnown { tally.heightErr = pageErr; tally.heightAbs = abs(pageErr); tally.heightPages = 1 }
        return tally
    }
}
