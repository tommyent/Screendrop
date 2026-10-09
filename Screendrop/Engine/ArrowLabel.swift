import CoreGraphics
import Foundation

/// Shared positioning for the arrow's painted label and its grab area.
enum ArrowLabel {
    static func layout(_ props: ArrowProps, midpoint: Vec, rotation: Double) -> (text: TextProps, transform: Mat)? {
        guard let label = props.label, !label.isEmpty else { return nil }
        var text = TextProps()
        text.text = label
        text.fontSize = 24
        text.swatch = props.swatch
        text.boxStyle = .box
        let rect = TextMeasure.outerRect(text)
        // Counter-rotate so a vertical or rotated measurement still has a horizontal label.
        let transform = Mat.multiply(
            Mat.compose(x: midpoint.x, y: midpoint.y, rotation: -rotation),
            Mat.translate(-rect.midX, -rect.midY)
        )
        return (text, transform)
    }
}
