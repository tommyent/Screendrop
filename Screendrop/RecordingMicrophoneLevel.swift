//
//  RecordingMicrophoneLevel.swift
//  Screendrop
//
//  The microphone level the recording bar shows during a take, so a dead,
//  wrong or clipping mic shows up mid-take instead of after Stop. Levels are
//  read off the same SCStream microphone buffers the writer records; the
//  meter never opens the mic itself.
//

import Accelerate
import CoreMedia
import Foundation

nonisolated enum MicrophoneLevelMeter {
    /// The quietest level the meter shows; anything below reads as empty.
    static let floorDecibels: Float = -60
    /// About -0.2 dBFS: a peak this close to full scale is clipping, or a
    /// breath away from it.
    static let clipPeak: Float = 0.977
    /// How long the meter stays red after the last clipped buffer, long
    /// enough to notice out of the corner of an eye.
    static let clipHold: TimeInterval = 1.5
    /// How far the shown level may fall per update (about 20 a second), so
    /// it sinks smoothly instead of flickering between words.
    static let fallPerUpdate: Double = 0.06

    /// The largest absolute sample in a buffer of linear PCM, 0...1 for
    /// full scale. Nil for formats the meter doesn't read.
    static func peak(of sampleBuffer: CMSampleBuffer) -> Float? {
        guard let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatID == kAudioFormatLinearPCM else { return nil }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        guard (isFloat && format.mBitsPerChannel == 32) || (isSignedInteger && format.mBitsPerChannel == 16) else {
            return nil
        }
        return try? sampleBuffer.withAudioBufferList { buffers, _ in
            var peak: Float = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                var bufferPeak: Float = 0
                if isFloat {
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    guard count > 0 else { continue }
                    vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &bufferPeak, vDSP_Length(count))
                } else {
                    let samples = UnsafeBufferPointer(
                        start: data.assumingMemoryBound(to: Int16.self),
                        count: Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                    )
                    let largest = samples.reduce(0) { max($0, $1.magnitude) }
                    bufferPeak = Float(largest) / Float(Int16.max)
                }
                peak = max(peak, bufferPeak)
            }
            return min(peak, 1)
        }
    }

    /// Where a linear peak sits on the meter, 0 at the floor and 1 at full
    /// scale, on a decibel scale so speech lands mid-meter.
    static func fraction(forPeak peak: Float) -> Double {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10(peak)
        return Double(min(max((decibels - floorDecibels) / -floorDecibels, 0), 1))
    }

    static func isClipping(peak: Float) -> Bool {
        peak >= clipPeak
    }

    /// The level to show next: straight up to a louder peak, falling slowly
    /// from a quieter one.
    static func nextLevel(previous: Double, peak: Float) -> Double {
        max(fraction(forPeak: peak), previous - fallPerUpdate)
    }
}

/// Collects microphone peaks on the capture's serial audio queue and hands
/// the loudest of each ~50 ms window to `publish`, so the main actor sees
/// about 20 updates a second rather than one per buffer.
/// Used only from that one queue, which is what makes it safe to share.
nonisolated final class MicrophoneLevelTap: @unchecked Sendable {
    private static let publishInterval: UInt64 = 50_000_000

    private let publish: @Sendable (Float) -> Void
    /// Nanoseconds; replaceable so tests don't depend on real timing.
    private let clock: @Sendable () -> UInt64
    private var windowPeak: Float = 0
    private var lastPublish: UInt64 = 0

    init(
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        publish: @escaping @Sendable (Float) -> Void
    ) {
        self.clock = clock
        self.publish = publish
    }

    func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard let peak = MicrophoneLevelMeter.peak(of: sampleBuffer) else { return }
        windowPeak = max(windowPeak, peak)
        let now = clock()
        guard now - lastPublish >= Self.publishInterval else { return }
        lastPublish = now
        publish(windowPeak)
        windowPeak = 0
    }
}
