//
//  AnnotationInspector.swift
//  Screendrop
//

import AppKit
import SwiftUI

// MARK: - Inspector

enum AnnotationEditorFocusedField: Hashable {
    case watermarkText
}

/// Sections that fold with a chevron rather than a feature switch.
private enum AnnotationInspectorAdvancedSection: String, Hashable, CaseIterable {
    case camera
}

private enum AnnotationInspectorSectionState {
    static let expandedSectionsKey = "annotationInspector.expandedAdvancedSections"

    static func loadExpandedSections() -> Set<AnnotationInspectorAdvancedSection> {
        let rawValues = UserDefaults.standard.stringArray(forKey: expandedSectionsKey) ?? []
        return Set(rawValues.compactMap(AnnotationInspectorAdvancedSection.init(rawValue:)))
    }

    static func saveExpandedSections(_ sections: Set<AnnotationInspectorAdvancedSection>) {
        UserDefaults.standard.set(sections.map(\.rawValue), forKey: expandedSectionsKey)
    }
}

struct AnnotationEditorInspector: View {
    @Bindable var model: AnnotationEditorModel
    @Bindable var wallpaperStore: AnnotationWallpaperStore
    @Bindable var backgroundPresetStore: AnnotationBackgroundPresetStore
    let focusedField: FocusState<AnnotationEditorFocusedField?>.Binding
    let onEditorAction: () -> Void
    let onPickWallpaper: () -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var expandedAdvancedSections: Set<AnnotationInspectorAdvancedSection> = AnnotationInspectorSectionState.loadExpandedSections()

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                AnnotationStyleStrip(
                    model: model,
                    presetStore: backgroundPresetStore,
                    onEditorAction: onEditorAction
                )

                // Only when the tool or selection has something to style:
                // colour and width live in the dock's colour pill.
                if model.hasInspectorStyleControls {
                    InspectorSection(accessibilityLabel: "Style") {
                        styleControls
                    }

                    InspectorSectionDivider()
                }

                InspectorSection(
                    "Background",
                    accessory: {
                        if !usesDefaultFrame {
                            InspectorResetButton(help: "Reset padding, corners, shadow and alignment") {
                                onEditorAction()
                                withAnimation(sectionAnimation) {
                                    let defaults = AnnotationBackgroundSettings()
                                    model.backgroundSettings.padding = defaults.padding
                                    model.backgroundSettings.cornerRadius = defaults.cornerRadius
                                    model.backgroundSettings.shadow = defaults.shadow
                                    model.backgroundSettings.shadowStyle = defaults.shadowStyle
                                    model.backgroundSettings.alignment = defaults.alignment
                                }
                            }
                        }
                        if model.backgroundSettings.style != .none {
                            InspectorClearButton(help: "Remove background") {
                                onEditorAction()
                                model.backgroundSettings.style = .none
                            }
                        }
                    }
                ) {
                    AnnotationBackgroundInspector(
                        settings: Binding(
                            get: { model.backgroundSettings },
                            set: { model.backgroundSettings = $0 }
                        ),
                        wallpaperStore: wallpaperStore,
                        onEditorAction: onEditorAction,
                        onPickWallpaper: onPickWallpaper,
                        onPreview: { model.previewBackground($0, isHovering: $1) },
                        onEndPreview: { model.previewBackground = nil }
                    )
                }

                InspectorSection(
                    "Border",
                    summary: AnnotationInspectorSummary.border(model.backgroundSettings.border),
                    isOn: featureBinding(\.border.isEnabled),
                    toggleTitle: "Enable border",
                    accessory: {
                        if model.backgroundSettings.border.isEnabled,
                           model.backgroundSettings.border != AnnotationScreenshotBorderSettings(isEnabled: true) {
                            sectionResetButton("Reset border") {
                                model.backgroundSettings.border = AnnotationScreenshotBorderSettings(isEnabled: true)
                            }
                        }
                    }
                ) {
                    AnnotationScreenshotBorderInspector(
                        settings: Binding(
                            get: { model.backgroundSettings.border },
                            set: { model.backgroundSettings.border = $0 }
                        ),
                        onEditorAction: onEditorAction
                    )
                }

                InspectorGroupBreak()

                InspectorSection(
                    "Camera",
                    summary: AnnotationInspectorSummary.camera(model.backgroundSettings.camera),
                    isExpanded: expansionBinding(for: .camera),
                    accessory: {
                        if !model.backgroundSettings.camera.isDefault {
                            sectionResetButton("Reset camera") {
                                model.backgroundSettings.camera = AnnotationCameraSettings()
                            }
                        }
                    }
                ) {
                    AnnotationCameraInspector(
                        settings: Binding(
                            get: { model.backgroundSettings.camera },
                            set: { model.backgroundSettings.camera = $0 }
                        ),
                        onEditorAction: onEditorAction
                    )
                }

                InspectorSection(
                    "Progressive Blur",
                    summary: AnnotationInspectorSummary.progressiveBlur(model.backgroundSettings.progressiveBlur),
                    isOn: featureBinding(\.progressiveBlur.isEnabled),
                    toggleTitle: "Enable progressive blur",
                    accessory: {
                        if model.backgroundSettings.progressiveBlur.isEnabled,
                           model.backgroundSettings.progressiveBlur != AnnotationProgressiveBlurSettings(isEnabled: true) {
                            sectionResetButton("Reset progressive blur") {
                                model.backgroundSettings.progressiveBlur = AnnotationProgressiveBlurSettings(isEnabled: true)
                            }
                        }
                    }
                ) {
                    AnnotationProgressiveBlurInspector(
                        settings: Binding(
                            get: { model.backgroundSettings.progressiveBlur },
                            set: { model.backgroundSettings.progressiveBlur = $0 }
                        ),
                        onEditorAction: onEditorAction
                    )
                }

                InspectorGroupBreak()

                InspectorSection(
                    "Watermark",
                    summary: AnnotationInspectorSummary.watermark(model.backgroundSettings.watermark),
                    isOn: featureBinding(\.watermark.isEnabled),
                    toggleTitle: "Enable watermark",
                    accessory: {
                        if model.backgroundSettings.watermark.isEnabled,
                           model.backgroundSettings.watermark != AnnotationWatermarkSettings(isEnabled: true) {
                            sectionResetButton("Reset watermark") {
                                model.backgroundSettings.watermark = AnnotationWatermarkSettings(isEnabled: true)
                            }
                        }
                    }
                ) {
                    AnnotationWatermarkInspector(
                        settings: Binding(
                            get: { model.backgroundSettings.watermark },
                            set: { model.backgroundSettings.watermark = $0 }
                        ),
                        focusedField: focusedField,
                        onFocusCleared: onEditorAction
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // The Revert To bar keeps clear of the floating preview peek pill
            // itself; without the bar, the end of the list must.
            .padding(.bottom, showsRevertBar ? 12 : PreviewPeekTab.pillHeight * 1.1)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsRevertBar {
                InspectorRevertBar(background: sidebarBackground) {
                    AnnotationEditorRevertItems(editor: model)
                }
            }
        }
        .environment(\.annotationEditorHistory, model)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .background(sidebarBackground)
        .inspectorColumnWidth(
            min: InspectorMetrics.columnMinWidth,
            ideal: InspectorMetrics.columnIdealWidth,
            max: InspectorMetrics.columnMaxWidth
        )
        .frame(
            minWidth: InspectorMetrics.columnMinWidth,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private var sidebarBackground: Color { WorkspaceChrome.background }

    /// Revert To applies to History captures, which keep their original.
    private var showsRevertBar: Bool {
        model.sourceURL.map(ScreenshotHistoryStore.shared.isHistoryURL) ?? false
    }

    private var usesDefaultFrame: Bool {
        let settings = model.backgroundSettings
        let defaults = AnnotationBackgroundSettings()
        return settings.padding == defaults.padding
            && settings.cornerRadius == defaults.cornerRadius
            && settings.shadow == defaults.shadow
            && settings.shadowStyle == defaults.shadowStyle
            && settings.alignment == defaults.alignment
    }

    private var sectionAnimation: Animation? {
        accessibilityReduceMotion ? nil : .morph
    }

    private func expansionBinding(
        for section: AnnotationInspectorAdvancedSection
    ) -> Binding<Bool> {
        Binding(
            get: { expandedAdvancedSections.contains(section) },
            set: { isExpanded in
                if isExpanded {
                    expandedAdvancedSections.insert(section)
                } else {
                    expandedAdvancedSections.remove(section)
                }
                AnnotationInspectorSectionState.saveExpandedSections(expandedAdvancedSections)
            }
        )
    }

    /// A feature switch in a section header. The section folds with it.
    private func featureBinding(
        _ keyPath: WritableKeyPath<AnnotationBackgroundSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { model.backgroundSettings[keyPath: keyPath] },
            set: { value in
                onEditorAction()
                model.backgroundSettings[keyPath: keyPath] = value
            }
        )
    }

    /// Restores a section's defaults without switching it off.
    private func sectionResetButton(_ help: String, reset: @escaping () -> Void) -> some View {
        InspectorResetButton(help: help) {
            onEditorAction()
            withAnimation(sectionAnimation) { reset() }
        }
        .transition(.blurPop)
    }

    // MARK: Tools & style

    private func smartRedactionRow(tool: AnnotationTool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectorActionButton(
                "Find sensitive text…",
                systemImage: "text.viewfinder",
                isBusy: model.isSmartRedacting
            ) {
                onEditorAction()
                model.smartRedact(using: tool)
            }
            .help("Find sensitive text and \(tool == .blur ? "blur" : "pixelate") it")

            if model.isSmartRedacting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning screenshot…")
                        .font(.inspectorLabel)
                        .foregroundStyle(InspectorControlPalette.label)
                }
            } else if let message = model.smartRedactionMessage {
                Text(message)
                    .font(.inspectorLabel)
                    .foregroundStyle(InspectorControlPalette.label)
            }
        }
    }

    @ViewBuilder
    private var styleControls: some View {
        if model.hasInspectorStyleControls {
            if model.selectionCount > 1 {
                Text("\(model.selectionCount) annotations selected")
                    .font(.inspectorLabel)
                    .foregroundStyle(InspectorControlPalette.label)
            }

            if model.isTextStyleAvailable {
                AnnotationTextStyleControls(model: model)
            } else {
                if model.inspectedTool == .magnifier {
                    InspectorSlider("Zoom", value: Binding(
                        get: { model.magnifierZoom },
                        set: { onEditorAction(); model.setMagnifierZoom($0) }
                    ), range: 1...8, format: .magnification(fractionDigits: 1))
                }
                if model.isFillStyleAvailable {
                    InspectorRow("Fill") {
                        InspectorSegmented(
                            options: AnnoFillStyle.allCases,
                            isSelected: { $0 == model.geoFill },
                            onTap: {
                                onEditorAction()
                                model.setGeoFill($0)
                            },
                            label: { Text($0.label) },
                            height: InspectorMetrics.controlHeight
                        )
                    }
                }

                // Colour and width live in the tool dock's colour pill.

                if model.isHandDrawnStyleAvailable {
                    InspectorToggleRow("Hand-drawn", isOn: Binding(
                        get: { model.handDrawn },
                        set: { onEditorAction(); model.setHandDrawn($0) }
                    ))
                }

                if model.isRedactionStyleAvailable {
                    InspectorSlider(
                        "Strength",
                        value: Binding(
                            get: { model.redactionDensity },
                            set: {
                                onEditorAction()
                                model.setRedactionDensity($0)
                            }
                        ),
                        range: 0.15...1,
                        format: .percent()
                    )
                    if let tool = model.inspectedTool, tool.isRedactionTool {
                        smartRedactionRow(tool: tool)
                    }
                }
            }
        }
    }
}

// MARK: - Section summaries

/// One-line readouts for collapsed section headers. `nil` means the section
/// has nothing active worth announcing.
private enum AnnotationInspectorSummary {
    static func border(_ settings: AnnotationScreenshotBorderSettings) -> String? {
        guard settings.isEnabled else { return nil }
        let thickness = InspectorValueFormat.percent(fractionDigits: 1).displayString(for: settings.thickness)
        return "\(settings.color.title) · \(thickness)"
    }

    static func camera(_ settings: AnnotationCameraSettings) -> String? {
        guard !settings.isDefault else { return nil }
        var parts: [String] = []
        let angles = [
            settings.tiltXDegrees, settings.tiltYDegrees, settings.rollDegrees,
            settings.rotationXDegrees, settings.rotationYDegrees
        ]
        if angles.contains(where: { abs($0) > 0.0001 }) {
            parts.append("Angled")
        }
        if abs(settings.zoom - 1) > 0.0001 {
            parts.append(InspectorValueFormat.magnification(fractionDigits: 2).displayString(for: settings.zoom))
        }
        if abs(settings.panX) > 0.0001 || abs(settings.panY) > 0.0001 {
            parts.append("Panned")
        }
        if parts.isEmpty {
            parts.append("FOV \(InspectorValueFormat.degrees().displayString(for: settings.fieldOfViewDegrees))")
        }
        return parts.joined(separator: " · ")
    }

    static func progressiveBlur(_ settings: AnnotationProgressiveBlurSettings) -> String? {
        guard settings.isEnabled else { return nil }
        return "\(settings.mode.title) · \(Int(settings.strength.rounded()))"
    }

    static func watermark(_ settings: AnnotationWatermarkSettings) -> String? {
        let text = settings.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.isEnabled, !text.isEmpty else { return nil }
        return "“\(text)”"
    }
}
