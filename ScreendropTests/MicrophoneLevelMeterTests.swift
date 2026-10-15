import CoreMedia
import Foundation
import Testing

struct MicrophoneLevelMeterTests {
    @Test func readsTheLoudestFloatSampleEitherSign() throws {
        let buffer = try Self.sampleBuffer(floats: [0.1, -0.5, 0.25, 0])
        #expect(MicrophoneLevelMeter.peak(of: buffer) == 0.5)
    }

    @Test func readsSixteenBitSamples() throws {
        let buffer = try Self.sampleBuffer(int16s: [100, Int16.min, 2_000])
        #expect(MicrophoneLevelMeter.peak(of: buffer) == 1)
        let quiet = try Self.sampleBuffer(int16s: [0, 16_384, -8_192])
        let peak = try #require(MicrophoneLevelMeter.peak(of: quiet))
        #expect(abs(peak - 0.5) < 0.001)
    }

    @Test func ignoresFormatsItDoesNotRead() throws {
        // 32-bit integer PCM: valid audio, but not a format SCStream hands the meter.
        let format = Self.pcmFormat(bits: 32, flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
        let description = try CMAudioFormatDescription(audioStreamBasicDescription: format)
        let block = try CMBlockBuffer(length: 8, flags: .assureMemoryNow)
        let buffer = try CMSampleBuffer(
            dataBuffer: block, formatDescription: description, numSamples: 2,
            presentationTimeStamp: .zero, packetDescriptions: []
        )
        #expect(MicrophoneLevelMeter.peak(of: buffer) == nil)
    }

    @Test func placesPeaksOnADecibelScale() {
        #expect(MicrophoneLevelMeter.fraction(forPeak: 0) == 0)
        #expect(MicrophoneLevelMeter.fraction(forPeak: 0.0001) == 0) // -80 dBFS, below the floor
        #expect(abs(MicrophoneLevelMeter.fraction(forPeak: 0.031_62) - 0.5) < 0.001) // -30 dBFS
        #expect(MicrophoneLevelMeter.fraction(forPeak: 1) == 1)
    }

    @Test func flagsClippingOnlyNearFullScale() {
        #expect(MicrophoneLevelMeter.isClipping(peak: 1))
        #expect(MicrophoneLevelMeter.isClipping(peak: 0.98))
        #expect(!MicrophoneLevelMeter.isClipping(peak: 0.9)) // about -0.9 dBFS: loud, not clipped
    }

    @Test func risesAtOnceAndFallsGradually() {
        #expect(MicrophoneLevelMeter.nextLevel(previous: 0.2, peak: 1) == 1)
        let fallen = MicrophoneLevelMeter.nextLevel(previous: 1, peak: 0)
        #expect(abs(fallen - (1 - MicrophoneLevelMeter.fallPerUpdate)) < 0.000_001)
    }

    @Test func tapPublishesTheLoudestPeakOfEachWindow() throws {
        let published = Locked<[Float]>([])
        let now = Locked<UInt64>(1_000_000_000)
        let tap = MicrophoneLevelTap(clock: { now.value }) { peak in published.update { $0.append(peak) } }
        tap.ingest(try Self.sampleBuffer(floats: [0.25]))
        // 10 ms later, inside the same 50 ms window: held back, but remembered.
        now.update { $0 += 10_000_000 }
        tap.ingest(try Self.sampleBuffer(floats: [0.75]))
        tap.ingest(try Self.sampleBuffer(floats: [0.5]))
        #expect(published.value == [0.25])
        now.update { $0 += 50_000_000 }
        tap.ingest(try Self.sampleBuffer(floats: [0.1]))
        #expect(published.value == [0.25, 0.75])
    }

    // MARK: - Fixtures

    static func pcmFormat(bits: UInt32, flags: AudioFormatFlags) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: bits / 8, mFramesPerPacket: 1, mBytesPerFrame: bits / 8,
            mChannelsPerFrame: 1, mBitsPerChannel: bits, mReserved: 0
        )
    }

    static func sampleBuffer(floats: [Float]) throws -> CMSampleBuffer {
        try sampleBuffer(
            bytes: floats.withUnsafeBytes { Data($0) },
            count: floats.count,
            format: pcmFormat(bits: 32, flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        )
    }

    static func sampleBuffer(int16s: [Int16]) throws -> CMSampleBuffer {
        try sampleBuffer(
            bytes: int16s.withUnsafeBytes { Data($0) },
            count: int16s.count,
            format: pcmFormat(bits: 16, flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
        )
    }

    private static func sampleBuffer(bytes: Data, count: Int, format: AudioStreamBasicDescription) throws -> CMSampleBuffer {
        let description = try CMAudioFormatDescription(audioStreamBasicDescription: format)
        let block = try CMBlockBuffer(length: bytes.count, flags: .assureMemoryNow)
        try bytes.withUnsafeBytes { try block.replaceDataBytes(with: $0) }
        return try CMSampleBuffer(
            dataBuffer: block, formatDescription: description, numSamples: count,
            presentationTimeStamp: .zero, packetDescriptions: []
        )
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func update(_ change: (inout Value) -> Void) {
        lock.withLock { change(&stored) }
    }
}
