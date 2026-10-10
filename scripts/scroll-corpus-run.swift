// Scores Scrolling Capture matchers against a seam-truth corpus. The corpus
// holds private screen content and lives outside the repo: one folder per
// page with NNNN.png frames and truth.json
// {source, selection, ignoredTrailingColumns, frames:[{index,time}],
//  seams:[{from,to,offset|null,truthKind:"scrollY"|"manual"|"unknown"}]}.
// A seam offset means content moved up: to[y] == from[y + offset].
//
// swiftc -parse-as-library -default-isolation MainActor scripts/scroll-corpus-run.swift \
//   Screendrop/ScrollingCaptureStitcher.swift -o /tmp/scroll-corpus-run
// /tmp/scroll-corpus-run <corpus dir> --matcher r7
//
// Each frame with a seam from its predecessor is one seam to score. A frame
// without one starts a new run with a fresh matcher. A matcher's claim is
// judged against the summed seam offsets from the frame it compared with;
// any "unknown" seam on that path leaves the seam unscored. Placing a frame
// where truth says nothing fits (a known seam with a null offset, or a total
// at least the frame height) is wrong; returning nil there is correct.
// Pages are also totalled by name prefix (user-, fresh-) when there are several.
import CoreGraphics
import Foundation
import ImageIO

/// The new frame's content moved up by `offset` device pixels from run frame
/// `against`: new[y] == against[y + offset].
struct Claim { let against: Int; let offset: Int }

/// Sees one run's frames in order, the first at creation. nil: can't place it.
protocol CorpusMatcher: AnyObject { func place(_ frame: CGImage, index: Int) async -> Claim? }

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

    func place(_ frame: CGImage, index: Int) async -> Claim? {
        let base = await stitcher.stitchedHeight - frame.height
        let update = await stitcher.add(frame)
        guard update != .noMatch, let registration = await stitcher.registration else { return nil }
        let claim = Claim(against: reference, offset: registration.offset - base)
        if update == .appended { reference = index }
        return claim
    }
}

let matchers: [String: (_ first: CGImage, _ index: Int, _ ignoredTrailingColumns: Int) -> CorpusMatcher?] = [
    "r7": { R7Matcher(first: $0, index: $1, ignoredTrailingColumns: $2) },
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
    var pages = 0, seams = 0, scored = 0, correct = 0, wrong = 0, skipped = 0, unscored = 0
    var offBy: [Int: Int] = [:]

    static func += (lhs: inout Tally, rhs: Tally) {
        lhs.pages += rhs.pages; lhs.seams += rhs.seams; lhs.scored += rhs.scored; lhs.correct += rhs.correct
        lhs.wrong += rhs.wrong; lhs.skipped += rhs.skipped; lhs.unscored += rhs.unscored
        lhs.offBy.merge(rhs.offBy, uniquingKeysWith: +)
    }

    var row: [String] {
        let histogram = offBy.keys.sorted().map { "\($0):\(offBy[$0]!)" }.joined(separator: " ")
        let off = offBy.values.reduce(0, +)
        return ["\(pages)", "\(seams)", "\(scored)", "\(correct)", off == 0 ? "0" : "\(off) (\(histogram))",
                "\(wrong)", "\(skipped)", "\(unscored)"]
    }
}

@main struct ScrollCorpusRun {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, arguments[2] == "--matcher", let make = matchers[arguments[3]] else {
            print("usage: scroll-corpus-run <corpus dir> --matcher <\(matchers.keys.sorted().joined(separator: "|"))>")
            exit(2)
        }
        let corpus = URL(fileURLWithPath: arguments[1])
        let pages = try FileManager.default.contentsOfDirectory(atPath: corpus.path).sorted()
            .filter { FileManager.default.fileExists(atPath: corpus.appendingPathComponent("\($0)/truth.json").path) }
        var rows: [[String]] = []
        var total = Tally()
        var groups: [String: Tally] = [:]
        for page in pages {
            let folder = corpus.appendingPathComponent(page)
            let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: folder.appendingPathComponent("truth.json")))
            let tally = try await score(truth, folder: folder, make: make)
            rows.append([page] + tally.row)
            total += tally
            groups[String(page.prefix { $0 != "-" }), default: Tally()] += tally
        }
        if groups.count > 1 { rows += groups.keys.sorted().map { ["TOTAL \($0)"] + groups[$0]!.row } }
        rows.append(["TOTAL"] + total.row)
        print("matcher \(arguments[3]), corpus \(corpus.path)")
        let header = ["page", "pages", "seams", "scored", "correct", "off-by-N (N:count)", "wrong", "skipped", "unscored"]
        let table = [header] + rows
        let widths = header.indices.map { column in table.map { $0[column].count }.max()! }
        for row in table {
            print(row.indices.map { column in
                let pad = String(repeating: " ", count: widths[column] - row[column].count)
                return column == 0 ? row[column] + pad : pad + row[column]
            }.joined(separator: "  "))
        }
    }

    static func score(_ truth: Truth, folder: URL, make: (CGImage, Int, Int) -> CorpusMatcher?) async throws -> Tally {
        var tally = Tally(pages: 1)
        let seamInto = Dictionary(uniqueKeysWithValues: truth.seams.map { ($0.to, $0) })
        let crop = CGRect(x: truth.selection.columns[0], y: truth.selection.rows[0],
                          width: truth.selection.columns[1] - truth.selection.columns[0],
                          height: truth.selection.rows[1] - truth.selection.rows[0])
        var matcher: CorpusMatcher?
        for index in truth.frames.map(\.index).sorted() {
            let url = folder.appendingPathComponent(String(format: "%04d.png", index))
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let frame = image.cropping(to: crop) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]) }
            guard let seam = seamInto[index] else {
                matcher = make(frame, index, truth.ignoredTrailingColumns)
                continue
            }
            tally.seams += 1
            guard let claim = await matcher?.place(frame, index: index) else {
                if seam.truthKind == "unknown" { tally.unscored += 1; continue }
                tally.scored += 1
                // Where nothing fits, refusing is the right answer.
                if seam.offset.map({ abs($0) >= frame.height }) ?? true { tally.correct += 1 } else { tally.skipped += 1 }
                continue
            }
            // Walk back along the run to the frame the matcher compared with.
            var path: [Truth.Seam] = []
            var at = index
            while at != claim.against {
                guard let step = seamInto[at], step.from < at else { fatalError("\(folder.lastPathComponent): claim against \(claim.against) left the run at \(index)") }
                path.append(step)
                at = step.from
            }
            if path.contains(where: { $0.truthKind == "unknown" }) { tally.unscored += 1; continue }
            tally.scored += 1
            let offsets = path.map(\.offset)
            let total: Int? = offsets.contains(nil) ? nil : offsets.reduce(0) { $0 + $1! }
            guard let expected = total, abs(expected) < frame.height else { tally.wrong += 1; continue }
            let error = abs(claim.offset - expected)
            let wrongSign = claim.offset != 0 && expected != 0 && (claim.offset > 0) != (expected > 0)
            if error == 0 { tally.correct += 1 }
            else if error <= 3 && !wrongSign { tally.offBy[error, default: 0] += 1 }
            else { tally.wrong += 1 }
        }
        return tally
    }
}
