// Generated pixels only: no captured screens or third-party content.
import Foundation

enum ScrollingReworkFixture {
    static let width = 48
    static let height = 200
    static func pixel(x: Int, pageY: Int) -> UInt32 {
        var value = UInt32(truncatingIfNeeded: pageY &* 113 + x &* 971 + 17)
        value = (value ^ (value >> 8)) &* 2654435761
        return 0xff000000 | (value & 0x00ffffff)
    }
    static func frame(_ offset: Int, phase: Int = 0, video: Range<Int>? = nil,
                      header: Int = 0, footer: Int = 0, pinned: Range<Int>? = nil,
                      relayoutAt: Int? = nil, greenAd: Range<Int>? = nil) -> ScrollingCaptureRaster {
        var pixels: [UInt32] = []
        for y in 0..<height { for x in 0..<width {
            let pageY = offset + y
            var value = pixel(x: x, pageY: pageY)
            if greenAd?.contains(pageY) == true && pageY % 37 > 10 { value = 0xff239447 }
            if let video, video.contains(pageY), x < width - 4 {
                value = 0xff000000 | UInt32((phase * 701 + x * 107 + pageY * 53) & 0xffffff)
            }
            if y < header || y >= height - footer || pinned?.contains(y) == true {
                value = pixel(x: x, pageY: y + 50_000)
            }
            if let relayoutAt, pageY >= relayoutAt { value = pixel(x: x, pageY: pageY + 13) }
            pixels.append(value)
        } }
        return ScrollingCaptureRaster(width: width, height: height, pixels: pixels)!
    }
}
