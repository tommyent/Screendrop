import CoreGraphics
import Compression
import Foundation
import Darwin

/// Capture geometry in display-local top-left points, matching SCStreamConfiguration.sourceRect.
nonisolated struct ScrollingCaptureTraceGeometry: Codable, Equatable, Sendable {
    struct Obstacle: Codable, Equatable, Sendable {
        let frame: CGRect
        let layer: Int
    }
    let displayID: UInt32
    let selection: CGRect
    let matchingRect: CGRect
    let targetWindowFrame: CGRect?
    let targetWindowLayer: Int?
    let reason: String
    let obstacles: [Obstacle]
}

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
        let state: String
        let height: Int
        let events: [String]
        var timing: ScrollingCaptureSampleTiming
        var scrollInput: ScrollingCaptureScrollInput.Snapshot? = nil
    }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private let maximumQueuedBytes: Int
    private var queuedBytes = 0 // lock-protected; all other mutable state is queue-confined.
    private var omissions: (ranges: [Range<Int>], state: String)?
    private var pending: [(sample: Sample, bytes: Int)] = []
    private var draining = false
    private var trace: ScrollingCaptureTrace?
    private var previousState: String?

    init(first: ScrollingCaptureRaster, selection: ScrollingCaptureOutputRect,
         ignoredTrailingColumns: Int, maximumHeight: Int, colorSpace: CGColorSpace,
         directory: URL, maximumQueuedBytes: Int = 128 * 1024 * 1024,
         queue: DispatchQueue = DispatchQueue(label: "Sukusho.scrollTrace", qos: .utility),
         geometry: ScrollingCaptureTraceGeometry? = nil, scrollInputAtStart: ScrollingCaptureScrollInput.Snapshot? = nil) {
        self.queue = queue
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
                    colorSpace: space, directory: directory, geometry: geometry, scrollInputAtStart: scrollInputAtStart)
            } catch { NSLog("Scrolling Capture trace could not start: %@", error.localizedDescription) }
        }
    }

    func append(_ sample: Sample) {
        let bytes = sample.old.byteCount + sample.frame.byteCount
        let schedule = lock.withLock {
            while bytes <= maximumQueuedBytes, bytes > maximumQueuedBytes - queuedBytes, !pending.isEmpty {
                let old = pending.removeFirst()
                queuedBytes -= old.bytes
                omitLocked(index: old.sample.index, state: old.sample.state)
            }
            if bytes <= maximumQueuedBytes - queuedBytes {
                queuedBytes += bytes
                pending.append((sample, bytes))
            } else { omitLocked(index: sample.index, state: sample.state) }
            if draining { return false }
            draining = true
            return true
        }
        if schedule { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            let next = lock.withLock { () -> (sample: Sample, bytes: Int)? in
                guard !pending.isEmpty else { draining = false; return nil }
                return pending.removeFirst()
            }
            let omittedFailure = flushOmissions()
            guard let next else { if omittedFailure { trace?.save() }; return }
            process(next.sample, bytes: next.bytes, saveAfterOmission: omittedFailure)
        }
    }

    private func process(_ sample: Sample, bytes: Int, saveAfterOmission: Bool) {
        defer { release(bytes) }
        guard trace != nil else { return }
        do {
            var timing = sample.timing
            timing.stages["traceStarted"] = ScrollingCaptureSampleTiming.now()
            timing.stages["compressionStarted"] = ScrollingCaptureSampleTiming.now()
            let prior = self.trace!.document.records.last?.input ?? self.trace!.document.first
            let contiguous = (self.trace!.document.records.last?.index ?? 0) == sample.index - 1
            let input = contiguous && sample.old.pixels == sample.frame.pixels && prior.columns == sample.frame.matchingColumns
                ? prior : try ScrollingCaptureTrace.Raster(sample.frame)
            timing.stages["compressionFinished"] = ScrollingCaptureSampleTiming.now()
            self.trace?.append(.init(index: sample.index, time: sample.time, input: input, state: sample.state,
                height: sample.height, events: sample.events, timing: timing, scrollInput: sample.scrollInput))
        } catch { self.trace?.omit(index: sample.index, state: sample.state) }
        self.saveTransition(sample.state, force: saveAfterOmission)
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

    private func saveTransition(_ state: String, force: Bool = false) {
        if force || ((state == "lost" || state == "limit") && state != previousState) { trace?.save() }
        previousState = state
    }
    private func omitLocked(index: Int, state: String) {
        let failure = omissions?.state == "lost" || state == "lost" ? "lost"
            : omissions?.state == "limit" || state == "limit" ? "limit" : state
        var ranges = omissions?.ranges ?? []
        if let last = ranges.last, last.upperBound == index { ranges[ranges.count - 1] = last.lowerBound..<(index + 1) }
        else { ranges.append(index..<(index + 1)) }
        omissions = (ranges, failure)
    }
    private func flushOmissions() -> Bool {
        let omitted = lock.withLock { let value = omissions; omissions = nil; return value }
        guard let omitted else { return false }
        for range in omitted.ranges { trace?.omit(index: range.upperBound - 1, state: omitted.state, count: range.count) }
        return omitted.state == "lost" || omitted.state == "limit"
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
        /// The frame R7 was given, with its matching columns.
        let input: Raster
        let state: String
        let height: Int
        /// R7's result and what the engine decided.
        let events: [String]
        var timing: ScrollingCaptureSampleTiming? = nil
        /// The scroll input the engine decided with; absent in older traces.
        var scrollInput: ScrollingCaptureScrollInput.Snapshot? = nil
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
        var omittedRanges: [Range<Int>]? = nil
        var lastOmittedEvent: String?
        var savedAfterLoss = false
        var savedOnDone = false
        var savedAfterStall: Bool? = nil
        var endedAt: TimeInterval? = nil
        var outputChecksum: UInt64?
        var writeTimings: [[String: TimeInterval]]? = nil
        var geometry: ScrollingCaptureTraceGeometry? = nil
        /// The scroll input when this part began; a part's first decisions depend on it.
        var scrollInputAtStart: ScrollingCaptureScrollInput.Snapshot? = nil
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
    private var recordSizes: [Int] = []
    private var sawLoss = false
    /// After the first loss, this many more records are kept; then the history
    /// freezes, so the lost frames that follow never evict the failure itself.
    private static let recordsAfterLoss = 6
    private var keptAfterLoss: Int?
    private var progressTime: TimeInterval?
    private var progressHeight: Int?
    private var pendingSinceProgress = false

    init(first: ScrollingCaptureRaster, selection: ScrollingCaptureOutputRect,
         ignoredTrailingColumns: Int, maximumHeight: Int, colorSpace: CGColorSpace,
         directory: URL, maximumBytes: Int = 64 * 1024 * 1024,
         geometry: ScrollingCaptureTraceGeometry? = nil,
         scrollInputAtStart: ScrollingCaptureScrollInput.Snapshot? = nil) throws {
        let input = try Raster(first)
        self.directory = directory
        self.maximumBytes = maximumBytes
        retainedBytes = input.bgraLZFSE.count + 4096
        guard retainedBytes < maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        document = Document(version: 1, selectionColumns: selection.columns, selectionRows: selection.rows,
            ignoredTrailingColumns: ignoredTrailingColumns, maximumHeight: maximumHeight,
            colorProfile: colorSpace.copyICCData() as Data?, first: input)
        document.geometry = geometry
        document.scrollInputAtStart = scrollInputAtStart
    }

    mutating func append(_ record: Record) {
        var record = record
        sawLoss = sawLoss || record.state == "lost" || record.state == "limit"
        let observed = record.timing?.stages["idleObserved"] ?? record.time
        if progressTime == nil { progressTime = observed }
        if record.state == "appended" || record.height != (progressHeight ?? document.selectionRows.count) {
            progressTime = observed
            pendingSinceProgress = false
        } else if record.state == "pending" { pendingSinceProgress = true }
        progressHeight = record.height
        // Keep recent exact inputs; explicit gaps make a truncated session uncertifiable.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        record.timing?.stages["recordEncodeStarted"] = ScrollingCaptureSampleTiming.now()
        let size = (try? encoder.encode(record).count) ?? maximumBytes
        record.timing?.stages["recordEncodeFinished"] = ScrollingCaptureSampleTiming.now()
        record.timing?.stages["traceFinished"] = ScrollingCaptureSampleTiming.now()
        if document.first.bgraLZFSE.count + size + 8192 < maximumBytes {
            if let kept = keptAfterLoss {
                guard kept < Self.recordsAfterLoss, document.records.count < 4096,
                      retainedBytes + size + 4096 < maximumBytes else {
                    return omit(index: record.index, state: record.state, reason: "traceFrozenAfterLoss")
                }
                keptAfterLoss = kept + 1
            }
            // Until the first loss, the newest records stay, with room for the few after it.
            while keptAfterLoss == nil, !document.records.isEmpty,
                  document.records.count + Self.recordsAfterLoss >= 4096
                    || retainedBytes + size * (1 + Self.recordsAfterLoss) + 4096 >= maximumBytes {
                let old = document.records.removeFirst()
                retainedBytes -= recordSizes.removeFirst()
                omit(index: old.index, state: old.state, reason: "traceHistoryFull")
            }
            document.records.append(record)
            recordSizes.append(size)
            retainedBytes += size
        } else {
            omit(index: record.index, state: record.state, reason: "traceRecordTooLarge")
        }
        if sawLoss, keptAfterLoss == nil { keptAfterLoss = 0 }
    }

    mutating func omit(index: Int, state: String, count: Int = 1, reason: String = "traceQueueFull") {
        sawLoss = sawLoss || state == "lost" || state == "limit"
        // A loss dropped before it reached the history still freezes it; history
        // evicted to make room for a recorded loss doesn't.
        if state == "lost" || state == "limit", keptAfterLoss == nil { keptAfterLoss = 0 }
        document.omittedSamples += count
        document.lastOmittedEvent = "sample \(index): \(reason)"
        var merged: [Range<Int>] = []
        for range in ((document.omittedRanges ?? []) + [(index - count + 1)..<(index + 1)])
            .sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, last.upperBound >= range.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        document.omittedRanges = merged
    }

    mutating func noteTiming(_ timing: ScrollingCaptureSampleTiming) {
        guard let last = document.records.lastIndex(where: { timing.sequence == nil || $0.timing?.sequence == timing.sequence })
        else { return }
        var current = document.records[last].timing ?? .init()
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
        guard time.isFinite, let progressTime else { return false }
        return pendingSinceProgress && time - progressTime >= 3
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
}
