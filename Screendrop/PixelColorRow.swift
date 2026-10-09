import SwiftUI

/// The colour under the pointer, under the editor's tool grid (sd-t4k): a
/// swatch, its hex, and the Tab hint, like Shottr's toolbar readout. Reads
/// the window's `PixelProbe` from the environment.
struct PixelColorRow: View {
    @Environment(PixelProbe.self) private var probe: PixelProbe?

    var body: some View {
        let color = probe?.hovered
        InspectorRow("Color") {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.map(Color.init) ?? .clear)
                    .frame(width: 14, height: 14)
                    .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5) }
                Text(color?.hex ?? "—")
                    .font(.inspectorNumeric)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Text(probe?.copiedHex != nil ? "Copied" : "Tab to copy")
                    .font(.inspectorLabel)
                    .foregroundStyle(.secondary)
                    .opacity(color == nil && probe?.copiedHex == nil ? 0 : 1)
            }
        }
        .help("The colour under the pointer. Tab copies its hex.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(color.map { "Color under the pointer, \($0.hex)" } ?? "Color under the pointer, none")
    }
}

extension Color {
    /// A screenshot pixel's sRGB colour.
    nonisolated init(_ pixel: PixelColor) {
        self.init(.sRGB, red: Double(pixel.red) / 255, green: Double(pixel.green) / 255,
                  blue: Double(pixel.blue) / 255, opacity: Double(pixel.alpha) / 255)
    }
}
