import AppKit
import SwiftUI

struct StudioBackgroundMusicControls: View {
    @Bindable var model: RecordingStudioModel
    var findMusic: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            Text("Background music")
                .font(.inspectorSectionHeader)
                .foregroundStyle(InspectorControlPalette.label)
                .padding(.top, 6)

            if let settings = model.backgroundMusicSettings {
                trackChip(settings)
                if let music = model.backgroundMusic {
                    MusicStartWaveform(levels: model.musicWaveform, start: Double(model.musicStartOffset), duration: music.duration)
                    InspectorSlider("Starts at", value: $model.musicStartOffset,
                        range: 0...CGFloat(max(0.001, music.duration - 0.05)),
                        format: InspectorValueFormat(multiplier: 1, fractionDigits: 1, suffix: " s",
                            showsPositiveSign: false, step: 0.1, acceptedSuffixes: ["s"]))
                        .accessibilityHint("Where in the music track playback begins")
                }
                if let credit = settings.credit, !credit.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(credit)
                            .font(.inspectorLabel)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Copy credit") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(credit, forType: .string)
                        }
                        .buttonStyle(.link)
                        .font(.inspectorLabel)
                    }
                }
            } else {
                InspectorHint(findMusic == nil ? "No background music. Add your own file." : "No background music. Find a track or add your own file.")
            }

            HStack(spacing: InspectorMetrics.rowSpacing) {
                if let findMusic {
                    InspectorActionButton("Find music…", systemImage: "magnifyingglass", action: findMusic)
                }
                InspectorActionButton("Add music…", systemImage: "plus") { pickMusic() }
            }
            .disabled(!model.isProject || model.hasRunningWork)

            if let error = model.backgroundMusicError { InspectorHint(error, tint: .orange) }
            if !model.isProject { InspectorHint("Background music needs a recording project.") }

            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorSlider("Music volume", value: $model.musicVolume, range: 0...1, format: .percent())
                Toggle("Loop to fit", isOn: $model.musicLoops)
                    .toggleStyle(.switch)
                    .help("Repeats from the chosen start point to the end of the track")
                Toggle("Lower under voice", isOn: $model.musicDucks)
                    .toggleStyle(.switch)
                    .disabled(!model.canIsolateVoice)
                    .help("Dips the music while the recorded microphone has speech")
                if !model.canIsolateVoice { InspectorHint("No microphone track to follow for ducking.") }
                InspectorSegmented(options: RecordingBackgroundMusic.DuckAmount.allCases,
                    isSelected: { $0 == model.musicDuckAmount },
                    onTap: { model.musicDuckAmount = $0 },
                    label: { Text($0.title).font(.inspectorSegment).help("\($0.rawValue.formatted()) dB") })
                    .disabled(!model.canIsolateVoice || !model.musicDucks)
                    .accessibilityLabel("How much to lower the music")
            }
            .disabled(!model.hasBackgroundMusic)

            InspectorHint("Fades out over the last second. Exports and shares include the music.")
        }
    }

    private func trackChip(_ settings: RecordingBackgroundMusic) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "music.note")
                .foregroundStyle(.teal)
                .accessibilityHidden(true)
            Text(settings.displayName)
                .font(.inspectorValue)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let music = model.backgroundMusic {
                Text(Duration.seconds(music.duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.inspectorLabel.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Remove music", systemImage: "xmark") { model.removeBackgroundMusic() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("Remove background music")
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inspectorField()
        .help(settings.displayName)
    }

    private func pickMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = RecordingAudioFormat.importContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose Background Music"
        panel.begin { [weak model] response in
            guard response == .OK, let url = panel.url else { return }
            model?.setBackgroundMusic(fileURL: url, displayName: url.lastPathComponent, credit: nil, startOffset: 0)
        }
    }
}

private struct MusicStartWaveform: View {
    var levels: [Float]
    var start: Double
    var duration: Double

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty, duration > 0 else { return }
            let marker = size.width * min(1, max(0, start / duration))
            let width = size.width / CGFloat(levels.count)
            for (index, level) in levels.enumerated() {
                let x = CGFloat(index) * width
                let height = max(2, CGFloat(level) * (size.height - 4))
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: max(1, width - 1), height: height)
                context.fill(Path(rect), with: .color(.teal.opacity(x < marker ? 0.25 : 0.85)))
            }
            context.fill(Path(CGRect(x: marker, y: 0, width: 2, height: size.height)), with: .color(.accentColor))
        }
        .frame(height: 30)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}
