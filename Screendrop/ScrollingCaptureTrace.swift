import CoreGraphics
import Compression
import Foundation

/// Opt-in, local-only diagnostics. Pixels outside matchingColumns remain in the
/// input: R7 discovers its own gutters, and Done also needs these output pixels.
nonisolated struct ScrollingCaptureTrace {
    struct Raster: Codable, Equatable {
        let width: Int
        let height: Int
        let columns: [Range<Int>]
        let bgraLZFSE: Data

        init(_ frame: ScrollingCaptureRaster) throws {
            guard frame.pixels.count * 4 <= 128 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            width = frame.width; height = frame.height; columns = frame.matchingColumns
            bgraLZFSE = try (frame.pixels.withUnsafeBytes { Data($0) } as NSData).compressed(using: .lzfse) as Data
        }

        func decoded() throws -> ScrollingCaptureRaster {
            guard width > 0, height > 0, width <= 16_384, height <= 16_384,
                  width * height * 4 <= 128 * 1024 * 1024 else { throw CocoaError(.coderReadCorrupt) }
            var pixels = [UInt32](repeating: 0, count: width * height)
            guard !bgraLZFSE.isEmpty else { throw CocoaError(.coderReadCorrupt) }
            let count = pixels.withUnsafeMutableBytes { output in bgraLZFSE.withUnsafeBytes { input in
                compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, output.count,
                    input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZFSE)
            } }
            guard count == width * height * 4 else { throw CocoaError(.coderReadCorrupt) }
            guard let frame = ScrollingCaptureRaster(width: width, height: height, pixels: pixels, matchingColumns: columns)
            else { throw CocoaError(.coderReadCorrupt) }
            return frame
        }
    }

    struct Record: Codable, Equatable {
        let index: Int
        let time: TimeInterval
        let input: Raster
        let viewport: Range<Int>
        let contentRows: Range<Int>?
        let matchingColumns: [Range<Int>]
        let engine: String
        let state: String
        let height: Int
        let events: [String]
        let recoveryAttempt: Bool
        let recoveryRows: Range<Int>?
        let recoveryPatch: Raster?
        let bestShift: Int?
        let changedInPlace: Data
        let maximumChannelDifference: Data
    }

    struct Document: Codable {
        let version: Int
        let selectionColumns: Range<Int>
        let selectionRows: Range<Int>
        let ignoredTrailingColumns: Int
        let maximumHeight: Int
        let colorProfile: Data?
        let first: Raster
        var records: [Record] = []
        var omittedSamples = 0
        var lastOmittedEvent: String?
        var savedAfterLoss = false
        var savedOnDone = false
        var outputChecksum: UInt64?
    }

    static var defaultDirectory: URL? {
        guard UserDefaults.standard.bool(forKey: "ScrollingCaptureTrace"),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent("Sukusho/ScrollingCaptureTraces", isDirectory: true)
    }

    private(set) var document: Document
    private let directory: URL
    private let fileName = UUID().uuidString + ".scrolltrace"
    private let maximumBytes: Int
    private var retainedBytes: Int
    private var sawLoss = false

    init(first: ScrollingCaptureRaster, selection: ScrollingCaptureOutputRect,
         ignoredTrailingColumns: Int, maximumHeight: Int, colorSpace: CGColorSpace,
         directory: URL, maximumBytes: Int = 64 * 1024 * 1024) throws {
        let input = try Raster(first)
        self.directory = directory
        self.maximumBytes = maximumBytes
        retainedBytes = input.bgraLZFSE.count + 4096
        guard retainedBytes < maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        document = Document(version: 1, selectionColumns: selection.columns, selectionRows: selection.rows,
            ignoredTrailingColumns: ignoredTrailingColumns, maximumHeight: maximumHeight,
            colorProfile: colorSpace.copyICCData() as Data?, first: input)
    }

    mutating func append(_ record: Record) {
        sawLoss = sawLoss || record.state == "lost" || record.state == "limit"
        // Keep a complete prefix, never present a truncated session as replayable.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let size = (try? encoder.encode(record).count) ?? maximumBytes
        if document.omittedSamples == 0, document.records.count < 4096,
           retainedBytes + size + 4096 < maximumBytes {
            document.records.append(record)
            retainedBytes += size
        } else {
            document.omittedSamples += 1
            document.lastOmittedEvent = "sample \(record.index): \(record.state); \(record.events.joined(separator: "; "))"
        }
    }

    mutating func save(done: Bool = false, output: ScrollingCaptureRaster? = nil) {
        guard sawLoss else { return }
        do {
            document.savedAfterLoss = true
            document.savedOnDone = document.savedOnDone || done
            if let output { document.outputChecksum = Self.checksum(output) }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(document)
            guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            let files = FileManager.default
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let old = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
                .filter { $0.pathExtension == "scrolltrace" && $0.lastPathComponent != fileName }
                .map { url in
                    let info = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    return (url: url, date: info.contentModificationDate ?? .distantPast, size: info.fileSize ?? 0)
                }.sorted { $0.date < $1.date }
            var total = data.count + old.reduce(0) { $0 + $1.size }
            for file in old where total > maximumBytes * 4 || file.date < Date().addingTimeInterval(-7 * 86400) {
                total -= file.size
                try files.removeItem(at: file.url)
            }
            let url = directory.appendingPathComponent(fileName)
            try data.write(to: url, options: [.atomic])
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Scrolling Capture trace could not be saved: %@", error.localizedDescription)
        }
    }

    static func read(_ url: URL) throws -> Document {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let document = try PropertyListDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1, document.records.count <= 4096 else { throw CocoaError(.coderReadCorrupt) }
        return document
    }

    static func checksum(_ raster: ScrollingCaptureRaster) -> UInt64 {
        raster.pixels.reduce(UInt64(raster.width) << 32 | UInt64(raster.height)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    /// Diagnostic only: this best exact-row shift never supplies registration authority.
    static func differences(from old: ScrollingCaptureRaster, to new: ScrollingCaptureRaster,
                            rows: Range<Int>) -> (shift: Int?, changed: Data, difference: Data) {
        guard old.width == new.width, old.height == new.height, rows.lowerBound >= 0, rows.upperBound <= new.height,
              let old = old.using(columns: new.matchingColumns) else {
            return (nil, Data(), Data())
        }
        var oldRows: [Int: [Int]] = [:], votes: [Int: Set<Int>] = [:]
        for y in rows where !old.isBlank(y) { oldRows[old.rowHash(y), default: []].append(y) }
        for y in rows where !new.isBlank(y) {
            for oldY in oldRows[new.rowHash(y), default: []] where old.sameRow(oldY, as: new, at: y) {
                votes[oldY - y, default: []].insert(new.rowHash(y))
            }
        }
        let maximum = votes.values.map(\.count).max() ?? 0
        let best = votes.filter { $0.value.count == maximum }.keys
        let shift = best.count == 1 ? best.first : nil
        var changed = Data(), difference = Data()
        for y in 0..<new.height {
            changed.append(old.sameRow(y, as: new, at: y) ? 0 : 1)
            guard let shift, (0..<old.height).contains(y + shift) else { difference.append(255); continue }
            var largest = 0
            for columns in new.matchingColumns { for x in columns {
                let a = old.pixels[(y + shift) * old.width + x], b = new.pixels[y * new.width + x]
                for channel in stride(from: 0, through: 24, by: 8) {
                    largest = max(largest, abs(Int((a >> channel) & 255) - Int((b >> channel) & 255)))
                }
            } }
            difference.append(UInt8(largest))
        }
        return (shift, changed, difference)
    }
}
