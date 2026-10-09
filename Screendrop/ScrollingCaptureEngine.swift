import CoreGraphics
import Foundation

extension ScrollingCaptureRaster {
    nonisolated init?(image: CGImage, colorSpace: CGColorSpace) {
        var pixels = [UInt32](repeating: 0, count: image.width * image.height)
        let drawn = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: image.width, height: image.height, pixels: pixels)
    }

    nonisolated func image(in colorSpace: CGColorSpace) -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    nonisolated func columns(_ columns: Range<Int>) -> Self? {
        let included = matchingColumns.compactMap { range -> Range<Int>? in
            let lower = max(range.lowerBound, columns.lowerBound), upper = min(range.upperBound, columns.upperBound)
            return lower < upper ? (lower - columns.lowerBound)..<(upper - columns.lowerBound) : nil
        }
        return Self(width: columns.count, height: height, pixels: (0..<height).flatMap {
            Array(row($0).dropFirst(columns.lowerBound).prefix(columns.count))
        }, matchingColumns: included)
    }
}

/// R7 remains the static/redraw compatibility path. Visible changing overlap
/// hands output to exact registration and complete-frame band ownership.
actor ScrollingCaptureEngine {
    enum Engine: String, Sendable { case legacy, buffered }
    enum State: Sendable { case pending, appended, lost, limit }
    struct Update: Sendable { let state: State; let height: Int; let engine: Engine }

    private let legacy: ScrollingCaptureStitcher
    private let selection: ScrollingCaptureOutputRect
    private let colorSpace: CGColorSpace
    private let maximumHeight: Int
    private var lastSafeFrame: ScrollingCaptureRaster
    private var safeImage: ScrollingCaptureRaster
    private var viewport: Range<Int>
    private var matchingColumns: [Range<Int>]
    private var viewportHintOffset: Int?
    private var observedMotionRows = Set<Int>()
    private var pageWitnessRows = Set<Int>()
    private var safeOffset = 0
    private var sampleIndex = 0
    private var previousTime: TimeInterval?
    private var buffer: ScrollingCaptureRegistrationBuffer?
    private var compositor: ScrollingCaptureBandCompositor?
    private var prefix: [UInt32] = []
    private var baseOffset = 0
    private var registrationOrigin = 0
    private var previous: ScrollingCaptureRaster
    private var recovering = false
    private var recoveryPatch: (frame: ScrollingCaptureRaster, rows: Range<Int>)?
    private var trace: ScrollingCaptureTrace?
    private var traceEvents: [String] = []
    private var traceRecoveryAttempt = false
    private(set) var engine: Engine = .legacy
    private(set) var outputHeight: Int

    init?(firstFrame: CGImage, selection: ScrollingCaptureOutputRect? = nil,
          ignoredTrailingColumns: Int, maximumHeight: Int = 16_384,
          traceDirectory: URL? = ScrollingCaptureTrace.defaultDirectory) {
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
        lastSafeFrame = raster
        previous = raster
        viewport = rect.rows
        matchingColumns = [rect.columns.lowerBound..<max(rect.columns.lowerBound + 1,
            rect.columns.upperBound - min(max(0, ignoredTrailingColumns), rect.columns.count / 4))]
        safeImage = output
        outputHeight = safeImage.height
        if let traceDirectory {
            do {
                trace = try ScrollingCaptureTrace(first: raster, selection: rect,
                    ignoredTrailingColumns: ignoredTrailingColumns, maximumHeight: maximumHeight,
                    colorSpace: space, directory: traceDirectory)
            } catch { NSLog("Scrolling Capture trace could not start: %@", error.localizedDescription) }
        }
    }

    func add(_ image: CGImage, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) async -> Update {
        let old = previous
        traceEvents.removeAll(keepingCapacity: true)
        traceRecoveryAttempt = recovering
        let result = await process(image, at: time)
        previousTime = time
        if trace != nil, let decoded = ScrollingCaptureRaster(image: image, colorSpace: colorSpace) {
            let masked = decoded.using(columns: matchingColumns) ?? decoded
            guard let input = try? ScrollingCaptureTrace.Raster(masked) else { return result }
            let stats = ScrollingCaptureTrace.differences(from: old, to: masked, rows: viewport)
            trace?.append(.init(index: sampleIndex, time: time, input: input, viewport: viewport,
                contentRows: buffer?.initial.contentRows, matchingColumns: matchingColumns,
                engine: result.engine.rawValue, state: String(describing: result.state), height: result.height,
                events: traceEvents, recoveryAttempt: traceRecoveryAttempt, recoveryRows: recoveryPatch?.rows,
                recoveryPatch: recoveryPatch.flatMap { try? ScrollingCaptureTrace.Raster($0.frame) },
                bestShift: stats.shift, changedInPlace: stats.changed, maximumChannelDifference: stats.difference))
            if result.state == .lost || result.state == .limit { trace?.save() }
        }
        return result
    }

    func lastTraceRecord() -> ScrollingCaptureTrace.Record? { trace?.document.records.last }

    private func note(_ event: @autoclosure () -> String) { if trace != nil { traceEvents.append(event()) } }

    private func process(_ image: CGImage, at time: TimeInterval) async -> Update {
        sampleIndex += 1
        guard let decoded = ScrollingCaptureRaster(image: image, colorSpace: colorSpace),
              let frame = decoded.using(columns: matchingColumns),
              frame.width == lastSafeFrame.width, frame.height == lastSafeFrame.height else { return update(.lost) }
        let oldHeight = outputHeight
        let stable = Set((0..<frame.height).filter { previous.sameRow($0, as: frame, at: $0) })
        defer { previous = frame }
        if engine == .legacy {
            guard let selected = image.cropping(to: CGRect(x: selection.columns.lowerBound, y: selection.rows.lowerBound,
                width: selection.columns.count, height: selection.rows.count)) else { return update(.lost) }
            let result = await legacy.add(selected)
            note("legacy: \(result)")
            if buffer == nil, safeOffset == 0, let proposed = await legacy.proposedViewport {
                viewport = (proposed.lowerBound + selection.rows.lowerBound)..<(proposed.upperBound + selection.rows.lowerBound)
            }
            if let position = await legacy.registration {
                note("legacy position: \(position.offset); static: \(position.isStatic); minor: \(position.hasOnlyMinorRedraw)")
                let body = (position.rows.lowerBound + selection.rows.lowerBound)..<(position.rows.upperBound + selection.rows.lowerBound)
                let legacyOutput = position.isStatic || (result == .appended && position.hasOnlyMinorRedraw)
                if buffer == nil || legacyOutput {
                    let current = position.matchingColumns.map {
                        ($0.lowerBound + selection.columns.lowerBound)..<($0.upperBound + selection.columns.lowerBound)
                    }
                    // A briefly unchanged gutter must not regain matching authority.
                    let retained = matchingColumns.flatMap { old in current.compactMap { new -> Range<Int>? in
                        let lower = max(old.lowerBound, new.lowerBound), upper = min(old.upperBound, new.upperBound)
                        return lower < upper ? lower..<upper : nil
                    } }
                    guard !retained.isEmpty else { return update(.pending) }
                    matchingColumns = retained
                }
                if legacyOutput {
                    // shortcut: ≤2-level pale animation keeps R7's existing behavior;
                    // semantic video detection would need independent page information.
                    let offset = position.offset
                    let height = min(maximumHeight, max(1, offset + selection.rows.count))
                    if let image = await legacy.makeImage(),
                       let raster = ScrollingCaptureRaster(image: image, colorSpace: colorSpace),
                       height <= raster.height,
                       var output = ScrollingCaptureRaster(width: raster.width, height: height,
                            pixels: Array(raster.pixels.prefix(height * raster.width))) {
                        // A backscroll ends with the current footer, not rows from the overshoot.
                        if body.upperBound < selection.rows.upperBound {
                            var pixels = output.pixels
                            for y in body.upperBound..<selection.rows.upperBound {
                                let target = offset + y - selection.rows.lowerBound
                                guard target >= 0, target < height else { continue }
                                let start = y * frame.width + selection.columns.lowerBound
                                pixels.replaceSubrange((target * output.width)..<((target + 1) * output.width),
                                    with: frame.pixels[start..<(start + output.width)])
                            }
                            output = ScrollingCaptureRaster(width: output.width, height: height, pixels: pixels)!
                        }
                        safeImage = output
                        outputHeight = output.height
                        viewport = widerViewport(body: body, delta: offset - safeOffset, frame: frame)
                        let delta = offset - safeOffset
                        pageWitnessRows = Set(viewport.filter { y in
                            if delta == 0 {
                                return pageWitnessRows.contains(y) && lastSafeFrame.sameRow(y, as: frame, at: y)
                            }
                            return (0..<frame.height).contains(y + delta)
                                && lastSafeFrame.sameRow(y + delta, as: frame, at: y)
                                && !lastSafeFrame.sameRow(y, as: frame, at: y)
                        })
                        lastSafeFrame = frame.using(columns: matchingColumns)!
                        safeOffset = offset
                        buffer = nil
                        compositor = nil
                        recovering = false
                        return update(outputHeight >= maximumHeight ? .limit : outputHeight > oldHeight ? .appended : .pending)
                    }
                } else if result == .appended {
                    // R7 may have sliced visible video. Never publish that image.
                    engine = .buffered
                    buffer = nil
                    compositor = nil
                    let delta = position.offset - safeOffset
                    viewport = widerViewport(body: body, delta: delta, frame: frame)
                    viewportHintOffset = viewport == body ? nil : delta
                    let old = lastSafeFrame.using(columns: matchingColumns)!
                    let new = frame.using(columns: matchingColumns)!
                    observedMotionRows = Set(viewport.filter {
                        viewport.contains($0 + delta) && !old.sameRow($0 + delta, as: new, at: $0)
                    }.map { $0 + delta })
                }
            }
        }
        if buffer == nil {
            let start = max(viewport.lowerBound, selection.rows.lowerBound - safeOffset)
            guard start < selection.rows.upperBound,
                  let first = lastSafeFrame.using(columns: matchingColumns),
                  let registration = ScrollingCaptureRegistrationBuffer(first: first,
                confirmation: first, contentRows: viewport, observedMotionRows: observedMotionRows,
                pageWitnessRows: pageWitnessRows),
                  let output = ScrollingCaptureBandCompositor(initial: registration.initial,
                    selection: ScrollingCaptureOutputRect(columns: selection.columns, rows: start..<selection.rows.upperBound),
                    maximumOutputRows: maximumHeight) else { return update(.lost) }
            buffer = registration
            compositor = output
            baseOffset = safeOffset
            registrationOrigin = 0
            let seam = min(safeImage.height, max(0, safeOffset + start - selection.rows.lowerBound))
            prefix = Array(safeImage.pixels.prefix(seam * safeImage.width))
        }
        var recovered: ScrollingCapturePlacement?
        var recoveryEvent: ScrollingCaptureRegistrationBuffer.Event?
        if recovering {
            guard let position = recoveryOffset(frame, stable: stable) else {
                note("recovery: no unique page overlap")
                return update(.lost)
            }
            note("recovery: \(position.offset); rows: \(position.rows.sorted())")
            let offset = position.offset
            let lower = max(viewport.lowerBound, selection.rows.lowerBound)
            let upper = min(viewport.upperBound, selection.rows.upperBound)
            guard lower < upper else { return update(.lost) }
            let rows = lower..<upper
            let origin = lastSafeFrame.using(columns: matchingColumns)!
            let oldTop = viewport.lowerBound + offset - safeOffset
            let unchangedChrome = (0..<frame.height).filter { !viewport.contains($0) }
                .allSatisfy { origin.sameRow($0, as: frame, at: $0) }
            let sameBounds = unchangedChrome && viewport.contains(oldTop)
                && origin.sameRow(oldTop, as: frame, at: viewport.lowerBound)
                && widerViewport(body: rows, delta: offset - safeOffset, frame: frame) == viewport
            if !sameBounds {
                compositor?.narrowOwnerSourcingToSelection()
            }
            let moving = Set(compositor?.bands.flatMap { band in
                band.rows.map { $0 + baseOffset - offset }
            } ?? []).intersection(rows)
            if sameBounds, var candidate = buffer, candidate.initial.contentRows == viewport {
                let verified = candidate.add(frame, at: sampleIndex, time: time)
                note("recovery registration: \(verified.state); \(String(describing: verified.failure))")
                if verified.placements.last.map({ $0.offset + registrationOrigin == offset - baseOffset }) == true {
                    buffer = candidate
                    recoveryEvent = verified
                }
            }
            if recoveryEvent == nil {
                guard let registration = ScrollingCaptureRegistrationBuffer(first: frame, confirmation: frame,
                    contentRows: rows, observedMotionRows: moving.union(Set(rows).subtracting(stable)),
                    pageWitnessRows: position.rows) else { return update(.lost) }
                buffer = registration
                registrationOrigin = offset - baseOffset
                recovered = ScrollingCapturePlacement(index: sampleIndex, offset: registrationOrigin,
                    frame: frame, stableRows: position.rows, motionRows: moving.intersection(viewport), contentRows: viewport)
            }
            compositor?.resume()
            recovering = false
        }
        let matching = frame.using(columns: matchingColumns)!
        var event = recoveryEvent ?? buffer!.add(matching, at: sampleIndex, time: time)
        if engine == .legacy, let placed = event.placements.last, placed.offset > 0, sampleIndex > 1 {
            let proposed = widerViewport(body: viewport, delta: placed.offset, frame: matching)
            let old = lastSafeFrame.using(columns: matchingColumns)!
            let motion = Set(proposed.filter {
                proposed.contains($0 + placed.offset) && !old.sameRow($0 + placed.offset, as: matching, at: $0)
            }.map { $0 + placed.offset })
            if proposed != viewport,
               var candidate = ScrollingCaptureRegistrationBuffer(first: old, confirmation: old,
                    contentRows: proposed, observedMotionRows: motion, pageWitnessRows: pageWitnessRows),
               let preceding = previous.using(columns: matchingColumns) {
                _ = candidate.add(preceding, at: sampleIndex - 1, time: previousTime ?? time - 0.05)
                let verified = candidate.add(matching, at: sampleIndex, time: time)
                note("wider registration: \(verified.state); failure: \(String(describing: verified.failure)); offsets: \(verified.placements.map(\.offset))")
                if verified.placements.last?.offset == placed.offset {
                    let start = max(proposed.lowerBound, selection.rows.lowerBound - safeOffset)
                    if let output = ScrollingCaptureBandCompositor(initial: candidate.initial,
                        selection: ScrollingCaptureOutputRect(columns: selection.columns, rows: start..<selection.rows.upperBound),
                        maximumOutputRows: maximumHeight) {
                        viewport = proposed
                        buffer = candidate
                        compositor = output
                        let seam = min(safeImage.height, max(0, safeOffset + start - selection.rows.lowerBound))
                        prefix = Array(safeImage.pixels.prefix(seam * safeImage.width))
                        event = verified
                    }
                }
            }
        }
        note("registration: \(event.state); failure: \(String(describing: event.failure)); pending: \(String(describing: event.pendingReason))")
        note("retained: \(buffer!.pendingCount); bytes: \(buffer!.bufferedBytes); settled: \(buffer!.settledPageRows.sorted())")
        for placement in event.placements {
            note("placement: \(placement.index) at \(placement.offset); content: \(placement.contentRows); stable: \(placement.stableRows.sorted()); motion: \(placement.motionRows.sorted()); corroborating: \(placement.corroboratingRows.sorted())")
        }
        if event.state == .lost {
            recovering = true
            buffer?.discardUnresolved()
            return update(.lost)
        }
        var placements = event.placements.map { placement in
            ScrollingCapturePlacement(index: placement.index, offset: placement.offset + registrationOrigin,
                frame: placement.frame, stableRows: placement.stableRows, motionRows: placement.motionRows,
                contentRows: viewport)
        }
        if let recovered { placements = [recovered] }
        if let hint = viewportHintOffset, let placed = placements.last {
            viewportHintOffset = nil
            if placed.offset != hint {
                // A wrong crop-derived hint costs lookahead, never a placement.
                viewport = selection.rows
                buffer = nil
                compositor = nil
                return update(.pending)
            }
        }
        if !placements.isEmpty {
            let stop = max(1, baseOffset + placements.last!.offset + selection.rows.count)
            if stop > maximumHeight { return update(.limit) }
            if stop <= prefix.count / selection.columns.count {
                outputHeight = stop
            } else {
                compositor?.resume()
                let composed = compositor!.add(placements)
                note("compositor: \(composed.state); failure: \(String(describing: composed.failure))")
                note("bands: \(compositor!.bands.map { "\($0.rows): owner \(String(describing: $0.owner?.index)), locked \($0.locked)" })")
                if composed.state == .lost {
                    recovering = true
                    return update(composed.failure == .outputLimit ? .limit : .lost)
                }
                outputHeight = stop
            }
            engine = .buffered
            rememberRecovery(placements.last!)
            return update(outputHeight > oldHeight ? .appended : .pending)
        }
        return update(.pending)
    }

    func makeImage() -> CGImage? {
        let image = renderedImage()
        if trace != nil {
            trace?.save(done: true, output: image.flatMap { ScrollingCaptureRaster(image: $0, colorSpace: colorSpace) })
        }
        return image
    }

    private func renderedImage() -> CGImage? {
        guard engine == .buffered, let tail = compositor?.finish() else { return safeImage.image(in: colorSpace) }
        let pixels = prefix + tail.pixels
        guard pixels.count >= outputHeight * selection.columns.count else { return nil }
        return ScrollingCaptureRaster(width: selection.columns.count, height: outputHeight,
            pixels: Array(pixels.prefix(outputHeight * selection.columns.count)))?.image(in: colorSpace)
    }

    func recoveryRows(_ count: Int) -> CGImage? {
        recoveryRaster(count)?.image(in: colorSpace)
    }

    private func recoveryRaster(_ count: Int, newest: Bool = true) -> ScrollingCaptureRaster? {
        if newest, let patch = newestRecoveryPatch(count) { return patch.frame }
        if engine == .legacy {
            let height = min(count, safeImage.height)
            return ScrollingCaptureRaster(width: safeImage.width, height: height,
                pixels: Array(safeImage.pixels.suffix(height * safeImage.width)))
        }
        if outputHeight > prefix.count / selection.columns.count,
           let confirmed = compositor?.recoveryRows(count) { return confirmed }
        let end = min(outputHeight, prefix.count / selection.columns.count)
        let height = min(count, end)
        guard height > 0 else { return nil }
        return ScrollingCaptureRaster(width: selection.columns.count, height: height,
            pixels: Array(prefix[((end - height) * selection.columns.count)..<(end * selection.columns.count)]))
    }

    private func recoveryOffset(_ frame: ScrollingCaptureRaster, stable: Set<Int>) -> (offset: Int, rows: Set<Int>)? {
        guard let selected = frame.columns(selection.columns) else { return nil }
        let confirmed = engine == .legacy ? safeImage.height : min(outputHeight,
            prefix.count / selection.columns.count + min(compositor?.confirmedHeight ?? 0, compositor?.outputHeight ?? 0))
        var references: [(frame: ScrollingCaptureRaster, start: Int)] = []
        if let patch = newestRecoveryPatch(frame.height) { references.append((patch.frame, patch.rows.lowerBound)) }
        if let old = recoveryRaster(frame.height, newest: false) {
            references.append((old, confirmed - old.height + selection.rows.lowerBound))
        }
        var positions: [Int: Set<Int>] = [:]
        for source in references {
            guard let reference = source.frame.using(columns: selected.matchingColumns) else { continue }
            let start = source.start
            var votes: [Int: Set<Int>] = [:]
            let current = stable.intersection(viewport).intersection(selection.rows)
            for y in current where !selected.isBlank(y) {
                for oldY in 0..<reference.height where reference.sameRow(oldY, as: selected, at: y) {
                    let pageY = start + oldY
                    guard pageY >= max(viewport.lowerBound, selection.rows.lowerBound),
                          engine != .legacy || pageY < safeOffset + viewport.upperBound,
                          compositor?.bands.contains(where: { $0.rows.contains(pageY - baseOffset) }) != true else { continue }
                    votes[start + oldY - y, default: []].insert(reference.rowHash(oldY))
                }
            }
            let offsets = votes.filter { $0.value.count >= 8 }.keys
            guard offsets.count == 1, let offset = offsets.first,
                  current.filter({ (0..<reference.height).contains(offset + $0 - start) })
                    .allSatisfy({ reference.sameRow(offset + $0 - start, as: selected, at: $0) }) else { continue }
            positions[offset, default: []].formUnion(current.filter { y in
                let oldY = offset + y - start
                return (0..<reference.height).contains(oldY) && reference.sameRow(oldY, as: selected, at: y)
            })
        }
        guard positions.count == 1, let position = positions.first else { return nil }
        return (position.key, position.value)
    }

    private func rememberRecovery(_ placement: ScrollingCapturePlacement) {
        recoveryPatch = nil
        let eligible = placement.stableRows.intersection(selection.rows).filter { y in
            compositor?.bands.contains { $0.rows.contains(placement.offset + y) } != true
        }.sorted()
        var run: [Int] = []
        func retain() {
            guard Set(run.filter { !placement.frame.isBlank($0) }.map { placement.frame.rowHash($0) }).count >= 8,
                  let first = run.first, let last = run.last else { return }
            let pixels = run.flatMap { y in
                Array(placement.frame.row(y).dropFirst(selection.columns.lowerBound).prefix(selection.columns.count))
            }
            if let frame = ScrollingCaptureRaster(width: selection.columns.count, height: run.count, pixels: pixels) {
                recoveryPatch = (frame, (baseOffset + placement.offset + first)..<(baseOffset + placement.offset + last + 1))
            }
        }
        for y in eligible {
            if let last = run.last, y != last + 1 { retain(); run.removeAll(keepingCapacity: true) }
            run.append(y)
        }
        retain()
    }

    private func newestRecoveryPatch(_ count: Int) -> (frame: ScrollingCaptureRaster, rows: Range<Int>)? {
        guard engine == .buffered, count > 0, let patch = recoveryPatch,
              compositor?.bands.contains(where: { band in
                  band.rows.overlaps((patch.rows.lowerBound - baseOffset)..<(patch.rows.upperBound - baseOffset))
              }) != true else { return nil }
        let confirmed = min(outputHeight, prefix.count / selection.columns.count
            + min(compositor?.confirmedHeight ?? 0, compositor?.outputHeight ?? 0)) + selection.rows.lowerBound
        guard patch.rows.upperBound > confirmed else { return nil }
        let height = min(count, patch.frame.height)
        guard let image = ScrollingCaptureRaster(width: patch.frame.width, height: height,
            pixels: Array(patch.frame.pixels.suffix(height * patch.frame.width))) else { return nil }
        return (image, (patch.rows.upperBound - height)..<patch.rows.upperBound)
    }

    private func update(_ state: State) -> Update { Update(state: state, height: outputHeight, engine: engine) }

    private func widerViewport(body: Range<Int>, delta: Int, frame: ScrollingCaptureRaster) -> Range<Int> {
        guard delta > 0 else { return viewport }
        let old = lastSafeFrame.using(columns: matchingColumns)!
        let new = frame.using(columns: matchingColumns)!
        let moved = (0..<frame.height).filter {
            $0 + delta < frame.height && old.sameRow($0 + delta, as: new, at: $0)
                && !old.sameRow($0, as: new, at: $0) && !new.isBlank($0)
        }
        guard !moved.isEmpty else { return body }
        // shortcut: changing outer rows may be an entering video, not yet page
        // evidence; independent registration must verify this wider proposal.
        var top = 0
        var bottom = frame.height
        for y in top..<bottom where !new.isBlank(y) && old.sameRow(y, as: new, at: y)
            && (y + delta >= frame.height || !old.sameRow(y + delta, as: new, at: y)) {
            if y < body.lowerBound { top = y + 1 }
            else if y >= body.upperBound { bottom = min(bottom, y) }
            else { return body }
        }
        guard let verifiedTop = moved.first(where: { $0 >= top && $0 <= body.lowerBound }) else { return body }
        top = verifiedTop
        return top..<bottom
    }
}
