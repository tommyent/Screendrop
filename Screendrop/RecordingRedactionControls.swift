import SwiftUI

struct RecordingRedactionControls: View {
    @Bindable var model: RecordingStudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            if model.isSelectingRedaction {
                InspectorHint("Draw or resize a rectangle over the screen video.")
                HStack {
                    geometryField("X", keyPath: \.origin.x)
                    geometryField("Y", keyPath: \.origin.y)
                }
                HStack {
                    geometryField("Width", keyPath: \.size.width)
                    geometryField("Height", keyPath: \.size.height)
                }
                HStack {
                    InspectorActionButton("Cancel", systemImage: "xmark") { model.cancelRedaction() }
                    InspectorActionButton("Add", systemImage: "plus") { model.addRedaction() }
                }
            } else {
                InspectorActionButton("Add Redaction", systemImage: "rectangle.dashed") { model.beginRedaction() }
                    .disabled(!model.isLoaded || model.hasRunningWork)
            }
            ForEach(model.redactions) { region in
                Button {
                    model.selectedRedactionID = region.id
                    if let time = model.editorTime(forSourceTime: region.start) { model.seek(to: time) }
                } label: {
                    HStack {
                        Text(region.mode.title)
                        Spacer()
                        Text("\(region.start, format: .number.precision(.fractionLength(2)))–\(region.end, format: .number.precision(.fractionLength(2))) s")
                            .monospacedDigit()
                        if region.id == model.selectedRedactionID { Image(systemName: "checkmark") }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(region.mode.title), source seconds \(region.start) to \(region.end)")
            }
            if let region = model.selectedRedaction {
                Picker("Effect", selection: Binding(get: { region.mode }, set: {
                    var next = region; next.mode = $0; model.updateRedaction(next)
                })) {
                    ForEach(RecordingRedaction.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                timeField("Start", keyPath: \.start)
                timeField("End", keyPath: \.end)
                InspectorSlider("Strength", value: Binding(
                    get: { CGFloat(region.strength) },
                    set: { var next = region; next.strength = Double($0); model.updateRedaction(next) }
                ), range: 0.35...1, format: .percent())
                InspectorActionButton("Remove", systemImage: "trash", role: .destructive) { model.removeRedaction(region.id) }
            }
            if let error = model.redactionEditError { InspectorHint(error, tint: .orange) }
            InspectorHint("Times use the original recording. The original stays in the package; previews and exports are redacted. Camera, audio and captions are unchanged.")
        }
        .disabled(!model.isLoaded || model.hasRunningWork)
    }

    private func timeField(_ label: String, keyPath: WritableKeyPath<RecordingRedaction, Double>) -> some View {
        HStack {
            Text(label)
            TextField(label, value: Binding(
                get: { model.selectedRedaction?[keyPath: keyPath] ?? 0 },
                set: { value in
                    guard var region = model.selectedRedaction else { return }
                    region[keyPath: keyPath] = value
                    model.updateRedaction(region)
                }
            ), format: .number.precision(.fractionLength(2)))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("\(label) in source seconds")
            Button("Use Playhead") {
                guard var region = model.selectedRedaction else { return }
                region[keyPath: keyPath] = model.sourceTime(atEditorTime: model.currentTime)
                model.updateRedaction(region)
            }
            .help("Set redaction \(label.lowercased()) to the playhead")
        }
    }

    private func geometryField(_ label: String, keyPath: WritableKeyPath<CGRect, CGFloat>) -> some View {
        VStack(alignment: .leading) {
            Text(label)
            TextField(label, value: Binding<Double>(
                get: { Double(model.workingVideoCropRect[keyPath: keyPath]) },
                set: { value in
                    guard value.isFinite else { return }
                    var rect = model.workingVideoCropRect
                    rect[keyPath: keyPath] = CGFloat(min(max(value, 0), 1))
                    let clipped = rect.intersection(CropRectEditor.unit)
                    if clipped.width > 0, clipped.height > 0 { model.workingVideoCropRect = clipped }
                }
            ), format: .percent.precision(.fractionLength(0)))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Redaction \(label.lowercased()) as a percentage of the source")
        }
    }
}
