import AppKit
import Foundation

private struct AnnotationClipboard: Codable {
    var shapes: [AnnoShape]
    var bindings: [ArrowBinding]
    var images: [String: Data]
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
            if let binding = info.bindings.start, !ids.contains(binding.toId) { props.start = info.start.point }
            if let binding = info.bindings.end, !ids.contains(binding.toId) { props.end = info.end.point }
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
              !payload.shapes.isEmpty else { return false }
        let ids = Set(payload.shapes.map(\.id))
        guard ids.count == payload.shapes.count,
              payload.shapes.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.rotation.isFinite }),
              payload.bindings.allSatisfy({ ids.contains($0.arrowId) && ids.contains($0.toId) }) else { return false }
        let assetIDs = Set(payload.shapes.compactMap { $0.imageProps?.assetID })
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
