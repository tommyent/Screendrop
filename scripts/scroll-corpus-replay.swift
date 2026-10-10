// Replays corpus pages through the app's wired path, ScrollingCaptureFeed
// (crop, Vision, verifier, stitcher, frame dump), and prints each frame's
// placement and the keeps-changing hint. With the frame dump on, each run's dump plus the
// page's truth.json scores in scroll-corpus-run.swift as the page itself does.
//
// swiftc -parse-as-library -default-isolation MainActor scripts/scroll-corpus-replay.swift \
//   Screendrop/ScrollingCapture{Feed,FrameStitcher,Raster,Region,Stream,Trace}.swift \
//   Screendrop/ScrollingCaptureOffset{Estimator,Verifier}.swift -o /tmp/scroll-corpus-replay
// /tmp/scroll-corpus-replay <corpus page dir> [-ScrollingCaptureTrace YES]
import CoreGraphics
import Foundation
import ImageIO

@main struct ScrollCorpusReplay {
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        func object(_ name: String) -> [String: Any] {
            (try? Data(contentsOf: folder.appendingPathComponent(name)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        let truth = object("truth.json").merging(object("page.json")) { fromTruth, _ in fromTruth }
        let selection = truth["selection"] as! [String: [Int]]
        let output = ScrollingCaptureOutputRect(columns: selection["columns"]![0]..<selection["columns"]![1],
                                                rows: selection["rows"]![0]..<selection["rows"]![1])
        let trailing = truth["ignoredTrailingColumns"] as! Int
        let into = Set((truth["seams"] as! [[String: Any]]).map { $0["to"] as! Int })
        var feed: ScrollingCaptureFeed?
        for index in (truth["frames"] as! [[String: Any]]).map({ $0["index"] as! Int }).sorted() {
            let url = folder.appendingPathComponent(String(format: "%04d.png", index))
            let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
            guard into.contains(index), let running = feed else {
                feed = ScrollingCaptureFeed(firstFrame: image, at: Double(index), selection: output,
                                            ignoredTrailingColumns: trailing)
                print(index, "first")
                continue
            }
            let update = await running.add(image, at: Double(index))
            print(index, update.placement, "height", update.height, update.keepsChanging ? "keeps-changing" : "")
        }
        try await Task.sleep(for: .seconds(2)) // the dump writes on its own queue
    }
}
