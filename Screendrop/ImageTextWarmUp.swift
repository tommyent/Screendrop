import CoreGraphics
import CoreText
import Foundation
import Vision

/// Launch and Capture Text share one warm-up, including while Vision is cold.
@MainActor
final class ImageTextWarmUp {
    static let shared = ImageTextWarmUp()
    private var task: Task<Void, Never>?
    private let recognize: @Sendable () async -> Void

    init(recognize: @escaping @Sendable () async -> Void = ImageTextWarmUp.recognizeSample) {
        self.recognize = recognize
    }

    @discardableResult
    func start() -> Task<Void, Never> {
        if let task { return task }
        let recognize = recognize
        let task = Task.detached(priority: .background) { await recognize() }
        self.task = task
        return task
    }

    nonisolated private static func recognizeSample() async {
        guard let image = sampleImage() else { return }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
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
