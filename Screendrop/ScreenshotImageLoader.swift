//
//  ScreenshotImageLoader.swift
//  Screendrop
//
//  Created by Codex on 26/04/26.
//

import AppKit
import ImageIO

enum ScreenshotImageLoader {
    static func imageSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }
        
        // Orientations 5-8 turn the image a quarter turn, so upright it's transposed.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }
    
    static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded(.up)))
        ]
        
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        
        return NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    /// Decodes the image at its native pixel resolution. Used when the
    /// low-resolution editing preview preference is disabled.
    static func fullResolutionImage(at url: URL) -> NSImage? {
        guard let cgImage = uprightImage(at: url) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    /// Decodes the image at its native pixel resolution with its EXIF
    /// orientation applied, as `imageSize` and `downsampledImage` see it.
    /// Everything that reads a screenshot's pixels (editor, export, crop, text
    /// recognition, compression) decodes through here so they all agree.
    /// Untagged and orientation-1 images take the plain decode, as before.
    nonisolated static func uprightImage(at url: URL) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation != 1,
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return CGImageSourceCreateImageAtIndex(source, 0, options)
        }

        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ] as CFDictionary)
    }

    /// The image's EXIF orientation, 1 when it has none.
    static func orientation(at url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any] else {
            return 1
        }
        return properties[kCGImagePropertyOrientation] as? Int ?? 1
    }

    private static var sourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }
}
