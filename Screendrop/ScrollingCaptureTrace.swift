import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Opt-in frame dump (`defaults write com.tommyent.Sukusho ScrollingCaptureTrace -bool YES`).
/// Each capture writes a new folder in Caches/Screendrop/ScrollingCaptureFrames, laid out as a
/// corpus page (scripts/scroll-corpus-run.swift): NNNN.png, the selection crop the stitcher sees
/// at full resolution; page.json with the selection and ignored trailing columns; and
/// frames.jsonl, one line per frame: index, time (mach seconds), reference (the frame it was
/// compared with), candidateOffset (Vision's) and verifiedOffset (the verifier's; null when it
/// wasn't placed), both against the reference, and action (the stitcher's placement). Adding
/// truth.json makes the folder a corpus page. It holds screen content: local only, owner-only
/// permissions.
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
    func write(index: Int, time: TimeInterval, frame: CGImage?, reference: Int? = nil, candidateOffset: Int? = nil,
               verifiedOffset: Int?, action: String) {
        queue.async { [folder, lines] in
            if let frame, let png = CGImageDestinationCreateWithURL(folder.appendingPathComponent(
                String(format: "%04d.png", index)) as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(png, frame, nil)
                CGImageDestinationFinalize(png)
            }
            func json(_ value: Int?) -> String { value.map(String.init) ?? "null" }
            lines.write(Data((#"{"index":\#(index),"time":\#(time),"reference":\#(json(reference)),"#
                + #""candidateOffset":\#(json(candidateOffset)),"verifiedOffset":\#(json(verifiedOffset)),"action":"\#(action)"}"#
                + "\n").utf8))
        }
    }
}
