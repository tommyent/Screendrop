import CoreGraphics
import Testing

/// Run the original assertions against R7 and replay the identical samples
/// through production dispatch; static appends must retain R7's exact pixels.
actor CanonicalStitchReplay {
    private let baseline: ScrollingCaptureStitcher
    private let production: ScrollingCaptureEngine
    private let label: String
    private var samples = 0
    private var sawChangingAppend = false

    init?(firstFrame: CGImage, ignoredTrailingColumns: Int) {
        guard let baseline = ScrollingCaptureStitcher(firstFrame: firstFrame, ignoredTrailingColumns: ignoredTrailingColumns),
              let production = ScrollingCaptureEngine(firstFrame: firstFrame, ignoredTrailingColumns: ignoredTrailingColumns)
        else { return nil }
        self.baseline = baseline
        self.production = production
        label = Test.current?.displayName ?? Test.current?.name ?? "unknown"
    }

    var stitchedHeight: Int { get async { await baseline.stitchedHeight } }
    var hasPersistentLocalChange: Bool { get async { await baseline.hasPersistentLocalChange } }
    func resetMotionDetection() async { await baseline.resetMotionDetection() }

    func add(_ image: CGImage) async -> ScrollingCaptureStitcher.Update {
        let original = await baseline.add(image)
        let result = await production.add(image)
        if original == .appended, let position = await baseline.registration,
           !position.isStatic && !position.hasOnlyMinorRedraw { sawChangingAppend = true }
        samples += 1
        print("DISPATCH | \(label) | \(samples) | \(result.engine.rawValue) | \(result.state) | \(result.height)")
        if let group = Int(label.prefix(2)), [21, 22, 24].contains(group) || (26...42).contains(group),
           original == .noMatch {
            #expect(result.state != .appended, "Canonical refusal must not turn into a new append: \(label)")
            #expect(result.height <= (await baseline.stitchedHeight))
        }
        if original == .appended, let position = await baseline.registration,
           position.isStatic || position.hasOnlyMinorRedraw,
           !sawChangingAppend {
            #expect(result.state == .appended)
            #expect(result.height == (await baseline.stitchedHeight))
            let old = await baseline.makeImage(), new = await production.makeImage()
            #expect(old != nil && new != nil)
            if let old, let new {
                let space = CGColorSpace(name: CGColorSpace.sRGB)!
                #expect(ScrollingCaptureRaster(image: old, colorSpace: space)?.pixels
                    == ScrollingCaptureRaster(image: new, colorSpace: space)?.pixels)
            }
        }
        return original
    }

    func makeImage() async -> CGImage? {
        let image = await production.makeImage()
        #expect(image != nil)
        #expect(image?.height == (await production.outputHeight))
        return await baseline.makeImage()
    }
}
