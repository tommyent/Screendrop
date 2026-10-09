import Foundation

extension AnnoEditor {
    /// Imprints an arrow-key measurement (sd-p31) on the screenshot: a line
    /// with a bar at each end from `start` to `end` in page space, in the
    /// current colour and stroke. One undo step, and left selected.
    func imprintMeasurement(from start: Vec, to end: Vec) {
        markUndo()
        var props = ArrowProps()
        props.swatch = currentSwatch
        props.strokeWidth = pageStrokeWidth(currentStrokeWidth)
        props.arrowheadStart = .bar
        props.arrowheadEnd = .bar
        props.start = Vec(0, 0)
        props.end = Vec.sub(end, start)
        let shape = AnnoShape(x: start.x, y: start.y, kind: .arrow(props))
        document.add(shape)
        selectedIds = [shape.id]
        notifyChanged()
    }
}
