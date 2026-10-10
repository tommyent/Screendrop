import CoreGraphics
import Compression
import Foundation
import Darwin

/// All stage times use mach absolute time in seconds, including SCK displayTime.
nonisolated struct ScrollingCaptureSampleTiming: Codable, Equatable, Sendable {
    var sequence: Int? = nil
    var displayTime: TimeInterval? = nil
    var callbackTime: TimeInterval? = nil
    var engineEnqueued: TimeInterval? = nil
    var droppedSinceLast: Int? = nil
    var status: Int? = nil
    var captureRequested: TimeInterval? = nil
    var captureReturned: TimeInterval? = nil
    var sleepRequested: TimeInterval? = nil
    var sleepReturned: TimeInterval? = nil
    var stages: [String: TimeInterval] = [:]

    static func now() -> TimeInterval { Double(mach_absolute_time()) * secondsPerTick }
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
}

/// Serial, bounded diagnostics; capture never waits for compression, statistics or disk.
nonisolated final class ScrollingCaptureTraceWriter: @unchecked Sendable {
    struct Sample: Sendable {
        let index: Int
        let time: TimeInterval
        let old: ScrollingCaptureRaster
        let frame: ScrollingCaptureRaster
        let viewport: Range<Int>
        let contentRows: Range<Int>?
        let engine: String
        let state: String
        let height: Int
        let events: [String]
        let recoveryAttempt: Bool
        let recoveryRows: Range<Int>?
        let recoveryPatch: ScrollingCaptureRaster?
        var timing: ScrollingCaptureSampleTiming
    }

    private let queue = DispatchQueue(label: "Sukusho.scrollTrace", qos: .utility)
    private let lock = NSLock()
    private let maximumQueuedBytes: Int
    private var queuedBytes = 0 // lock-protected; all other mutable state is queue-confined.
    private var omissions: (count: Int, index: Int, state: String)?
    private var trace: ScrollingCaptureTrace?
    private var previousState: String?

    init(first: ScrollingCaptureRaster, selection: ScrollingCaptureOutputRect,
         ignoredTrailingColumns: Int, maximumHeight: Int, colorSpace: CGColorSpace,
         directory: URL, maximumQueuedBytes: Int = 128 * 1024 * 1024) {
        self.maximumQueuedBytes = maximumQueuedBytes
        let profile = colorSpace.copyICCData() as Data?
        queuedBytes = first.byteCount
        queue.async {
            defer { self.release(first.byteCount) }
            do {
                let space = profile.flatMap { CGColorSpace(iccData: $0 as CFData) }
                    ?? CGColorSpace(name: CGColorSpace.sRGB)!
                self.trace = try ScrollingCaptureTrace(first: first, selection: selection,
                    ignoredTrailingColumns: ignoredTrailingColumns, maximumHeight: maximumHeight,
                    colorSpace: space, directory: directory)
            } catch { NSLog("Scrolling Capture trace could not start: %@", error.localizedDescription) }
        }
    }

    func append(_ sample: Sample) {
        let bytes = sample.old.byteCount + sample.frame.byteCount + (sample.recoveryPatch?.byteCount ?? 0)
        guard reserve(bytes) else {
            omit(index: sample.index, state: sample.state)
            return
        }
        queue.async {
            defer { self.release(bytes) }
            guard self.trace != nil else { return }
            guard self.trace!.document.omittedSamples == 0 else {
                self.trace?.omit(index: sample.index, state: sample.state)
                self.saveTransition(sample.state)
                return
            }
            do {
                var timing = sample.timing
                timing.stages["traceStarted"] = ScrollingCaptureSampleTiming.now()
                timing.stages["rowStatsStarted"] = ScrollingCaptureSampleTiming.now()
                let stats = ScrollingCaptureTrace.differences(from: sample.old, to: sample.frame, rows: sample.viewport)
                timing.stages["rowStatsFinished"] = ScrollingCaptureSampleTiming.now()
                timing.stages["compressionStarted"] = ScrollingCaptureSampleTiming.now()
                let prior = self.trace!.document.records.last?.input ?? self.trace!.document.first
                let input = sample.old.pixels == sample.frame.pixels && prior.columns == sample.frame.matchingColumns
                    ? prior : try ScrollingCaptureTrace.Raster(sample.frame)
                let patch = try sample.recoveryPatch.map(ScrollingCaptureTrace.Raster.init)
                timing.stages["compressionFinished"] = ScrollingCaptureSampleTiming.now()
                self.trace?.append(.init(index: sample.index, time: sample.time, input: input,
                    viewport: sample.viewport, contentRows: sample.contentRows,
                    matchingColumns: sample.frame.matchingColumns, engine: sample.engine, state: sample.state,
                    height: sample.height, events: sample.events, recoveryAttempt: sample.recoveryAttempt,
                    recoveryRows: sample.recoveryRows, recoveryPatch: patch, bestShift: stats.shift,
                    changedInPlace: stats.changed, maximumChannelDifference: stats.difference, timing: timing))
            } catch { self.trace?.omit(index: sample.index, state: sample.state) }
            self.saveTransition(sample.state)
        }
    }

    func noteTiming(_ timing: ScrollingCaptureSampleTiming) {
        guard reserve(4096) else { return }
        queue.async {
            defer { self.release(4096) }
            self.trace?.noteTiming(timing)
        }
    }

    func finish(at time: TimeInterval, output: ScrollingCaptureRaster? = nil) {
        let bytes = output?.byteCount ?? 0
        let done = output != nil
        if reserve(bytes) {
            queue.async {
                defer { self.release(bytes) }
                self.trace?.save(done: done, output: output, endedAt: time)
            }
        } else {
            queue.async { self.trace?.save(done: done, endedAt: time) }
        }
    }

    func document() async -> ScrollingCaptureTrace.Document? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.trace?.document) }
        }
    }

    private func saveTransition(_ state: String) {
        if (state == "lost" || state == "limit"), state != previousState { trace?.save() }
        previousState = state
    }
    private func omit(index: Int, state: String) {
        let schedule = lock.withLock {
            let empty = omissions == nil
            let failure = omissions?.state == "lost" || state == "lost" ? "lost"
                : omissions?.state == "limit" || state == "limit" ? "limit" : state
            omissions = ((omissions?.count ?? 0) + 1, index, failure)
            return empty
        }
        guard schedule else { return }
        queue.async {
            let omitted = self.lock.withLock { let value = self.omissions; self.omissions = nil; return value }
            if let omitted {
                self.trace?.omit(index: omitted.index, state: omitted.state, count: omitted.count)
                self.saveTransition(omitted.state)
            }
        }
    }
    private func reserve(_ bytes: Int) -> Bool {
        lock.withLock {
            guard bytes <= maximumQueuedBytes - queuedBytes else { return false }
            queuedBytes += bytes
            return true
        }
    }
    private func release(_ bytes: Int) { lock.withLock { queuedBytes -= bytes } }
}

/// Opt-in, local-only diagnostics. Pixels outside matchingColumns remain in the
/// input: R7 discovers its own gutters, and Done also needs these output pixels.
nonisolated struct ScrollingCaptureTrace {
    struct Raster: Codable, Equatable, Sendable {
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

    struct Record: Codable, Equatable, Sendable {
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
        var timing: ScrollingCaptureSampleTiming? = nil
    }

    struct Document: Codable, Sendable {
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
        var savedAfterStall: Bool? = nil
        var endedAt: TimeInterval? = nil
        var outputChecksum: UInt64?
        var writeTimings: [[String: TimeInterval]]? = nil
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
        var record = record
        sawLoss = sawLoss || record.state == "lost" || record.state == "limit"
        // Keep a complete prefix, never present a truncated session as replayable.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        record.timing?.stages["recordEncodeStarted"] = ScrollingCaptureSampleTiming.now()
        let size = (try? encoder.encode(record).count) ?? maximumBytes
        record.timing?.stages["recordEncodeFinished"] = ScrollingCaptureSampleTiming.now()
        record.timing?.stages["traceFinished"] = ScrollingCaptureSampleTiming.now()
        if document.omittedSamples == 0, document.records.count < 4096,
           retainedBytes + size + 4096 < maximumBytes {
            document.records.append(record)
            retainedBytes += size
        } else {
            document.omittedSamples += 1
            document.lastOmittedEvent = "sample \(record.index): \(record.state); \(record.events.joined(separator: "; "))"
        }
    }

    mutating func omit(index: Int, state: String, count: Int = 1) {
        sawLoss = sawLoss || state == "lost" || state == "limit"
        document.omittedSamples += count
        document.lastOmittedEvent = "sample \(index): traceQueueFull"
    }

    mutating func noteTiming(_ timing: ScrollingCaptureSampleTiming) {
        guard let last = document.records.indices.last else { return }
        var current = document.records[last].timing ?? .init()
        if let sequence = timing.sequence, sequence != current.sequence { return }
        current.stages.merge(timing.stages) { _, new in new }
        document.records[last].timing = current
    }

    mutating func save(done: Bool = false, output: ScrollingCaptureRaster? = nil, endedAt: TimeInterval? = nil) {
        let stalled = endedAt.map { self.stalled(at: $0) } ?? false
        guard sawLoss || stalled else { return }
        do {
            document.savedAfterLoss = sawLoss
            document.savedOnDone = document.savedOnDone || done
            if stalled { document.savedAfterStall = true }
            if let endedAt { document.endedAt = endedAt }
            if done { document.outputChecksum = output.map(Self.checksum) }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            var times = ["fileEncodeStarted": ScrollingCaptureSampleTiming.now(), "fileEncodeFinished": 0,
                         "fileWriteStarted": 0, "fileWriteFinished": 0]
            if document.writeTimings == nil { document.writeTimings = [] }
            if document.writeTimings!.count == 4096 { document.writeTimings!.removeFirst() }
            document.writeTimings!.append(times)
            let data = try encoder.encode(document)
            times["fileEncodeFinished"] = ScrollingCaptureSampleTiming.now()
            let timingSize = try encoder.encode(document.writeTimings!).count
            guard data.count + timingSize <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            let files = FileManager.default
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let old = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
                .filter { $0.pathExtension == "scrolltrace" && $0.lastPathComponent != fileName }
                .map { url in
                    let info = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let timingSize = (try? url.appendingPathExtension("timing").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return (url: url, date: info.contentModificationDate ?? .distantPast, size: (info.fileSize ?? 0) + timingSize)
                }.sorted { $0.date < $1.date }
            var total = data.count + timingSize + old.reduce(0) { $0 + $1.size }
            for file in old where total > maximumBytes * 4 || file.date < Date().addingTimeInterval(-7 * 86400) {
                total -= file.size
                try files.removeItem(at: file.url)
                try? files.removeItem(at: file.url.appendingPathExtension("timing"))
            }
            let url = directory.appendingPathComponent(fileName)
            times["fileWriteStarted"] = ScrollingCaptureSampleTiming.now()
            try data.write(to: url, options: [.atomic])
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            times["fileWriteFinished"] = ScrollingCaptureSampleTiming.now()
            document.writeTimings![document.writeTimings!.count - 1] = times
            // The final write cannot contain its own end time; keep a small private companion.
            let measurements = try encoder.encode(document.writeTimings!)
            guard measurements.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            let timingURL = url.appendingPathExtension("timing")
            try measurements.write(to: timingURL, options: [.atomic])
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: timingURL.path)
        } catch {
            NSLog("Scrolling Capture trace could not be saved: %@", error.localizedDescription)
        }
    }

    private func stalled(at time: TimeInterval) -> Bool {
        guard time.isFinite, let first = document.records.first else { return false }
        var progressTime = first.timing?.stages["idleObserved"] ?? first.time
        var height = document.selectionRows.count
        var pending = false
        for record in document.records {
            if record.state == "appended" || record.height != height {
                progressTime = record.timing?.stages["idleObserved"] ?? record.time
                pending = false
            } else if record.state == "pending" {
                pending = true
            }
            height = record.height
        }
        return pending && time - progressTime >= 3
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
            if old.sameRow(y + shift, as: new, at: y) { difference.append(0); continue }
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
