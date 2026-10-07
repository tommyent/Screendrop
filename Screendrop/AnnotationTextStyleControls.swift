//
//  AnnotationTextStyleControls.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct AnnotationTextStyleControls: View {
    @Bindable var model: AnnotationEditorModel
    @State private var fontSizeText = ""
    @FocusState private var isFontSizeFieldFocused: Bool

    var body: some View {
        VStack(spacing: InspectorMetrics.rowSpacing) {
            fontFamilyMenu
                .frame(minWidth: 0, maxWidth: .infinity)

            AnnotationSwatchStrip(selectedSwatch: model.selectedSwatch) { swatch in
                model.setSwatch(swatch)
            }

            if model.selectedTextBoxStyle == .box {
                boxTextColorRow
            }

            HStack(spacing: 6) {
                fontSizeStepper

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    InspectorSegmented(
                        options: TextBoxStyle.allCases,
                        isSelected: { $0 == model.selectedTextBoxStyle },
                        onTap: { model.selectedTextBoxStyle = $0 },
                        label: { style in
                            TextBoxStyleIcon(style: style)
                                .help(style.title)
                                .accessibilityLabel(style.title)
                        }
                    )
                    .frame(width: Self.segmentWidth * 2 + InspectorMetrics.controlInset * 2)

                    InspectorSegmented(
                        options: TextStyleSegment.allCases,
                        isSelected: { segment in
                            switch segment {
                            case .bold: model.selectedTextIsBold
                            case .italic: model.selectedTextIsItalic
                            case .underline: model.selectedTextIsUnderline
                            }
                        },
                        onTap: { segment in
                            switch segment {
                            case .bold: model.selectedTextIsBold.toggle()
                            case .italic: model.selectedTextIsItalic.toggle()
                            case .underline: model.selectedTextIsUnderline.toggle()
                            }
                        },
                        label: { segment in
                            Text(segment.title)
                                .font(segment.font)
                                .underline(segment == .underline)
                        }
                    )
                    .frame(width: Self.segmentWidth * 3 + InspectorMetrics.controlInset * 2)
                }
            }

            InspectorSegmented(
                options: TextAlignmentSegment.allCases,
                isSelected: { $0 == TextAlignmentSegment(model.selectedTextAlignment) },
                onTap: { model.selectedTextAlignment = $0.nsTextAlignment },
                label: { segment in
                    Image(systemName: segment.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
            )
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: syncFontSizeText)
        .onDisappear(perform: commitFontSizeText)
        .onChange(of: model.selectedTextFontSize) { _, _ in
            guard !isFontSizeFieldFocused else { return }
            syncFontSizeText()
        }
        .onChange(of: model.selectionCount) { _, _ in
            guard !isFontSizeFieldFocused else { return }
            syncFontSizeText()
        }
        .onChange(of: isFontSizeFieldFocused) { _, isFocused in
            if isFocused {
                syncFontSizeText()
            } else {
                commitFontSizeText()
            }
        }
    }

    /// One segment of the plain/box toggle and of B/I/U, so the two read as one row of equal
    /// buttons. Sized so stepper, toggle and B/I/U fit the inspector's narrowest column (260 pt,
    /// 236 pt of content): measured at 234 pt.
    private static let segmentWidth: CGFloat = 26

    /// The text colour on a box: automatic black or white first, then the same swatches and
    /// custom well as the box colour above it.
    private var boxTextColorRow: some View {
        HStack(spacing: 6) {
            Text("Text")
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)

            Button {
                model.selectedBoxTextSwatch = nil
            } label: {
                AutomaticInkChip(
                    box: model.selectedSwatch,
                    ink: model.automaticBoxTextSwatch,
                    isSelected: model.selectedBoxTextSwatch == nil
                )
            }
            .buttonStyle(.plain)
            .help("Automatic: black or white, whichever reads on the box")
            .accessibilityLabel("Automatic text colour")
            .accessibilityAddTraits(model.selectedBoxTextSwatch == nil ? .isSelected : [])

            AnnotationSwatchStrip(selectedSwatch: model.selectedBoxTextSwatch) { swatch in
                model.selectedBoxTextSwatch = swatch
            }
        }
    }

    private var fontFamilyMenu: some View {
        Menu {
            ForEach(AnnoFontFamily.allCases) { family in
                Button {
                    model.selectedTextFontFamily = family
                } label: {
                    if model.selectedTextFontFamily == family {
                        Label(family.title, systemImage: "checkmark")
                    } else {
                        Text(family.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.selectedTextFontFamily.title)
                    .font(.inspectorValue)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .inspectorField()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Font family")
    }

    private var fontSizeStepper: some View {
        HStack(spacing: 0) {
            Button {
                adjustFontSize(by: -1)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 24, height: InspectorMetrics.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Divider().frame(height: 13)

            TextField("", text: $fontSizeText)
                .focused($isFontSizeFieldFocused)
                .onSubmit(commitFontSizeText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.inspectorNumeric)
                .frame(width: 30)

            Divider().frame(height: 13)

            Button {
                adjustFontSize(by: 1)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 24, height: InspectorMetrics.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .inspectorField()
    }

    private func syncFontSizeText() {
        fontSizeText = String(Int(model.selectedTextFontSize.rounded()))
    }

    private func commitFontSizeText() {
        let trimmedText = fontSizeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Double(trimmedText), size.isFinite else {
            syncFontSizeText()
            return
        }

        let clampedSize = AnnotationTextMetrics.clampedFontSize(CGFloat(size.rounded()))
        model.selectedTextFontSize = clampedSize
        fontSizeText = String(Int(clampedSize))
    }

    private func adjustFontSize(by delta: CGFloat) {
        commitFontSizeText()
        let size = max(model.selectedTextFontSize + delta, AnnotationTextMetrics.minimumFontSize)
        model.selectedTextFontSize = size
        syncFontSizeText()
    }
}

private extension TextBoxStyle {
    var title: String {
        switch self {
        case .plain: "Plain text"
        case .box: "Text on a box"
        }
    }
}

/// A "T" on its own, or knocked out of a filled square, in the segment's own colour so it follows
/// the selected and hover states like the other segments.
private struct TextBoxStyleIcon: View {
    let style: TextBoxStyle

    var body: some View {
        switch style {
        case .plain:
            Text("T")
                .font(.system(size: 12, weight: .bold))
        case .box:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .frame(width: 14, height: 14)
                .overlay {
                    Text("T")
                        .font(.system(size: 10, weight: .bold))
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}

/// The automatic text colour, previewed: an "A" in the ink it resolves to, on the box colour.
private struct AutomaticInkChip: View {
    let box: AnnotationSwatch
    let ink: AnnotationSwatch
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(box.color)
            .frame(width: 17, height: 17)
            .overlay {
                Text("A")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ink.color)
            }
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .padding(2.5)
            .overlay {
                if isSelected {
                    Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .contentShape(Circle().inset(by: -2))
    }
}

private enum TextStyleSegment: CaseIterable, Hashable {
    case bold
    case italic
    case underline

    var title: String {
        switch self {
        case .bold: "B"
        case .italic: "I"
        case .underline: "U"
        }
    }

    var font: Font {
        switch self {
        case .bold:
            .system(size: 12, weight: .bold)
        case .italic:
            .system(size: 12, weight: .regular, design: .serif).italic()
        case .underline:
            .system(size: 12, weight: .regular)
        }
    }
}

private enum TextAlignmentSegment: CaseIterable, Hashable {
    case left
    case center
    case right
    case justified

    init(_ alignment: NSTextAlignment) {
        switch alignment {
        case .center:
            self = .center
        case .right:
            self = .right
        case .justified:
            self = .justified
        default:
            self = .left
        }
    }

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
    }

    var systemImage: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justified: "text.justify.leading"
        }
    }
}
