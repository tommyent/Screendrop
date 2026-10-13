import CoreGraphics
import CoreText
import Foundation
import Vision

/// Launch and Capture Text share one warm-up, including while Vision is cold.
@MainActor
final class ImageTextWarmUp {
    static let shared = ImageTextWarmUp()
    private var task: Task<Void, Never>?
    private var isFinished = false
    private let recognize: @Sendable () async -> Void

    init(recognize: @escaping @Sendable () async -> Void = ImageTextWarmUp.recognizeSample) {
        self.recognize = recognize
    }

    @discardableResult
    func start() -> Task<Void, Never> {
        if let task { return task }
        let recognize = recognize
        let task = Task(priority: .background) {
            await recognize()
            isFinished = true
        }
        self.task = task
        return task
    }

    /// A stalled warm-up must not prevent a real recognition request.
    @discardableResult
    func waitUntilReady(timeout: Duration = .seconds(30)) async -> Bool {
        start()
        let deadline = ContinuousClock.now + timeout
        while !isFinished, ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: min(.milliseconds(50), ContinuousClock.now.duration(to: deadline)))
            } catch { return false }
        }
        return isFinished
    }

    nonisolated private static func recognizeSample() async {
        await withCheckedContinuation { continuation in
            // Vision's synchronous cold work belongs off the cooperative pool.
            DispatchQueue.global(qos: .utility).async {
                if let image = sampleImage() {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                }
                continuation.resume()
            }
        }
    }

    nonisolated static func sampleImage() -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 320, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 64))
        // A blank image can hang Vision's cold text detector; render real glyphs.
        let text = NSAttributedString(string: "Text capture is ready", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 12, y: 22)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return context.makeImage()
    }
}
