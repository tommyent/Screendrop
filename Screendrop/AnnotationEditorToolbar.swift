import SwiftUI

/// The editor's tools in the window toolbar, Shottr's way (sd-w8c): the
/// drawing tools in one glass group, then Crop, the eyedropper and the
/// ruler's hint in another.
struct AnnotationEditorToolbarTools: ToolbarContent {
    let model: AnnotationEditorModel
    @Bindable var probe: PixelProbe
    let isDisabled: Bool
    let onSelectTool: (AnnotationTool) -> Void
    let onCrop: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Group {
                ForEach([AnnotationTool.select] + AnnotationTool.paletteTools) { tool in
                    Toggle(isOn: Binding(
                        get: { model.selectedTool == tool && !probe.isPicking },
                        set: { _ in onSelectTool(tool) }
                    )) {
                        Label(tool.title, systemImage: tool.systemImage)
                    }
                    .help(tool.helpText)
                }
            }
            .disabled(isDisabled)
        }

        ToolbarSpacer(.fixed, placement: .principal)

        ToolbarItemGroup(placement: .principal) {
            Group {
                Button(action: onCrop) {
                    Label("Crop", systemImage: "crop")
                }
                .help("Crop the screenshot (C)")
                .disabled(model.previewImage == nil || model.imageSize == .zero)

                Toggle(isOn: $probe.isPicking) {
                    Label("Pick Color", systemImage: "eyedropper")
                }
                .help("Pick a colour: click the image to copy its hex. Tab copies the colour under the pointer any time.")

                AnnotationMeasureHintButton()
            }
            .disabled(isDisabled)
        }
    }
}

/// The ruler works by holding a key, so its button only says how.
private struct AnnotationMeasureHintButton: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Measure", systemImage: "ruler")
        }
        .help("How to measure")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hold an arrow key over the image")
                    .font(.headline)
                Text("← or → measures the width under the pointer, ↑ or ↓ the height. Add Shift to include the border. Click while holding to keep the measurement.")
                Text("With annotations selected, the arrow keys move them instead.")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 260, alignment: .leading)
            .padding(14)
        }
    }
}

/// The colour under the pointer, beside it, while the eyedropper is armed
/// or just after a copy.
struct PixelColorBadge: View {
    let color: PixelColor
    let copied: Bool

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(color))
                .frame(width: 14, height: 14)
                .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5) }
            Text(copied ? "Copied \(color.hex)" : color.hex)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copied ? "Copied \(color.hex)" : "Color under the pointer, \(color.hex)")
    }
}

extension Color {
    /// A screenshot pixel's sRGB colour.
    nonisolated init(_ pixel: PixelColor) {
        self.init(.sRGB, red: Double(pixel.red) / 255, green: Double(pixel.green) / 255,
                  blue: Double(pixel.blue) / 255, opacity: Double(pixel.alpha) / 255)
    }
}
