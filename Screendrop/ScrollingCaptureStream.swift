import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// One ScreenCaptureKit stream for a whole Scrolling Capture session. The
/// callback copies each new frame out of its surface, so SCK gets the surface
/// back at once, and leaves it in a single latest-frame slot: a slow engine
/// skips stale frames instead of working through a backlog.
nonisolated final class ScrollingCaptureStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let image: CGImage
        /// When WindowServer showed the frame, in `now()` seconds.
        let time: TimeInterval
        /// Counts every new frame SCK delivered, so a gap means frames that
        /// were replaced in the slot before the engine took them.
        let sequence: Int
    }

    let frames: AsyncStream<Frame>
    private let continuation: AsyncStream<Frame>.Continuation
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.screendrop.scrolling-capture.stream", qos: .userInteractive)
    /// Only touched on `queue`.
    private var sequence = 0

    override init() {
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
    }

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    /// No more frames; one already waiting in the slot is still delivered.
    func stop() {
        continuation.finish()
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    /// The clock frame times use: mach absolute time, in seconds.
    static func now() -> TimeInterval { seconds(mach_absolute_time()) }

    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    private static func seconds(_ ticks: UInt64) -> TimeInterval { Double(ticks) * secondsPerTick }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Idle frames repeat the last one: the display didn't change, so they
        // aren't new samples.
        guard type == .screen, sampleBuffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
              let status = (info[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)),
              status == .complete || status == .started,
              let pixels = sampleBuffer.imageBuffer,
              let image = Self.copy(pixels) else { return }
        sequence += 1
        let time = (info[.displayTime] as? UInt64).map(Self.seconds) ?? Self.now()
        continuation.yield(Frame(image: image, time: time, sequence: sequence))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Scrolling Capture stream stopped: %@", error.localizedDescription)
        continuation.finish()
    }

    /// Byte for byte, tagged with the surface's colour space. Skip-first
    /// alpha, so whatever SCK leaves in the alpha byte never darkens a pixel.
    private static func copy(_ buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer), row = width * 4
        var data = Data(count: row * height)
        data.withUnsafeMutableBytes { out in
            for y in 0..<height {
                out.baseAddress!.advanced(by: y * row).copyMemory(from: base.advanced(by: y * stride), byteCount: row)
            }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let space = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue()
            ?? CVBufferCopyAttachments(buffer, .shouldPropagate).flatMap {
                CVImageBufferCreateColorSpaceFromAttachments($0)?.takeRetainedValue()
            }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
