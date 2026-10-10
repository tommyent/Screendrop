import CoreGraphics
import Foundation
import Synchronization

/// The scrolls the session's monitor has heard, by hand or by auto-scroll. The
/// monitor sets it; every part's engine reads it. It counts that scrolls
/// happened, never where or how far.
nonisolated final class ScrollingCaptureScrollInput: Sendable {
    struct Snapshot: Codable, Equatable, Sendable {
        var monitored = false
        var scrolls = 0
    }
    private let snapshot = Mutex(Snapshot())
    func monitorStarted() { snapshot.withLock { $0.monitored = true } }
    func noteScroll() { snapshot.withLock { $0.scrolls += 1 } }
    var current: Snapshot { snapshot.withLock { $0 } }
}

extension ScrollingCaptureRaster {
    nonisolated init?(image: CGImage, colorSpace: CGColorSpace) {
        guard let pixels = Self.decodedPixels(image, colorSpace: colorSpace) else { return nil }
        self.init(width: image.width, height: image.height, pixels: pixels)
    }

    nonisolated static func decodedPixels(_ image: CGImage, colorSpace: CGColorSpace) -> [UInt32]? {
        var pixels = [UInt32](repeating: 0, count: image.width * image.height)
        let drawn = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? pixels : nil
    }

    nonisolated func image(in colorSpace: CGColorSpace) -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// The exported rectangle inside a larger frame, in integer device pixels.
nonisolated struct ScrollingCaptureOutputRect: Sendable {
    let columns: Range<Int>
    let rows: Range<Int>
}

/// R7 places every frame from exact rows. A frame it can't place waits while no
/// scroll has been heard since this part last placed one: a video playing or a
/// hover at rest is not a scroll. After one, that frame is lost, and the session
/// starts a new part behind a break mark. Without a running scroll monitor,
/// every frame R7 can't place is lost.
actor ScrollingCaptureEngine {
    enum State: Sendable { case pending, appended, lost, limit }
    struct Update: Sendable { let state: State; let height: Int }

    private let legacy: ScrollingCaptureStitcher
    private let selection: ScrollingCaptureOutputRect
    private let colorSpace: CGColorSpace
    private let maximumHeight: Int
    private let frameWidth: Int
    private let frameHeight: Int
    private let scrollInput: ScrollingCaptureScrollInput?
    /// The scroll input read once per call: its decisions and trace record use this.
    private var scrollState: ScrollingCaptureScrollInput.Snapshot?
    /// Scrolls heard when this part last placed a frame, or began.
    private var scrollsAtPlacement: Int
    /// The newest frame couldn't be placed and waits for a scroll to decide it.
    private var waiting = false
    private var state: State = .pending
    private var safeImage: ScrollingCaptureRaster
    private var previous: ScrollingCaptureRaster
    private var sampleIndex = 0
    private var lastObservationTime: TimeInterval?
    private var trace: ScrollingCaptureTraceWriter?
    private var traceInput: ScrollingCaptureRaster?
    private var stages: [String: TimeInterval] = [:]
    private var traceEvents: [String] = []
    private(set) var outputHeight: Int

    init?(firstFrame: CGImage, selection: ScrollingCaptureOutputRect? = nil,
          ignoredTrailingColumns: Int, maximumHeight: Int = 16_384,
          traceDirectory: URL? = ScrollingCaptureTrace.defaultDirectory,
          traceGeometry: ScrollingCaptureTraceGeometry? = nil, scrollInput: ScrollingCaptureScrollInput? = nil) {
        let space = firstFrame.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let raster = ScrollingCaptureRaster(image: firstFrame, colorSpace: space) else { return nil }
        let rect = selection ?? ScrollingCaptureOutputRect(columns: 0..<raster.width, rows: 0..<raster.height)
        guard rect.columns.lowerBound >= 0, rect.columns.upperBound <= raster.width, !rect.columns.isEmpty,
              rect.rows.lowerBound >= 0, rect.rows.upperBound <= raster.height, !rect.rows.isEmpty,
              rect.rows.count <= maximumHeight,
              let cropped = firstFrame.cropping(to: CGRect(x: rect.columns.lowerBound, y: rect.rows.lowerBound,
                width: rect.columns.count, height: rect.rows.count)),
              let output = ScrollingCaptureRaster(image: cropped, colorSpace: space),
              let legacy = ScrollingCaptureStitcher(firstFrame: cropped, ignoredTrailingColumns: ignoredTrailingColumns)
        else { return nil }
        self.selection = rect
        self.legacy = legacy
        colorSpace = space
        self.maximumHeight = maximumHeight
        frameWidth = raster.width
        frameHeight = raster.height
        self.scrollInput = scrollInput
        let start = scrollInput?.current
        scrollsAtPlacement = start?.scrolls ?? 0
        previous = raster
        safeImage = output
        outputHeight = safeImage.height
        if let traceDirectory {
            trace = ScrollingCaptureTraceWriter(first: raster, selection: rect,
                ignoredTrailingColumns: ignoredTrailingColumns, maximumHeight: maximumHeight,
                colorSpace: space, directory: traceDirectory, geometry: traceGeometry, scrollInputAtStart: start)
        }
    }

    func add(_ image: CGImage, at time: TimeInterval = ScrollingCaptureSampleTiming.now(),
             timing: ScrollingCaptureSampleTiming = .init()) async -> Update {
        scrollState = scrollInput?.current
        let old = previous
        traceEvents.removeAll(keepingCapacity: true)
        traceInput = nil
        stages = timing.stages
        stages["r7Started"] = 0; stages["r7Finished"] = 0
        mark("engineStarted")
        let result = await process(image)
        if time.isFinite { lastObservationTime = max(lastObservationTime ?? time, time) }
        mark("engineFinished")
        record(result, old: old, time: time, timing: timing)
        return result
    }

    func lastTraceRecord() async -> ScrollingCaptureTrace.Record? { await trace?.document()?.records.last }
    func noteTiming(_ timing: ScrollingCaptureSampleTiming) { trace?.noteTiming(timing) }

    /// An idle tick: nothing new on screen. A scroll heard after the newest frame
    /// waited decides that frame: it is lost.
    func noteIdle(at time: TimeInterval) async -> Update {
        scrollState = scrollInput?.current
        if time.isFinite { lastObservationTime = max(lastObservationTime ?? time, time) }
        guard waiting, scrolledSincePlacement else { return Update(state: state, height: outputHeight) }
        waiting = false
        sampleIndex += 1
        traceEvents = ["lost: no match after a scroll"]
        traceInput = previous
        stages = ["idleObserved": time]
        let result = update(.lost)
        record(result, old: previous, time: time, timing: .init())
        return result
    }

    private func mark(_ stage: String) {
        if trace != nil { stages[stage] = ScrollingCaptureSampleTiming.now() }
    }
    private func note(_ event: @autoclosure () -> String) { if trace != nil { traceEvents.append(event()) } }

    private func record(_ result: Update, old: ScrollingCaptureRaster, time: TimeInterval,
                        timing: ScrollingCaptureSampleTiming) {
        guard let trace, let frame = traceInput else { return }
        var timing = timing
        timing.stages = stages
        timing.stages["traceEnqueued"] = ScrollingCaptureSampleTiming.now()
        trace.append(.init(index: sampleIndex, time: time, old: old, frame: frame,
            state: String(describing: result.state), height: result.height, events: traceEvents,
            timing: timing, scrollInput: scrollState))
    }

    /// Without a running monitor nothing tells a scroll from a redraw, so every
    /// frame R7 can't place is lost.
    private var scrolledSincePlacement: Bool {
        guard let scrollState, scrollState.monitored else { return true }
        return scrollState.scrolls > scrollsAtPlacement
    }

    private func process(_ image: CGImage) async -> Update {
        sampleIndex += 1
        guard image.width == frameWidth, image.height == frameHeight,
              let selected = image.cropping(to: CGRect(x: selection.columns.lowerBound, y: selection.rows.lowerBound,
                width: selection.columns.count, height: selection.rows.count)) else { return update(.lost) }
        if trace != nil {
            mark("decodeStarted")
            traceInput = ScrollingCaptureRaster(image: image, colorSpace: colorSpace)
            mark("decodeFinished")
            if let traceInput { previous = traceInput }
        }
        mark("r7Started")
        let result = await legacy.add(selected)
        mark("r7Finished")
        note("legacy: \(result)")
        waiting = false
        guard result != .noMatch, let position = await legacy.registration else {
            guard scrolledSincePlacement else {
                waiting = true
                note("waiting: no scroll heard since the last placement")
                return update(.pending)
            }
            note("lost: no match after a scroll")
            return update(.lost)
        }
        note("legacy position: \(position.offset); static: \(position.isStatic)")
        // A redraw in place, such as a video playing at rest, adds nothing.
        guard result == .appended || position.isStatic else { return update(.pending) }
        let oldHeight = outputHeight
        let height = min(maximumHeight, max(1, position.offset + selection.rows.count))
        guard let stitched = await legacy.makeImage(),
              let raster = ScrollingCaptureRaster(image: stitched, colorSpace: colorSpace), height <= raster.height
        else { return update(.pending) }
        var pixels = Array(raster.pixels.prefix(height * raster.width))
        // A backscroll ends with the current footer, not rows from the overshoot.
        let bodyEnd = position.rows.upperBound
        if bodyEnd < selection.rows.count, let current = ScrollingCaptureRaster(image: selected, colorSpace: colorSpace) {
            for y in bodyEnd..<selection.rows.count {
                let target = position.offset + y
                guard target >= 0, target < height else { continue }
                pixels.replaceSubrange((target * raster.width)..<((target + 1) * raster.width), with: current.row(y))
            }
        }
        safeImage = ScrollingCaptureRaster(width: raster.width, height: height, pixels: pixels)!
        outputHeight = height
        scrollsAtPlacement = scrollState?.scrolls ?? scrollsAtPlacement
        return update(outputHeight >= maximumHeight ? .limit : outputHeight > oldHeight ? .appended : .pending)
    }

    func makeImage(at time: TimeInterval? = nil) -> CGImage? {
        trace?.finish(at: time ?? lastObservationTime ?? ScrollingCaptureSampleTiming.now(), output: safeImage)
        return safeImage.image(in: colorSpace)
    }

    func finishTrace(at time: TimeInterval) { trace?.finish(at: time) }

    /// The newest rows of the output: where this part left off.
    func recoveryRows(_ count: Int) -> CGImage? {
        let height = min(count, safeImage.height)
        guard height > 0 else { return nil }
        return ScrollingCaptureRaster(width: safeImage.width, height: height,
            pixels: Array(safeImage.pixels.suffix(height * safeImage.width)))?.image(in: colorSpace)
    }

    private func update(_ state: State) -> Update {
        self.state = state
        return Update(state: state, height: outputHeight)
    }
}
