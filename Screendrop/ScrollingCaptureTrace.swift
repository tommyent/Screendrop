import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Opt-in frame dump (`defaults write com.fayazahmed.Screendrop ScrollingCaptureTrace -bool YES`).
/// Each part writes a new folder in Caches/Screendrop/ScrollingCaptureFrames, laid out as a
/// corpus page (scripts/scroll-corpus-run.swift): NNNN.png, the selection crop R7 sees at full
/// resolution; page.json with the selection and ignored trailing columns; and frames.jsonl, one
/// line per frame: index, time (mach seconds), candidateOffset (null: no estimator yet),
/// verifiedOffset (the output row R7 put the frame's top at, so a seam is the difference of two
/// frames' values; null when R7 didn't place it) and action (the engine's state). A waiting
/// frame that an idle tick decides is lost gets a second line. Adding truth.json makes the folder
/// a corpus page. It holds screen content: local only, owner-only permissions.
nonisolated final class ScrollingCaptureFrameDump: Sendable {
    private let folder: URL
    private let lines: FileHandle
    private let queue = DispatchQueue(label: "ScrollingCaptureFrameDump", qos: .utility)

    init?(width: Int, height: Int, ignoredTrailingColumns: Int) {
        guard UserDefaults.standard.bool(forKey: "ScrollingCaptureTrace"),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        folder = caches.appendingPathComponent("Screendrop/ScrollingCaptureFrames/"
            + Date.now.formatted(.iso8601.dateSeparator(.dash).timeSeparator(.omitted)) + "-" + UUID().uuidString.prefix(8))
        let page = #"{"selection":{"columns":[0,\#(width)],"rows":[0,\#(height)]},"ignoredTrailingColumns":\#(ignoredTrailingColumns)}"#
        let jsonl = folder.appendingPathComponent("frames.jsonl")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                  attributes: [.posixPermissions: 0o700])) != nil,
              (try? Data(page.utf8).write(to: folder.appendingPathComponent("page.json"))) != nil,
              FileManager.default.createFile(atPath: jsonl.path, contents: nil),
              let lines = try? FileHandle(forWritingTo: jsonl) else { return nil }
        self.lines = lines
    }

    // ponytail: no queue or disk budget; it's an opt-in diagnostic, turn it off when done.
    func write(index: Int, time: TimeInterval, frame: CGImage?, verifiedOffset: Int?, action: String) {
        queue.async { [folder, lines] in
            if let frame, let png = CGImageDestinationCreateWithURL(folder.appendingPathComponent(
                String(format: "%04d.png", index)) as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(png, frame, nil)
                CGImageDestinationFinalize(png)
            }
            let offset = verifiedOffset.map(String.init) ?? "null"
            lines.write(Data((#"{"index":\#(index),"time":\#(time),"candidateOffset":null,"verifiedOffset":\#(offset),"action":"\#(action)"}"# + "\n").utf8))
        }
    }
}
