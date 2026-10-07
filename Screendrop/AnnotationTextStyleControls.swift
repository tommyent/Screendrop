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
                            // A named face has no bold or italic of its own, and none is
                            // synthesized; the setting is kept for when the font changes back.
                            let isInert = model.selectedTextFontFace != nil && segment != .underline
                            Text(segment.title)
                                .font(segment.font)
                                .underline(segment == .underline)
                                .opacity(isInert ? 0.35 : 1)
                                .help(isInert ? "Not available in this font" : "")
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

    private var fontFamilyMenu: some View {
        Menu {
            ForEach(AnnoFontFamily.allCases) { family in
                fontMenuItem(
                    family.title,
                    isSelected: model.selectedTextFontFace == nil && model.selectedTextFontFamily == family
                ) {
                    model.setTextFont(family)
                }
            }
            fontMenuItem(
                AnnoFontFace.title(AnnoFontFace.markerFelt),
                isSelected: model.selectedTextFontFace == AnnoFontFace.markerFelt
            ) {
                model.setTextFont(.pro, face: AnnoFontFace.markerFelt)
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.selectedTextFontFace.map { AnnoFontFace.title($0) } ?? model.selectedTextFontFamily.title)
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

    private func fontMenuItem(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
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
