import CoreGraphics
import Foundation
import SwiftUI

struct MagnifierProps: Codable, Equatable {
    var ring = Vec(0, 0)
    var ringSize: Double = 60
    var loupe = Vec(140, 0)
    var loupeSize: Double = 180
    var swatch: AnnotationSwatch = .red
    var strokeWidth: Double = 4

    var zoom: Double { loupeSize / ringSize }
    var ringRect: CGRect { rect(center: ring, size: ringSize) }
    var loupeRect: CGRect { rect(center: loupe, size: loupeSize) }
    var isValid: Bool {
        [ring.x, ring.y, loupe.x, loupe.y, ringSize, loupeSize, strokeWidth].allSatisfy(\.isFinite)
            && ringSize >= 1 && loupeSize >= 1 && strokeWidth >= 0
    }

    private func rect(center: Vec, size: Double) -> CGRect {
        CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }

    static func path(_ rect: CGRect) -> CGPath {
        Path(roundedRect: rect, cornerRadius: rect.width * 0.22, style: .continuous).cgPath
    }

    var handles: [(AnnoSelectionHandle, Vec)] {
        [(.magnifierRingResize, Vec(ringRect.maxX, ringRect.maxY)),
         (.magnifierLoupeResize, Vec(loupeRect.maxX, loupeRect.maxY)),
         (.magnifierRing, ring), (.magnifierLoupe, loupe)]
    }

    var geometry: Geometry2d {
        guard isValid else { return Rectangle2d(width: 0, height: 0, isFilled: false) }
        return Group2d(children: [
            Polygon2d(points: PathBuilder(cgPath: Self.path(ringRect)).vertices(), isFilled: true),
            Polygon2d(points: PathBuilder(cgPath: Self.path(loupeRect)).vertices(), isFilled: true),
            Polyline2d(points: [ring, loupe]),
        ])
    }
}

/// One sanitized bitmap per canvas, invalidated by source or redaction edits.
final class AnnoMagnifierPreviewCache {
    private var source: CGImage?
    private var redactions: [AnnoShape] = []
    private var image: CGImage?

    func image(source: CGImage, redactions: [AnnoShape], render: () -> CGImage?) -> CGImage? {
        if self.source === source, self.redactions == redactions { return image }
        self.source = source
        self.redactions = redactions
        image = render()
        return image
    }

    func clear() { source = nil; redactions = []; image = nil }
}
