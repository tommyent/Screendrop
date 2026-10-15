import Foundation

nonisolated enum RecordingMusicEnvelope {
    static let window = 0.02

    struct Placement: Equatable, Sendable {
        var sourceStart: Double
        var duration: Double
        var editorStart: Double
    }
    struct Point: Equatable, Sendable {
        var time: Double
        var volume: Double
    }

    static func placements(trackDuration: Double, startOffset: Double, duration: Double, loop: Bool) -> [Placement] {
        guard trackDuration.isFinite, duration.isFinite, duration > 0 else { return [] }
        let start = RecordingBackgroundMusic.startOffset(startOffset, duration: trackDuration)
        let available = trackDuration - start
        guard available > 0 else { return [] }
        var result: [Placement] = []
        var cursor = 0.0
        repeat {
            let length = min(available, duration - cursor)
            result.append(Placement(sourceStart: start, duration: length, editorStart: cursor))
            cursor += length
        } while loop && cursor < duration - 0.000_001
        return result
    }

    /// RMS follows the microphone's own level, with a floor for digital silence.
    static func speechRanges(levels: [Float], window: Double = window) -> [ClosedRange<Double>] {
        guard !levels.isEmpty else { return [] }
        let sorted = levels.sorted()
        let high = Double(sorted.last ?? 0)
        guard high > 0.0001 else { return [] }
        let noise = Double(sorted[Int(Double(sorted.count - 1) * 0.2)])
        let threshold = max(0.0001, min(high * 0.5, max(noise * 2.5, high * 0.15)))
        var result: [ClosedRange<Double>] = []
        var start: Double?
        for index in 0...levels.count {
            let active = index < levels.count && Double(levels[index]) >= threshold
            if active, start == nil { start = Double(index) * window }
            if !active, let beginning = start {
                result.append(beginning...Double(index) * window)
                start = nil
            }
        }
        return bridge(result)
    }

    static func bridge(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound - last.upperBound < 0.25 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else { result.append(range) }
        }
        return result
    }

    static func mappedSpeech(_ ranges: [ClosedRange<Double>], timeline: RecordingClipTimeline) -> [ClosedRange<Double>] {
        bridge(ranges.flatMap { range in
            timeline.slices(overlapping: range.lowerBound, sourceEnd: range.upperBound)
                .map { $0.editorStart...$0.editorEnd }
        })
    }

    static func points(settings: RecordingBackgroundMusic, speech: [ClosedRange<Double>], timeline: RecordingClipTimeline) -> [Point] {
        let duration = timeline.duration
        guard duration.isFinite, duration > 0 else { return [] }
        let mapped = settings.duck ? mappedSpeech(speech, timeline: timeline) : []
        let minimum = settings.duckAmount.gain
        var rangeIndex = 0
        var gain = 1.0
        var previousTime = 0.0
        var result: [Point] = []
        var times = (0...Int(ceil(duration / window))).map { min(duration, Double($0) * window) }
        times.append(max(0, duration - 1))
        for range in mapped {
            times += [range.lowerBound, min(duration, range.lowerBound + 0.05),
                      range.upperBound, min(duration, range.upperBound + 0.3)]
        }
        for time in Set(times).sorted() {
            while rangeIndex < mapped.count, mapped[rangeIndex].upperBound <= previousTime { rangeIndex += 1 }
            let active = rangeIndex < mapped.count && mapped[rangeIndex].lowerBound <= previousTime
            let step = (time - previousTime) * (1 - minimum) / (active ? 0.05 : 0.3)
            gain = active ? max(minimum, gain - step) : min(1, gain + step)
            let fade = min(1, max(0, (duration - time) / min(1, duration)))
            let point = Point(time: time, volume: settings.volume * gain * fade)
            if result.count >= 2 {
                let a = result[result.count - 2], b = result[result.count - 1]
                let oldSlope = (b.volume - a.volume) / (b.time - a.time)
                let newSlope = (point.volume - b.volume) / (point.time - b.time)
                if abs(oldSlope - newSlope) < 0.000_001 { result.removeLast() }
            }
            result.append(point)
            previousTime = time
        }
        return result
    }
}
