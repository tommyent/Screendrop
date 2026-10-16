import AppKit
import Foundation

private struct AnnotationClipboard: Codable {
    var shapes: [AnnoShape]
    var bindings: [ArrowBinding]
    var images: [String: Data]

    // Far beyond screenshot dimensions; the reciprocal also excludes unsafe divisors.
    static let numericLimit = 1_000_000.0

    private static func safe(_ values: Double...) -> Bool {
        values.allSatisfy { $0.isFinite && abs($0) <= numericLimit }
    }

    private static func positive(_ values: Double...) -> Bool {
        values.allSatisfy { (1 / numericLimit...numericLimit).contains($0) }
    }

    private static func safe(_ point: Vec) -> Bool { safe(point.x, point.y, point.z) }

    static func isSafe(_ shape: AnnoShape) -> Bool {
        guard safe(shape.x, shape.y, shape.rotation), (0...1).contains(shape.opacity) else { return false }
        if let swatch = shape.swatch,
           ![swatch.red, swatch.green, swatch.blue, swatch.alpha].allSatisfy({ (0...1).contains($0) }) { return false }
        switch shape.kind {
        case let .geo(p):
            return positive(p.w, p.h, p.strokeWidth) && safe(p.cornerRadius) && p.cornerRadius >= 0
        case let .draw(p):
            return positive(p.strokeWidth) && p.points.allSatisfy { safe($0) }
        case let .arrow(p):
            return positive(p.strokeWidth) && safe(p.start) && safe(p.end) && safe(p.bend)
        case let .text(p):
            return positive(p.w, p.fontSize)
        case let .redaction(p):
            return positive(p.w, p.h) && (0...1).contains(p.density)
        case let .highlight(p):
            return positive(p.w, p.h)
        case let .numbered(p):
            return positive(p.diameter) && safe(Double(p.value))
        case let .magnifier(p):
            return p.isValid && positive(p.ringSize, p.loupeSize) && safe(p.ring) && safe(p.loupe) && safe(p.strokeWidth)
        case let .image(p):
            return positive(p.w, p.h)
        }
    }

    var isValid: Bool {
        guard !shapes.isEmpty, Set(shapes.map(\.id)).count == shapes.count,
              shapes.allSatisfy({ Self.isSafe($0) }) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: shapes.map { ($0.id, $0) })
        return bindings.allSatisfy { binding in
            guard let source = byID[binding.arrowId], let target = byID[binding.toId] else { return false }
            return AnnoEditor.canBind(source, to: target) && Self.safe(binding.normalizedAnchor)
        }
    }
}

extension AnnoEditor {
    static let annotationPasteboardType = NSPasteboard.PasteboardType("com.tommyent.sukusho.annotations")

    /// Page units are image pixels: keep geometry unchanged across screenshot sizes.
    func copySelection(to pasteboard: NSPasteboard = .general) -> Bool {
        var shapes = selectedShapes
        guard !shapes.isEmpty else { return false }
        let ids = Set(shapes.map(\.id))
        // Freeze terminals whose targets aren't copied, rather than using their stale fallbacks.
        for index in shapes.indices {
            guard case var .arrow(props) = shapes[index].kind,
                  let info = document.arrowInfo(shapes[index].id) else { continue }
            let detachStart = info.bindings.start.map { !ids.contains($0.toId) } ?? false
            let detachEnd = info.bindings.end.map { !ids.contains($0.toId) } ?? false
            if detachStart { props.start = info.start.point }
            if detachEnd { props.end = info.end.point }
            // Clipping changes the chord, so keeping the old bend would produce a different circle.
            if detachStart || detachEnd, case .arc = info.body {
                let start = detachStart ? props.start : info.start.handle
                let end = detachEnd ? props.end : info.end.handle
                let arc = ArrowShared.arcInfo(start, end, info.middle)
                if arc.radius.isFinite, arc.size.isFinite {
                    let middle = Vec.add(arc.center, Vec.fromAngle(Vec.angle(arc.center, start) + arc.size / 2, arc.radius))
                    let offset = Vec.sub(middle, Vec.med(start, end))
                    let perpendicular = Vec.sub(end, start).uni.per
                    props.bend = -offset.x * perpendicular.x - offset.y * perpendicular.y
                }
            }
            shapes[index].kind = .arrow(props)
        }
        let assetIDs = Set(shapes.compactMap { $0.imageProps?.assetID })
        var images: [String: Data] = [:]
        for id in assetIDs {
            guard let asset = imageAssets[id] else { return false }
            images[id] = asset.data
        }
        let payload = AnnotationClipboard(
            shapes: shapes,
            bindings: document.bindings.filter { ids.contains($0.arrowId) && ids.contains($0.toId) },
            images: images
        )
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: Self.annotationPasteboardType)
    }

    func pasteAnnotations(from pasteboard: NSPasteboard = .general) -> Bool {
        guard let data = pasteboard.data(forType: Self.annotationPasteboardType),
              let payload = try? JSONDecoder().decode(AnnotationClipboard.self, from: data),
              payload.isValid else { return false }
        let ids = Set(payload.shapes.map(\.id))
        let assetIDs = Set(payload.shapes.compactMap { $0.imageProps?.assetID })
        guard Set(payload.images.keys) == assetIDs else { return false }
        var assets: [String: AnnoImageAsset] = [:]
        var assetMap: [String: String] = [:]
        for id in assetIDs {
            guard let bytes = payload.images[id], let asset = AnnoImageAsset(data: bytes) else { return false }
            let newID = UUID().uuidString
            assetMap[id] = newID
            assets[newID] = asset
        }
        let previousCount = annotationPasteRun.flatMap {
            $0.board == pasteboard.name.rawValue && $0.change == pasteboard.changeCount ? $0.count : nil
        } ?? 0
        guard previousCount >= 0, Double(previousCount) < AnnotationClipboard.numericLimit / 20 else { return false }
        let count = previousCount + 1
        let offset = Double(count) * 20
        let idMap = Dictionary(uniqueKeysWithValues: ids.map { ($0, AnnoShapeID()) })
        let shapes = payload.shapes.map { original in
            var shape = original
            shape.id = idMap[original.id]!
            shape.x += offset
            shape.y += offset
            if case var .image(props) = shape.kind {
                props.assetID = assetMap[props.assetID]!
                shape.kind = .image(props)
            }
            return shape
        }
        guard shapes.allSatisfy({ AnnotationClipboard.isSafe($0) }) else { return false }
        let bindings = payload.bindings.map { original in
            var binding = original
            binding.arrowId = idMap[original.arrowId]!
            binding.toId = idMap[original.toId]!
            return binding
        }
        stopEditingText()
        markUndo()
        imageAssets.merge(assets) { _, new in new }
        document.restore(AnnoDocument.Snapshot(shapes: document.shapes + shapes,
                                               bindings: document.bindings + bindings))
        tool = .select
        selectedIds = Set(shapes.map(\.id))
        annotationPasteRun = (pasteboard.name.rawValue, pasteboard.changeCount, count)
        notifyChanged()
        return true
    }
}
