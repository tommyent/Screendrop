//
//  AnnotationStyleStrip.swift
//  Screendrop
//
//  The annotator's saved styles, in the Styles picker it shares with Studio
//  (StylePresetPicker). The tiles show this screenshot wearing each style;
//  here a style's menu can also export it, and the pop-out footer imports
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
    @State private var transferAlert: PresetTransferAlert?

    var body: some View {
        StylePresetPicker(
            library: presetStore,
            appliedPreset: appliedPreset,
            itemNoun: "screenshot",
            saveMessage: "Saves the background, frame, camera, blur, border and watermark. New screenshots start with it.",
            hasMissingWallpaper: model.backgroundSettings.hasMissingCustomWallpaper,
            onEditorAction: onEditorAction,
            onApply: { model.applyBackgroundPreset($0) },
            onSave: { name in
                let preset = presetStore.savePreset(named: name, settings: model.backgroundSettings)
                if let preset { model.appliedBackgroundPresetID = preset.id }
                return preset
            },
            onDeleted: { preset in
                if model.appliedBackgroundPresetID == preset.id {
                    model.appliedBackgroundPresetID = nil
                }
            },
            preview: { preset in
                AnnotationStylePreview(settings: preset.settings, image: thumbnail, contentAspect: contentAspect)
            },
            extras: { preset in
                Button("Export…") { exportPreset(preset.id) }
            },
            footer: { close in
                HStack {
                    Spacer(minLength: 0)
                    Button("Import…") {
                        close()
                        importPresets()
                    }
                    .buttonStyle(.link)
                    .help("Import styles")
                    .accessibilityLabel("Import Styles")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        )
        .disabled(model.sourceURL == nil)
        // The pixels being edited, so the tiles follow a crop and its undo.
        .task(id: thumbnailURL) {
            let image = await Self.thumbnail(for: thumbnailURL)
            // A decode for an earlier image mustn't replace a newer one.
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
        .alert(item: $transferAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    private var appliedPreset: AnnotationBackgroundPreset? {
        guard let preset = presetStore.preset(id: model.appliedBackgroundPresetID),
              preset.matches(model.backgroundSettings) else { return nil }
        return preset
    }

    private var thumbnailURL: URL? {
        model.baseImageURL ?? model.sourceURL
    }

    private var contentAspect: CGFloat {
        guard model.imageSize.width > 0, model.imageSize.height > 0 else { return 1.6 }
        return model.imageSize.width / model.imageSize.height
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
