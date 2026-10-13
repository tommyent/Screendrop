import AppKit
import SwiftUI

/// The editor's tools in one glass capsule floating over the top of the
/// canvas (sd-w8c), upstream's dock moved up: the drawing tools grouped by
/// what they make, then Crop, the eyedropper and the ruler, then the
/// colour and size pill (sd-z4f). A zoomed-in image slides under it.
struct AnnotationToolDock: View {
    let model: AnnotationEditorModel
    @Bindable var probe: PixelProbe
    let isDisabled: Bool
    let onSelectTool: (AnnotationTool) -> Void
    let onCrop: () -> Void

    static let height: CGFloat = 44
    static let topPadding: CGFloat = 12
    /// Height the canvas keeps clear at its top: the dock, the gap above it
    /// and a little air below, so an image scrolled to its top starts clear.
    static let canvasReserve: CGFloat = topPadding + height + 8

    private static let groups: [[AnnotationTool]] = [
        [.select],
        [.rectangle, .ellipse, .highlight],
        [.arrow, .line, .freehand],
        [.text, .numberedCircle, .magnifier],
        [.pixelate, .blur],
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { separator }
                ForEach(group) { tool in
                    AnnotationDockButton(
                        systemImage: tool.systemImage,
                        title: tool.title,
                        help: tool.helpText,
                        isSelected: model.selectedTool == tool && !probe.isPicking && !probe.isMeasuringTool
                    ) {
                        onSelectTool(tool)
                    }
                }
            }

            separator

            AnnotationDockButton(
                systemImage: "crop",
                title: "Crop",
                help: "Crop the screenshot (C). ⌘-click the image to crop to the box under the pointer."
            ) {
                onCrop()
            }
            .disabled(model.previewImage == nil || model.imageSize == .zero)

            AnnotationDockButton(
                systemImage: "eyedropper",
                title: "Pick Color",
                help: "Pick a colour: click the image to copy its hex. Tab copies the colour under the pointer any time.",
                isSelected: probe.isPicking
            ) {
                probe.isPicking.toggle()
                // Escape disarms it only if no inspector field has the keyboard.
                if probe.isPicking { NSApp.keyWindow?.makeFirstResponder(nil) }
            }

            AnnotationDockButton(
                systemImage: "ruler",
                title: "Measure",
                help: "Measure: point at the image for the width and height under the pointer. Or hold 1 (height) or 2 (width) with any tool.",
                isSelected: probe.isMeasuringTool
            ) {
                probe.isMeasuringTool.toggle()
                if probe.isMeasuringTool { NSApp.keyWindow?.makeFirstResponder(nil) }
            }

            separator

            AnnotationStylePillButton(model: model)
                .frame(width: 34, height: 34)
        }
        .padding(.horizontal, 5)
        .frame(height: Self.height)
        .glassEffect(.regular, in: .capsule)
        .disabled(isDisabled)
        .motion(.morphQuick, value: model.selectedTool)
    }

    private var separator: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(width: 1, height: 18)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
    }
}

/// One round dock button; the selected one is inked (upstream's dock).
struct AnnotationDockButton: View {
    let systemImage: String
    let title: String
    let help: String
    var isSelected = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Palette.onAccent : Palette.label)
                .frame(width: 34, height: 34)
                .background {
                    Circle()
                        .fill(isSelected ? Palette.accent : isHovering ? Palette.hoverFill : .clear)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

/// An editor popover doesn't take the keyboard, so Escape reaches the
/// editor while one is open and used to disarm the tool or clear the
/// selection behind it. Open popovers register here, and Escape closes
/// the newest one instead.
enum EditorPopovers {
    private static var open: [(id: UUID, close: () -> Void)] = []

    static func closeNewest() -> Bool {
        guard let newest = open.popLast() else { return false }
        newest.close()
        return true
    }

    fileprivate static func set(_ id: UUID, close: (() -> Void)?) {
        open.removeAll { $0.id == id }
        if let close { open.append((id, close)) }
    }
}

extension View {
    /// Lets Escape in the editor close this popover first.
    func closesOnEditorEscape(_ isPresented: Binding<Bool>) -> some View {
        modifier(EditorPopoverEscape(isPresented: isPresented))
    }
}

private struct EditorPopoverEscape: ViewModifier {
    @Binding var isPresented: Bool
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented, initial: true) { _, isShown in
                EditorPopovers.set(id, close: isShown ? { isPresented = false } : nil)
            }
            .onDisappear { EditorPopovers.set(id, close: nil) }
    }
}
