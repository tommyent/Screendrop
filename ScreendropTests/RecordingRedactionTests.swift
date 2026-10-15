import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Testing

struct RecordingRedactionTests {
    private func region() -> RecordingRedaction {
        RecordingRedaction(start: 2, end: 4, rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
    }

    @Test func sharedRedactionsStayStaleUntilTheUploadedSnapshotMatches() throws {
        let original = region()
        #expect(!RecordingRedaction.needsSharedReplacement([], shared: nil))
        #expect(RecordingRedaction.needsSharedReplacement([original], shared: nil))
        #expect(RecordingRedaction.needsSharedReplacement([original], shared: []))
        let saved = try JSONDecoder().decode([RecordingRedaction].self, from: JSONEncoder().encode([original]))
        #expect(!RecordingRedaction.needsSharedReplacement([original], shared: saved))
        var edited = original
        edited.end += 1
        #expect(RecordingRedaction.needsSharedReplacement([edited], shared: saved))
        #expect(RecordingRedaction.needsSharedReplacement([original, edited], shared: saved))
        #expect(!RecordingRedaction.needsSharedReplacement([original], shared: saved)) // Undo.
    }

    @Test func boundsAndTimingRejectInvalidData() throws {
        let valid = region()
        try valid.validate(sourceDuration: 5)
        var invalid: [RecordingRedaction] = []
        for key in [\RecordingRedaction.start, \.end, \.strength] {
            var next = valid; next[keyPath: key] = .nan; invalid.append(next)
        }
        var next = valid; next.end = next.start; invalid.append(next)
        next = valid; next.start = -1; invalid.append(next)
        next = valid; next.strength = 1.1; invalid.append(next)
        for rect in [CGRect(x: -0.01, y: 0, width: 0.5, height: 0.5),
                     CGRect(x: 0.8, y: 0, width: 0.5, height: 0.5),
                     CGRect(x: 0, y: 0, width: 0, height: 0.5),
                     CGRect(x: 0, y: 0, width: -0.2, height: 0.5)] {
            next = valid; next.rect = rect; invalid.append(next)
        }
        for region in invalid { #expect(throws: RecordingRedactionError.self) { try region.validate() } }
        #expect(throws: RecordingRedactionError.self) { try valid.validate(sourceDuration: 3) }
        let restored = try JSONDecoder().decode(RecordingRedaction.self, from: JSONEncoder().encode(valid))
        #expect(restored == valid)
        let pixels = valid.pixelRect(in: CGRect(x: 10, y: 20, width: 100, height: 100))
        #expect(pixels.contains(CGRect(x: 20, y: 60, width: 30, height: 40)))
        #expect(pixels.width <= 31 && pixels.height <= 41)
    }

    @Test func maskRangesFollowCutsAndSpeedAndRoundOutward() {
        let timeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 1, sourceEnd: 3, speed: 2),
            RecordingClipSegment(sourceStart: 5, sourceEnd: 7)
        ])
        var mask = region()
        #expect(!mask.covers(editorTime: 0.4, frameDuration: 0.05, timeline: timeline))
        #expect(mask.covers(editorTime: 0.49, frameDuration: 0.02, timeline: timeline))
        #expect(mask.covers(editorTime: 0.5, frameDuration: 1 / 60, timeline: timeline))
        #expect(!mask.covers(editorTime: 1, frameDuration: 1 / 60, timeline: timeline))
        mask.start = 3; mask.end = 5
        #expect(!mask.covers(editorTime: 0.99, frameDuration: 0.02, timeline: timeline))
        mask.start = 5.01; mask.end = 5.02
        #expect(mask.covers(editorTime: 1, frameDuration: 1 / 30, timeline: timeline))
        #expect(!mask.covers(editorTime: 1.03, frameDuration: 1 / 30, timeline: timeline))
    }

    @Test func emptyFilterInputFailsClosed() {
        #expect(throws: RecordingRedactionError.self) {
            try RecordingRedactionFilter.apply([region()], to: CIImage.empty())
        }
    }

    @Test(arguments: RecordingRedaction.Mode.allCases)
    func filtersOnlyTheTopLeftRegionAndNeverMutatesInput(_ mode: RecordingRedaction.Mode) throws {
        let width = 128, height = 96
        let pixels = (0..<(width * height)).flatMap { index -> [UInt8] in
            let value: UInt8 = ((index % width) / 2 + (index / width) / 2) % 2 == 0 ? 255 : 0
            return [value, value, value, 255]
        }
        let bitmap = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                           bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.data?.copyMemory(from: pixels, byteCount: pixels.count)
        let original = try #require(bitmap.makeImage())
        let source = CIImage(cgImage: original)
        let mask = RecordingRedaction(start: 0, end: 1, rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), mode: mode)
        let output = try RecordingRedactionFilter.apply([mask], to: source)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let rendered = try #require(context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
        let result = try #require(rendered.dataProvider?.data) as Data
        let input = try #require(context.createCGImage(source, from: source.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
        let baseline = try #require(input.dataProvider?.data) as Data
        var changesInside = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = y * rendered.bytesPerRow + x * 4
                let difference = abs(Int(result[index]) - Int(baseline[index]))
                if x < width / 2 && y < height / 2 {
                    if difference > 20 { changesInside += 1 }
                } else { #expect(difference <= 1) }
            }
        }
        #expect(changesInside > width * height / 8)
        #expect(original.dataProvider?.data as Data? == Data(pixels))
        var invalid = mask; invalid.rect = .zero
        #expect(throws: RecordingRedactionError.self) { try RecordingRedactionFilter.apply([invalid], to: source) }
        var weakest = mask; weakest.strength = 0
        var minimum = mask; minimum.strength = 0.35
        let weakImage = try RecordingRedactionFilter.apply([weakest], to: source)
        let minimumImage = try RecordingRedactionFilter.apply([minimum], to: source)
        let weakPixels = try #require(context.createCGImage(weakImage, from: source.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
        let minimumPixels = try #require(context.createCGImage(minimumImage, from: source.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
        let weakData = try #require(weakPixels.dataProvider?.data) as Data
        let minimumData = try #require(minimumPixels.dataProvider?.data) as Data
        #expect(weakData == minimumData)
    }
}
