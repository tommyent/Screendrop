//
//  AnnotationStyleStrip.swift
//  Screendrop
//
//  The annotator's saved styles as thumbnails of this screenshot wearing
//  them, the same strip Studio shows. Clicking one applies it; the last tile
//  saves the current look. A style's menu sets it as the default for new
//  screenshots, exports it or deletes it, and the header's menu imports
//  styles shared as files.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AnnotationStyleStrip: View {
    @Bindable var model: AnnotationEditorModel
    @Bindable var presetStore: AnnotationBackgroundPresetStore
    let onEditorAction: () -> Void

    @State private var thumbnail: CGImage?
    @State private var isNameEditorPresented = false
    @State private var draftName = ""
    @State private var presetPendingDeletion: AnnotationBackgroundPreset?
    @State private var transferAlert: PresetTransferAlert?
    @FocusState private var isNameFieldFocused: Bool

    private static let tileWidth: CGFloat = 78
    private static let tileAspect: CGFloat = 1.5

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
            HStack(spacing: 6) {
                Text("Styles")
                    .font(.inspectorSectionHeader)
                    .foregroundStyle(Palette.label.opacity(0.95))
                Spacer(minLength: 0)
                headerMenu
            }
            .frame(minHeight: 24)
            .padding(.horizontal, InspectorMetrics.horizontalPadding)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(presetStore.presets) { preset in
                        tile(for: preset)
                    }
                    addTile
                }
                .padding(.horizontal, InspectorMetrics.horizontalPadding - 2.5)
            }
            .scrollIndicators(.never)
        }
        .padding(.top, InspectorMetrics.sectionVerticalPadding / 2 + 3)
        .padding(.bottom, 4)
        .disabled(model.sourceURL == nil)
        .task(id: model.sourceURL) {
            thumbnail = await Self.thumbnail(for: model.sourceURL)
        }
        .alert(
            "Delete Style?",
            isPresented: Binding(
                get: { presetPendingDeletion != nil },
                set: { if !$0 { presetPendingDeletion = nil } }
            ),
            presenting: presetPendingDeletion
        ) { preset in
            Button("Delete", role: .destructive) {
                presetStore.deletePreset(id: preset.id)
                if model.appliedBackgroundPresetID == preset.id {
                    model.appliedBackgroundPresetID = nil
                }
                presetPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                presetPendingDeletion = nil
            }
        } message: { preset in
            Text("“\(preset.name)” will be removed from your styles. This screenshot won’t change.")
        }
        .alert(item: $transferAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    private var headerMenu: some View {
        Menu {
            Button("Import Styles…", action: importPresets)
            if let applied = presetStore.preset(id: model.appliedBackgroundPresetID) {
                Button("Export “\(applied.name)”…") { exportPreset(applied.id) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.secondaryLabel)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Import or export styles")
    }

    private func tile(for preset: AnnotationBackgroundPreset) -> some View {
        let isApplied = model.appliedBackgroundPresetID == preset.id && preset.matches(model.backgroundSettings)
        let isDefault = presetStore.activePreset?.id == preset.id
        let isMissing = preset.hasMissingWallpaper
        return VStack(spacing: 4) {
            InspectorTile(title: preset.name, aspectRatio: Self.tileAspect, isSelected: isApplied) {
                guard !isMissing else {
                    presetPendingDeletion = preset
                    return
                }
                onEditorAction()
                withAnimation(.morphIfAllowed) { model.applyBackgroundPreset(preset) }
            } content: {
                AnnotationStylePreview(
                    settings: preset.settings,
                    image: thumbnail,
                    contentAspect: contentAspect
                )
                .overlay {
                    if isMissing {
                        Color.black.opacity(0.45)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }

            HStack(spacing: 3) {
                if isDefault {
                    Circle()
                        .fill(Palette.label)
                        .frame(width: 4, height: 4)
                        .help("Used for new screenshots")
                }
                Text(preset.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 10, weight: isApplied ? .semibold : .regular))
            .foregroundStyle(isApplied ? Palette.label : Palette.secondaryLabel)
            .padding(.horizontal, 2)
        }
        .frame(width: Self.tileWidth)
        .help(isMissing ? "\(preset.name)’s wallpaper can’t be found" : preset.name)
        .contextMenu {
            if !isMissing {
                Button(isDefault ? "Stop Using for New Screenshots" : "Use for New Screenshots") {
                    presetStore.setActivePreset(id: isDefault ? nil : preset.id)
                }
                Button("Export…") { exportPreset(preset.id) }
                Divider()
            }
            Button("Delete…", role: .destructive) {
                presetPendingDeletion = preset
            }
        }
    }

    private var addTile: some View {
        VStack(spacing: 4) {
            Button {
                onEditorAction()
                draftName = ""
                isNameEditorPresented = true
            } label: {
                RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    .foregroundStyle(.quaternary)
                    .aspectRatio(Self.tileAspect, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(2.5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Save this look as a style")
            .accessibilityLabel("Save Style")
            .popover(isPresented: $isNameEditorPresented, arrowEdge: .bottom) {
                nameEditor
            }

            Text(presetStore.presets.isEmpty ? "Save Look" : "Save")
                .font(.system(size: 10))
                .foregroundStyle(Palette.tertiaryLabel)
        }
        .frame(width: Self.tileWidth)
    }

    private var contentAspect: CGFloat {
        guard model.imageSize.width > 0, model.imageSize.height > 0 else { return 1.6 }
        return model.imageSize.width / model.imageSize.height
    }

    // MARK: Saving

    private var duplicateNamePreset: AnnotationBackgroundPreset? {
        presetStore.preset(named: draftName)
    }

    private var canSaveName: Bool {
        !AnnotationBackgroundPresetStore.normalizedName(draftName).isEmpty
            && duplicateNamePreset == nil
            && !model.backgroundSettings.hasMissingCustomWallpaper
    }

    private var nameEditor: some View {
        InspectorPopover(
            title: "New Style",
            message: "Saves the background, frame, camera, blur, border and watermark. New screenshots start with it.",
            confirmTitle: "Save",
            isConfirmDisabled: !canSaveName,
            width: 292,
            onCancel: { isNameEditorPresented = false },
            onConfirm: savePreset
        ) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Style name", text: $draftName)
                    .inspectorTextField()
                    .focused($isNameFieldFocused)
                    .onSubmit(savePreset)
                    .onChange(of: draftName) { _, newValue in
                        let limitedName = String(newValue.prefix(AnnotationBackgroundPresetStore.maximumNameLength))
                        if limitedName != newValue {
                            draftName = limitedName
                        }
                    }

                if model.backgroundSettings.hasMissingCustomWallpaper {
                    Label(
                        "The selected wallpaper can’t be found. Choose it again before saving.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.inspectorLabel)
                    .foregroundStyle(Palette.record)
                } else if duplicateNamePreset != nil {
                    Label("A style with this name already exists.", systemImage: "exclamationmark.circle.fill")
                        .font(.inspectorLabel)
                        .foregroundStyle(Palette.record)
                }
            }
        }
        .onAppear {
            Task { @MainActor in
                isNameFieldFocused = true
            }
        }
    }

    private func savePreset() {
        guard canSaveName,
              let preset = presetStore.savePreset(named: draftName, settings: model.backgroundSettings)
        else { return }
        model.appliedBackgroundPresetID = preset.id
        presetStore.setActivePreset(id: preset.id)
        isNameEditorPresented = false
    }

    /// A small copy of the screenshot for the thumbnails.
    nonisolated private static func thumbnail(for url: URL?) async -> CGImage? {
        guard let url else { return nil }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    // MARK: Sharing

    private func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.screendropPreset]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Import Screenshot Styles"
        panel.prompt = "Import"

        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls

            Task { @MainActor in
                var importedPresets: [AnnotationBackgroundPreset] = []
                var omittedWallpaperCount = 0
                var failures: [String] = []

                for url in urls {
                    do {
                        let transferFile = try AnnotationBackgroundPresetTransferFile.load(from: url)
                        let result = try presetStore.importTransferFile(transferFile)
                        importedPresets.append(contentsOf: result.importedPresets)
                        omittedWallpaperCount += result.omittedWallpaperCount
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }

                if let firstImportedPreset = importedPresets.first {
                    withAnimation(.morphIfAllowed) {
                        model.applyBackgroundPreset(firstImportedPreset)
                    }
                }

                transferAlert = Self.importAlert(
                    importedCount: importedPresets.count,
                    omittedWallpaperCount: omittedWallpaperCount,
                    failures: failures
                )
            }
        }
    }

    private func exportPreset(_ presetID: AnnotationBackgroundPreset.ID) {
        do {
            let transferFile = try presetStore.transferFile(for: presetID)
            guard let preset = presetStore.preset(id: presetID) else {
                throw AnnotationBackgroundPresetTransferError.presetNotFound
            }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.screendropPreset]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.title = "Export Screenshot Style"
            panel.prompt = "Export"
            panel.nameFieldStringValue = "\(Self.safeFilename(for: preset.name)).\(AnnotationBackgroundPresetTransferFile.filenameExtension)"

            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }

                Task { @MainActor in
                    do {
                        let data = try transferFile.encodedData()
                        try data.write(to: url, options: .atomic)
                        let omittedWallpaper = transferFile.presets.first?.omitted.contains(.wallpaper) == true
                        transferAlert = PresetTransferAlert(
                            title: "Style Exported",
                            message: omittedWallpaper
                                ? "The local wallpaper was not included. The imported style will use no background."
                                : "“\(preset.name)” is ready to share."
                        )
                    } catch {
                        transferAlert = PresetTransferAlert(
                            title: "Export Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        } catch {
            transferAlert = PresetTransferAlert(
                title: "Export Failed",
                message: error.localizedDescription
            )
        }
    }

    private static func importAlert(
        importedCount: Int,
        omittedWallpaperCount: Int,
        failures: [String]
    ) -> PresetTransferAlert {
        guard importedCount > 0 else {
            return PresetTransferAlert(
                title: "Import Failed",
                message: failures.joined(separator: "\n")
            )
        }

        let presetNoun = importedCount == 1 ? "style" : "styles"
        var messages = ["Imported \(importedCount) \(presetNoun)."]
        if omittedWallpaperCount > 0 {
            let wallpaperNoun = omittedWallpaperCount == 1 ? "wallpaper was" : "wallpapers were"
            messages.append(
                "\(omittedWallpaperCount) local \(wallpaperNoun) not included and will use no background."
            )
        }
        if !failures.isEmpty {
            messages.append("Some files could not be imported:\n\(failures.joined(separator: "\n"))")
        }
        return PresetTransferAlert(
            title: importedCount == 1 ? "Style Imported" : "Styles Imported",
            message: messages.joined(separator: "\n\n")
        )
    }

    private static func safeFilename(for presetName: String) -> String {
        let forbiddenCharacters = CharacterSet(charactersIn: "/:\n\r")
        let components = presetName.components(separatedBy: forbiddenCharacters)
        let sanitized = components.filter { !$0.isEmpty }.joined(separator: "-")
        return sanitized.isEmpty ? "Screenshot Style" : sanitized
    }
}

private struct PresetTransferAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// A style drawn the way the canvas lays it out: the background, then the
/// screenshot inset by the padding with its corners, border and shadow.
struct AnnotationStylePreview: View {
    let settings: AnnotationBackgroundSettings
    let image: CGImage?
    let contentAspect: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let short = min(size.width, size.height)
            let hasFill = settings.style != .none
            let inset = hasFill ? settings.padding * short : short * 0.08
            let available = CGSize(width: max(1, size.width - inset * 2), height: max(1, size.height - inset * 2))
            let aspect = max(0.1, contentAspect)
            let card = available.width / available.height > aspect
                ? CGSize(width: available.height * aspect, height: available.height)
                : CGSize(width: available.width, height: available.width / aspect)
            let cardShort = min(card.width, card.height)
            let radius = hasFill ? settings.cornerRadius * cardShort : 0
            let border = settings.border.isVisible ? max(1, settings.border.thickness * cardShort) : 0

            ZStack {
                if hasFill {
                    BackgroundSwatch(style: settings.style)
                } else {
                    Rectangle().fill(Color.primary.opacity(0.05))
                }

                Group {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color(white: 0.16)
                    }
                }
                .frame(width: card.width, height: card.height)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .padding(border)
                .background(
                    RoundedRectangle(cornerRadius: radius + border, style: .continuous)
                        .fill(settings.border.color.color.opacity(settings.border.opacity))
                        .opacity(border > 0 ? 1 : 0)
                )
                .shadow(
                    color: .black.opacity(hasFill ? 0.5 * settings.shadow : 0),
                    radius: short * 0.05 * settings.shadow,
                    y: short * 0.02 * settings.shadow
                )
            }
            .frame(width: size.width, height: size.height)
        }
    }
}
