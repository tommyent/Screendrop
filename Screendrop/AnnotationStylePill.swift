import SwiftUI

/// Colour and size for lines and text in one capsule, as in Shottr (sd-z4f).
/// The tool dock shows the current colour; clicking it opens the pill, which
/// styles the selection, or the armed tool when nothing is selected.
struct AnnotationStylePillButton: View {
    @Bindable var model: AnnotationEditorModel
    @State private var isPresented = false

    private var isAvailable: Bool { model.isColorStyleAvailable || model.isTextStyleAvailable }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Circle()
                .fill(model.selectedSwatch.color)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                .frame(width: 16, height: 16)
                .opacity(isAvailable ? 1 : 0.35)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .help("Colour and size")
        .accessibilityLabel("Colour and size, \(model.selectedSwatch.title)")
        .closesOnEditorEscape($isPresented)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            HStack(spacing: 12) {
                AnnotationSwatchStrip(
                    selectedSwatch: model.selectedSwatch,
                    columnCount: AnnotationSwatch.allCases.count + 1
                ) { swatch in
                    model.setSwatch(swatch)
                }
                .fixedSize()

                if model.isTextStyleAvailable {
                    TaperedSlider(
                        title: "Text size",
                        value: model.selectedTextFontSize,
                        stops: AnnotationSizeStops.textSizes,
                        onEditing: model.setInspectorEditing
                    ) { model.selectedTextFontSize = $0 }

                    InspectorSegmented(
                        options: TextBoxStyle.allCases,
                        isSelected: { $0 == model.selectedTextBoxStyle },
                        onTap: { model.selectedTextBoxStyle = $0 },
                        label: { style in
                            TextBoxStyleIcon(style: style)
                                .help(style.title)
                                .accessibilityLabel(style.title)
                        },
                        height: InspectorMetrics.controlHeight
                    )
                    .frame(width: 64)
                } else if model.isStrokeStyleAvailable {
                    TaperedSlider(
                        title: "Line width",
                        value: model.strokeWidth,
                        stops: AnnotationSizeStops.lineWidths,
                        onEditing: model.setInspectorEditing
                    ) { model.setStrokeWidth($0) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

/// Shottr's size slider: a wedge that widens to the right, under a round
/// thumb. Drags and arrow keys use the same discrete size stops.
private struct TaperedSlider: View {
    let title: String
    let value: CGFloat
    let stops: [CGFloat]
    /// One undo step per drag.
    let onEditing: (Bool) -> Void
    let onChange: (CGFloat) -> Void

    @State private var isDragging = false
    @FocusState private var isFocused: Bool

    private let width: CGFloat = 120
    private let height: CGFloat = 20
    private let thumb: CGFloat = 16

    var body: some View {
        let fraction = AnnotationSizeStops.fraction(for: value, in: stops)
        ZStack(alignment: .leading) {
            Path { path in
                path.move(to: CGPoint(x: thumb / 2, y: height / 2 - 1))
                path.addLine(to: CGPoint(x: width - thumb / 2, y: 2))
                path.addLine(to: CGPoint(x: width - thumb / 2, y: height - 2))
                path.addLine(to: CGPoint(x: thumb / 2, y: height / 2 + 1))
                path.closeSubpath()
            }
            .fill(Color.secondary.opacity(0.45))

            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                .frame(width: thumb, height: thumb)
                .offset(x: fraction * (width - thumb))
        }
        .frame(width: width, height: height)
        .overlay {
            if isFocused {
                Capsule().stroke(Color.accentColor.opacity(0.72), lineWidth: 1).padding(-3)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !isDragging {
                        isDragging = true
                        onEditing(true)
                    }
                    let f = min(max((drag.location.x - thumb / 2) / (width - thumb), 0), 1)
                    let next = AnnotationSizeStops.value(at: f, in: stops)
                    if next != value { onChange(next) }
                }
                .onEnded { _ in endDrag() }
        )
        // A drag cut short when the popover closes still ends its undo step.
        .onDisappear(perform: endDrag)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.leftArrow) {
            step(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            step(1)
            return .handled
        }
        .help("\(title): \(Int(value))")
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(value))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private func step(_ delta: Int) {
        let next = AnnotationSizeStops.step(from: value, by: delta, in: stops)
        if next != value { onChange(next) }
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        onEditing(false)
    }
}
