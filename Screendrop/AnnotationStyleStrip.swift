//
//  AnnotationStyleStrip.swift
//  Screendrop
//
//  The annotator's saved styles, in the Styles picker it shares with Studio
//  (StylePresetPicker). The tiles show this screenshot wearing each style.
//

import AppKit
import SwiftUI

struct AnnotationStyleStrip: View {
    @Bindable var model: AnnotationEditorModel
    @Bindable var presetStore: AnnotationBackgroundPresetStore
    let onEditorAction: () -> Void

    @State private var thumbnail: CGImage?

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
