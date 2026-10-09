import Foundation

extension AnnoEditor {
    /// Imprints an arrow-key measurement (sd-p31) on the screenshot: a line
    /// with a bar at each end from `start` to `end` in page space, labelled
    /// with its length, in the current colour and stroke. One annotation and
    /// one undo step, left unselected: a selection would turn the still-held
    /// arrow key's repeats into nudges (sd-xoh). The second click of a
    /// double-click belongs to the first stamp and adds nothing.
    func imprintMeasurement(from start: Vec, to end: Vec, label: String, clickCount: Int = 1) {
        guard clickCount < 2 else { return }
        markUndo()
        var props = ArrowProps()
        props.swatch = currentSwatch
        props.strokeWidth = pageStrokeWidth(currentStrokeWidth)
        props.arrowheadStart = .bar
        props.arrowheadEnd = .bar
        props.start = Vec(0, 0)
        props.end = Vec.sub(end, start)
        props.label = label
        document.add(AnnoShape(x: start.x, y: start.y, kind: .arrow(props)))
        notifyChanged()
    }
}
