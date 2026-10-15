import CoreGraphics
import Foundation
import Testing

struct ImageTextWarmUpTests {
    @Test @MainActor func sharesWorkWhileRunningAndAfterCompletion() async {
        let calls = WarmUpCalls()
        let warmUp = ImageTextWarmUp { await calls.record() }
        let launch = warmUp.start()
        let capture = warmUp.start()
        await launch.value
        await capture.value
        await warmUp.start().value
        #expect(await calls.count == 1)
    }

    @Test func sampleContainsInkOnWhite() throws {
        let image = try #require(ImageTextWarmUp.sampleImage())
        let data = try #require(image.dataProvider?.data) as Data
        var ink = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                if data[y * image.bytesPerRow + x * 4] < 128 { ink += 1 }
            }
        }
        #expect(ink > 100)
        #expect(ink < image.width * image.height / 2)
    }

    @Test @MainActor func stalledWarmUpStopsBlockingWithoutStartingAnother() async {
        let calls = WarmUpCalls()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let warmUp = ImageTextWarmUp {
            await calls.record()
            for await _ in stream { }
        }
        warmUp.start()
        while await calls.count == 0 { await Task.yield() }
        #expect(await warmUp.waitUntilReady(timeout: .zero) == false)
        #expect(await warmUp.waitUntilReady(timeout: .zero) == false)
        #expect(await calls.count == 1)
        continuation.finish()
        await warmUp.start().value
        #expect(await warmUp.waitUntilReady(timeout: .zero))
    }
}

private actor WarmUpCalls {
    private(set) var count = 0
    func record() { count += 1 }
}
