//
//  AnnotationBackgroundInspector.swift
//  Screendrop
//

import AppKit
import SwiftUI

private enum AnnotationBackgroundFillLibrary: CaseIterable, Hashable {
    case color
    case gradient
    case wallpaper

    var title: String {
        switch self {
        case .color: "Color"
        case .gradient: "Gradient"
        case .wallpaper: "Wallpaper"
        }
    }
}

/// The Background section (upstream v0.35's Frame): the fill as one row
/// that opens the full picker beside the inspector, then the canvas shape,
/// padding, corners, shadow and alignment.
struct AnnotationBackgroundInspector: View {
    @Binding var settings: AnnotationBackgroundSettings
    @Bindable var wallpaperStore: AnnotationWallpaperStore
    let onEditorAction: () -> Void
    let onPickWallpaper: () -> Void
    let onPreview: (AnnotationBackgroundStyle, Bool) -> Void
    let onEndPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorBackgroundRow(
                style: $settings.style,
                rememberedWallpaper: settings.customWallpaper,
                wallpaperStore: wallpaperStore,
                onEditorAction: onEditorAction,
                onPickWallpaper: onPickWallpaper,
                onSelectWallpaper: { settings.customWallpaper = $0 },
                onPreview: onPreview,
                onEndPreview: onEndPreview
            )

            if !settings.requiresCanvasLayout {
                InspectorHint("Pick a background to frame the screenshot.")
            }

            frameControls
                // Without a canvas there is nothing to shape, pad, round or
                // shadow. Dimmed rather than hidden, so picking a fill
                // doesn't shift the list.
                .disabled(!settings.requiresCanvasLayout)
                .opacity(settings.requiresCanvasLayout ? 1 : 0.4)
        }
    }

    private var frameControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSegmented(
                options: AnnotationBackgroundAspectRatio.allCases,
                isSelected: { $0 == settings.aspectRatio },
                onTap: {
                    onEditorAction()
                    settings.aspectRatio = $0
                },
                label: { ratio in
                    Text(ratio.title)
                        .font(.inspectorSegment)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            )

            InspectorFieldPair {
                InspectorSlider(
                    "Padding",
                    value: $settings.padding,
                    range: 0.04...0.45,
                    format: .percent()
                )
            } trailing: {
                InspectorSlider(
                    "Corners",
                    value: $settings.cornerRadius,
                    range: 0...0.12,
                    format: .percent()
                )
            }

            InspectorSlider(
                "Shadow",
                value: $settings.shadow,
                range: 0...1,
                format: .percent()
            )

            InspectorSegmented(
                options: AnnotationShadowStyle.allCases,
                isSelected: { $0 == settings.shadowStyle },
                onTap: {
                    onEditorAction()
                    settings.shadowStyle = $0
                },
                label: { style in
                    Text(style.title)
                        .font(.inspectorSegment)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            )
            .opacity(settings.shadow > 0 ? 1 : 0.45)

            InspectorRow("Alignment") {
                AlignmentPositionPicker(
                    alignment: $settings.alignment,
                    isEnabled: !settings.camera.hasEffect,
                    onEditorAction: onEditorAction
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

extension AnnotationBackgroundStyle {
    var displayTitle: String {
        switch self {
        case .none: "None"
        case .solid(let color): color.title
        case .gradient(let gradient): gradient.title
        case .customWallpaper(let wallpaper): wallpaper.title
        }
    }
}

/// A background drawn small: the fill itself, or a quiet empty well for none.
struct BackgroundSwatch: View {
    let style: AnnotationBackgroundStyle

    var body: some View {
        switch style {
        case .none:
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .overlay {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
        case .solid(let color):
            Rectangle().fill(color.color)
        case .gradient(let gradient):
            Rectangle().fill(LinearGradient(
                colors: gradient.colors.map(\.color),
                startPoint: gradient.startPoint,
                endPoint: gradient.endPoint
            ))
        case .customWallpaper(let wallpaper):
            AnnotationCustomWallpaperPreview(wallpaper: wallpaper, maxPixelSize: 320)
        }
    }
}

/// The background as one row: its swatch and name. The full picker opens
/// beside the inspector, over the canvas, so hovering a fill shows it on the
/// screenshot right there.
struct InspectorBackgroundRow: View {
    @Binding var style: AnnotationBackgroundStyle
    var rememberedWallpaper: AnnotationCustomWallpaper? = nil
    @Bindable var wallpaperStore: AnnotationWallpaperStore
    var onEditorAction: () -> Void = {}
    let onPickWallpaper: () -> Void
    var onSelectWallpaper: (AnnotationCustomWallpaper) -> Void = { _ in }
    /// A fill the pointer enters (true) or leaves (false).
    let onPreview: (AnnotationBackgroundStyle, Bool) -> Void
    /// The picker closed: drop any preview.
    let onEndPreview: () -> Void

    @State private var isPickerPresented = false
    @State private var isHovering = false

    var body: some View {
        Button {
            onEditorAction()
            isPickerPresented = true
        } label: {
            HStack(spacing: 8) {
                BackgroundSwatch(style: style)
                    .frame(width: 26, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    }

                Text(style.displayTitle)
                    .font(.inspectorValue)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 7)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .inspectorField()
            .overlay {
                if isHovering || isPickerPresented {
                    RoundedRectangle(cornerRadius: InspectorMetrics.fieldRadius, style: .continuous)
                        .fill(InspectorControlPalette.hoverFill)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Choose a background")
        .accessibilityLabel("Background")
        .accessibilityValue(style.displayTitle)
        .popover(isPresented: $isPickerPresented, arrowEdge: .leading) {
            // No title: the row it hangs off already says Background, and
            // the picker's own No Background tile replaces upstream's None.
            InspectorBackgroundFillPicker(
                style: $style,
                rememberedWallpaper: rememberedWallpaper,
                wallpaperStore: wallpaperStore,
                onEditorAction: onEditorAction,
                onPickWallpaper: {
                    isPickerPresented = false
                    onPickWallpaper()
                },
                onSelectWallpaper: onSelectWallpaper,
                onPreview: onPreview
            )
            .padding(14)
            .frame(width: 320)
            .background(Palette.panel)
            .presentationBackground(Palette.panel)
            .onDisappear(perform: onEndPreview)
        }
    }
}

/// The background fill browser shared by the annotator and Studio: a
/// Color / Gradient / Wallpaper library switch over tile grids, with recent
/// wallpapers, built-in packs and an add tile.
struct InspectorBackgroundFillPicker: View {
    @Binding var style: AnnotationBackgroundStyle
    /// A wallpaper to keep visible in Recent even when the fill is currently
    /// a color or gradient.
    let rememberedWallpaper: AnnotationCustomWallpaper?
    @Bindable var wallpaperStore: AnnotationWallpaperStore
    let onEditorAction: () -> Void
    let onPickWallpaper: () -> Void
    var onSelectWallpaper: (AnnotationCustomWallpaper) -> Void = { _ in }
    /// Called as the pointer enters (true) and leaves (false) a fill, so a
    /// host can show it before it is picked.
    var onPreview: ((AnnotationBackgroundStyle, Bool) -> Void)? = nil

    private let swatchColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)
    private static let maxVisibleRecentWallpapers = 4
    private let recentWallpaperColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)
    @State private var selectedFillLibrary = AnnotationBackgroundFillLibrary.color

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            HStack(spacing: 6) {
                // Sits outside the library tabs so it's reachable whichever
                // tab the current fill came from.
                InspectorTile(title: "No background", isSelected: style == .none) {
                    onEditorAction()
                    style = .none
                } content: {
                    Rectangle()
                        .fill(Color.white)
                        .overlay {
                            Canvas { context, size in
                                var slash = Path()
                                slash.move(to: CGPoint(x: size.width, y: 0))
                                slash.addLine(to: CGPoint(x: 0, y: size.height))
                                context.stroke(slash, with: .color(.red), lineWidth: 1.5)
                            }
                        }
                }
                .frame(width: InspectorMetrics.controlHeight, height: InspectorMetrics.controlHeight)

                InspectorSegmented(
                    options: AnnotationBackgroundFillLibrary.allCases,
                    isSelected: { $0 == selectedFillLibrary },
                    onTap: { library in
                        withAnimation(.snappy(duration: 0.16)) {
                            selectedFillLibrary = library
                        }
                    },
                    label: { library in
                        Text(library.title)
                            .font(.inspectorSegment)
                    }
                )
            }

            selectedFillPicker
                .transition(.opacity)
        }
        .onAppear {
            syncFillLibrary(with: style)
        }
        .onChange(of: style) { _, style in
            syncFillLibrary(with: style)
        }
    }

    private var customWallpaper: AnnotationCustomWallpaper? {
        if case .customWallpaper(let wallpaper) = style {
            return wallpaper
        }
        return rememberedWallpaper
    }

    @ViewBuilder
    private var selectedFillPicker: some View {
        switch selectedFillLibrary {
        case .color:
            LazyVGrid(columns: swatchColumns, spacing: 6) {
                ForEach(AnnotationBackgroundColor.plainPresets) { color in
                    InspectorTile(title: color.title, isSelected: style == .solid(color)) {
                        onEditorAction()
                        style = .solid(color)
                    } content: {
                        Rectangle().fill(color.color)
                    }
                    .onHover { onPreview?(.solid(color), $0) }
                }
                InspectorCustomBackgroundColorTile(style: $style, onSelect: onEditorAction)
            }

        case .gradient:
            LazyVGrid(columns: swatchColumns, spacing: 6) {
                ForEach(AnnotationBackgroundGradient.presets) { gradient in
                    InspectorTile(title: gradient.title, isSelected: style == .gradient(gradient)) {
                        onEditorAction()
                        style = .gradient(gradient)
                    } content: {
                        Rectangle().fill(LinearGradient(
                            colors: gradient.colors.map(\.color),
                            startPoint: gradient.startPoint,
                            endPoint: gradient.endPoint
                        ))
                    }
                    .onHover { onPreview?(.gradient(gradient), $0) }
                }
            }

        case .wallpaper:
            wallpaperGroup
        }
    }

    private func syncFillLibrary(with style: AnnotationBackgroundStyle) {
        switch style {
        case .none:
            break
        case .solid:
            selectedFillLibrary = .color
        case .gradient:
            selectedFillLibrary = .gradient
        case .customWallpaper:
            selectedFillLibrary = .wallpaper
        }
    }

    private var wallpaperGroup: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
            recentWallpaperGrid
            UnsplashWallpaperSearchView(search: UnsplashWallpaperSearch.shared) { url in
                selectWallpaper(AnnotationCustomWallpaper(url: url))
            }
        }
    }

    private var visibleRecentWallpapers: [AnnotationCustomWallpaper] {
        var wallpapers = wallpaperStore.recentWallpapers
        if let customWallpaper, wallpaperStore.isAvailable(customWallpaper) {
            let selectedURL = customWallpaper.url.standardizedFileURL
            if let selectedIndex = wallpapers.firstIndex(where: {
                $0.url.standardizedFileURL == selectedURL
            }) {
                if selectedIndex >= Self.maxVisibleRecentWallpapers {
                    wallpapers.remove(at: selectedIndex)
                    wallpapers.insert(customWallpaper, at: 0)
                }
            } else {
                wallpapers.insert(customWallpaper, at: 0)
            }
        }
        return Array(wallpapers.prefix(Self.maxVisibleRecentWallpapers))
    }

    private var recentWallpaperGrid: some View {
        LazyVGrid(columns: recentWallpaperColumns, spacing: 6) {
            wallpaperTiles(visibleRecentWallpapers)

            AnnotationAddWallpaperTile {
                onEditorAction()
                onPickWallpaper()
            }
                .help("Choose wallpaper")
        }
    }

    @ViewBuilder
    private func wallpaperTiles(_ wallpapers: [AnnotationCustomWallpaper]) -> some View {
        ForEach(wallpapers) { wallpaper in
            InspectorTile(
                title: wallpaper.title,
                aspectRatio: 1.35,
                isSelected: isSelectedWallpaper(wallpaper)
            ) {
                selectWallpaper(wallpaper)
            } content: {
                AnnotationCustomWallpaperPreview(wallpaper: wallpaper)
            }
            .onHover { onPreview?(.customWallpaper(wallpaper), $0) }
        }
    }

    private func selectWallpaper(_ wallpaper: AnnotationCustomWallpaper) {
        onEditorAction()
        wallpaperStore.addRecentWallpaper(wallpaper.url)
        onSelectWallpaper(wallpaper)
        style = .customWallpaper(wallpaper)
    }

    private func isSelectedWallpaper(_ wallpaper: AnnotationCustomWallpaper) -> Bool {
        guard case .customWallpaper(let selectedWallpaper) = style else { return false }
        return selectedWallpaper.url.standardizedFileURL == wallpaper.url.standardizedFileURL
    }

}

struct AnnotationWatermarkInspector: View {
    @Binding var settings: AnnotationWatermarkSettings
    let focusedField: FocusState<AnnotationEditorFocusedField?>.Binding
    let onFocusCleared: () -> Void

    /// The watermark stores its own color type; the shared swatch strip
    /// speaks `AnnotationSwatch`, so presets match by value and anything else
    /// shows in the custom well.
    private var watermarkSwatch: AnnotationSwatch {
        let color = settings.color
        return AnnotationSwatch.allCases.first {
            abs($0.red - color.red) < 0.002
                && abs($0.green - color.green) < 0.002
                && abs($0.blue - color.blue) < 0.002
        } ?? .custom(from: color.nsColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            // The section's switch alone turns the watermark on or off;
            // empty text just draws nothing yet (upstream 28ec23e).
            watermarkTextField

            if hasWatermarkText {
                VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                    InspectorFieldPair {
                        InspectorSlider(
                            "Density",
                            value: $settings.density,
                            range: 2...10,
                            format: .integer
                        )
                    } trailing: {
                        InspectorSlider(
                            "Size",
                            value: $settings.fontSize,
                            range: 8...160,
                            format: .pixels
                        )
                    }

                    InspectorFieldPair {
                        InspectorSlider(
                            "Angle",
                            value: $settings.rotationDegrees,
                            range: -90...90,
                            format: .degrees()
                        )
                    } trailing: {
                        InspectorSlider(
                            "Opacity",
                            value: $settings.opacity,
                            range: 0...0.75,
                            format: .percent()
                        )
                    }

                    InspectorRow("Color") {
                        AnnotationSwatchStrip(selectedSwatch: watermarkSwatch) { swatch in
                            settings.color = AnnotationWatermarkColor(
                                red: swatch.red,
                                green: swatch.green,
                                blue: swatch.blue
                            )
                        }
                    }
                }
            }
        }
        .onAppear {
            // Switched on with nothing to show yet: start typing straight away.
            if !hasWatermarkText { focusedField.wrappedValue = .watermarkText }
        }
    }

    private var watermarkTextField: some View {
        TextField("Watermark text", text: $settings.text)
            .focused(focusedField, equals: .watermarkText)
            .onSubmit(finishTextEditing)
            .textFieldStyle(.plain)
            .font(.inspectorValue)
            .padding(.horizontal, 8)
            .inspectorField()
            .onClickOutside(enabled: focusedField.wrappedValue == .watermarkText, perform: finishTextEditing)
    }

    private var hasWatermarkText: Bool {
        !settings.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func finishTextEditing() {
        focusedField.wrappedValue = nil
        onFocusCleared()
    }

}

private struct AnnotationAddWallpaperTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                .foregroundStyle(.quaternary)
                .aspectRatio(1.35, contentMode: .fit)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(2.5)
                .contentShape(RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct AlignmentPositionPicker: View {
    @Binding var alignment: AnnotationBackgroundAlignment
    let isEnabled: Bool
    let onEditorAction: () -> Void

    private let size: CGFloat = 44
    private let markerSize: CGFloat = 6
    private let cellSize: CGFloat = 12
    private let spacing: CGFloat = 2

    @State private var hoveredAlignment: AnnotationBackgroundAlignment?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: InspectorMetrics.sliderRadius,
            style: .continuous
        )
        let columns = Array(
            repeating: GridItem(.fixed(cellSize), spacing: spacing),
            count: 3
        )

        LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(AnnotationBackgroundAlignment.allCases) { option in
                Button {
                    onEditorAction()
                    withAnimation(accessibilityReduceMotion ? nil : .snappy(duration: 0.18)) {
                        alignment = option
                    }
                } label: {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(markerFill(for: option))
                        .frame(width: markerSize, height: markerSize)
                        .frame(width: cellSize, height: cellSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(!isEnabled)
                .help(option.title)
                .onHover { isHovering in
                    guard isEnabled else {
                        hoveredAlignment = nil
                        return
                    }
                    if isHovering {
                        hoveredAlignment = option
                    } else if hoveredAlignment == option {
                        hoveredAlignment = nil
                    }
                }
                .accessibilityLabel("\(option.title) alignment")
                .accessibilityValue(displayedAlignment == option ? "Selected" : "")
                .accessibilityAddTraits(displayedAlignment == option ? .isSelected : [])
            }
        }
        .padding(InspectorMetrics.controlInset)
        .frame(width: size, height: size)
        .background(shape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
        .clipShape(shape)
        .opacity(isEnabled ? 1 : 0.46)
        .help(isEnabled ? "Image alignment" : "Reset Camera to use alignment")
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                hoveredAlignment = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image alignment")
    }

    private var displayedAlignment: AnnotationBackgroundAlignment {
        isEnabled ? alignment : .center
    }

    private func markerFill(for option: AnnotationBackgroundAlignment) -> Color {
        if displayedAlignment == option {
            return InspectorControlPalette.selectedForeground
        }
        if hoveredAlignment == option {
            return Color.primary.opacity(0.48)
        }
        return Color.primary.opacity(0.22)
    }
}
