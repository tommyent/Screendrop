//
//  RecordingStudioStyleStrip.swift
//  Screendrop
//
//  Studio's saved styles, in the Styles picker it shares with the image
//  editor (StylePresetPicker). The tiles show a frame of this recording
//  wearing each style. After upstream v0.35's Studio Look.
//

import SwiftUI

struct RecordingStudioStyleStrip: View {
    @Bindable var model: RecordingStudioModel
    @Bindable var presetStore: RecordingStudioStylePresetStore

    var body: some View {
        StylePresetPicker(
            library: presetStore,
            appliedPreset: appliedPreset,
            itemNoun: "recording",
            saveMessage: "Saves the background, frame, cursor size and camera. New recordings start with it.",
            hasMissingWallpaper: model.style.hasMissingCustomWallpaper,
            onEditorAction: {},
            onApply: { model.applyStylePreset($0) },
            onSave: { name in
                let preset = presetStore.savePreset(named: name, style: model.style)
                if let preset { model.appliedStylePresetID = preset.id }
                return preset
            },
            onDeleted: { preset in
                if model.appliedStylePresetID == preset.id {
                    model.appliedStylePresetID = nil
                }
            },
            preview: { preset in
                StudioStyleTilePreview(model: model, style: preset.value)
            }
        )
        .disabled(!model.isLoaded)
    }

    private var appliedPreset: RecordingStudioStylePreset? {
        guard let preset = presetStore.preset(id: model.appliedStylePresetID),
              preset.matches(model.style) else { return nil }
        return preset
    }

}

/// Reads the model's poster frame itself, so a tile drawn before the frame
/// arrives redraws when it does.
private struct StudioStyleTilePreview: View {
    let model: RecordingStudioModel
    let style: RecordingStudioStyle

    var body: some View {
        StudioStylePreview(
            style: style,
            poster: model.stylePoster,
            contentAspect: model.sourceVideoAspect,
            showsCamera: model.hasCameraVideo
        )
    }
}

/// A style drawn the way Studio's canvas lays it out: the background, the
/// recording inset by the style's padding with its corners and shadow, and
/// the camera bubble where it sits.
struct StudioStylePreview: View {
    let style: RecordingStudioStyle
    let poster: CGImage?
    let contentAspect: CGFloat
    var showsCamera = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let short = min(size.width, size.height)
            // The canvas pads the video whether or not there is a fill.
            let inset = style.padding * short
            let available = CGSize(
                width: max(1, size.width - inset * 2),
                height: max(1, size.height - inset * 2)
            )
            let aspect = max(0.1, contentAspect)
            let card = available.width / available.height > aspect
                ? CGSize(width: available.height * aspect, height: available.height)
                : CGSize(width: available.width, height: available.width / aspect)

            ZStack {
                BackgroundSwatch(style: style.background)

                Group {
                    if let poster {
                        Image(decorative: poster, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color(white: 0.16)
                    }
                }
                .frame(width: card.width, height: card.height)
                .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius * short, style: .continuous))
                .shadow(
                    color: .black.opacity(style.background == .none ? 0 : 0.5 * style.shadow),
                    radius: short * 0.05 * style.shadow,
                    y: short * 0.02 * style.shadow
                )

                if showsCamera, style.camera.isVisible {
                    let diameter = style.camera.size * short
                    RoundedRectangle(cornerRadius: diameter * style.camera.roundness, style: .continuous)
                        .fill(Color(white: 0.78))
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: diameter * 0.45))
                                .foregroundStyle(Color(white: 0.55))
                        }
                        .frame(width: diameter, height: diameter)
                        .clipShape(RoundedRectangle(cornerRadius: diameter * style.camera.roundness, style: .continuous))
                        .position(x: style.camera.center.x * size.width, y: style.camera.center.y * size.height)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}
