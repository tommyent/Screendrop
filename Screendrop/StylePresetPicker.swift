//
//  StylePresetPicker.swift
//  Screendrop
//
//  The Styles picker the image editor and Studio share: a row naming the
//  applied style that opens a grid of thumbnails, the capture wearing each
//  saved style. Clicking one applies it; the last tile saves the current
//  look. A style's menu sets it as the default for new captures, exports it
//  or deletes it, and the grid's footer imports styles shared as files.
//  Each editor keeps its own store, since their styles hold different
//  settings.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A saved style the picker lists.
protocol StylePresetItem: Identifiable where ID == UUID {
    var name: String { get }
    var hasMissingWallpaper: Bool { get }
}

/// The store behind a Styles picker.
protocol StylePresetLibrary: AnyObject, Observable {
    associatedtype Preset: StylePresetItem
    var presets: [Preset] { get }
    var activePreset: Preset? { get }
    func preset(named rawName: String) -> Preset?
    func setActivePreset(id: UUID?)
    @discardableResult func deletePreset(id: UUID) -> Preset?
    static var maximumNameLength: Int { get }
    static func normalizedName(_ rawName: String) -> String
    /// A style as a shareable file, and whether its local wallpaper was left out.
    func exportedData(for id: UUID) throws -> (data: Data, omitsWallpaper: Bool)
    /// Adds the styles in a shared file, under fresh names.
    func importStyles(from url: URL) throws -> (presets: [Preset], omittedWallpaperCount: Int)
}

extension AnnotationBackgroundPreset: StylePresetItem {}
extension AnnotationBackgroundPresetStore: StylePresetLibrary {}
extension RecordingStudioStylePreset: StylePresetItem {}
extension RecordingStudioStylePresetStore: StylePresetLibrary {}

struct StylePresetPicker<Library: StylePresetLibrary, Preview: View>: View {
    @Bindable var library: Library
    /// The applied style while the look still matches it.
    let appliedPreset: Library.Preset?
    /// "screenshot" or "recording".
    let itemNoun: String
    /// What saving keeps, under New Style.
    let saveMessage: String
    /// The look's wallpaper can't be found, so it can't be saved.
    let hasMissingWallpaper: Bool
    let onEditorAction: () -> Void
    let onApply: (Library.Preset) -> Void
    /// Saves the current look under a name; nil when it wasn't saved.
    let onSave: (String) -> Library.Preset?
    let onDeleted: (Library.Preset) -> Void
    @ViewBuilder let preview: (Library.Preset) -> Preview

    @State private var isPickerPresented = false
    @State private var isNameEditorPresented = false
    @State private var draftName = ""
    @State private var presetPendingDeletion: Library.Preset?
    @State private var transferAlert: PresetTransferAlert?
    @FocusState private var isNameFieldFocused: Bool

    private static var tileAspect: CGFloat { 1.5 }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3)

    private var newItems: String { itemNoun.capitalized + "s" }

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
            HStack(spacing: 6) {
                Text("Styles")
                    .font(.inspectorSectionHeader)
                    .foregroundStyle(Palette.label.opacity(0.95))
                Spacer(minLength: 0)
            }
            .frame(minHeight: 24)
            .padding(.horizontal, InspectorMetrics.horizontalPadding)

            pickerRow
                .padding(.horizontal, InspectorMetrics.horizontalPadding)
        }
        .padding(.top, InspectorMetrics.sectionVerticalPadding / 2 + 3)
        .padding(.bottom, 4)
        .onChange(of: isPickerPresented) { _, isShown in
            if !isShown { isNameEditorPresented = false }
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
                library.deletePreset(id: preset.id)
                onDeleted(preset)
                presetPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                presetPendingDeletion = nil
            }
        } message: { preset in
            Text("“\(preset.name)” will be removed from your styles. This \(itemNoun) won’t change.")
        }
        .alert(item: $transferAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    private var pickerRow: some View {
        Button {
            onEditorAction()
            isPickerPresented = true
        } label: {
            HStack(spacing: 8) {
                Text(appliedPreset?.name ?? "None")
                    .font(.inspectorValue)
                    .foregroundStyle(appliedPreset == nil ? Palette.secondaryLabel : Palette.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, InspectorMetrics.fieldInset)
            .inspectorField()
        }
        .buttonStyle(.plain)
        .help("Choose a style")
        .accessibilityLabel("Styles")
        .accessibilityValue(appliedPreset?.name ?? "None")
        .closesOnEditorEscape($isPickerPresented)
        .popover(isPresented: $isPickerPresented, arrowEdge: .leading) {
            VStack(spacing: 8) {
                InspectorGridScroll {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(library.presets) { preset in
                            tile(for: preset)
                        }
                        addTile
                    }
                }

                HStack {
                    Spacer(minLength: 0)
                    Button("Import…") {
                        isPickerPresented = false
                        importPresets()
                    }
                    .buttonStyle(.link)
                    .help("Import styles")
                    .accessibilityLabel("Import Styles")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(width: 320)
            .background(Palette.panel)
            .presentationBackground(Palette.panel)
        }
    }

    private func tile(for preset: Library.Preset) -> some View {
        let isApplied = appliedPreset?.id == preset.id
        let isDefault = library.activePreset?.id == preset.id
        let isMissing = preset.hasMissingWallpaper
        return VStack(spacing: 4) {
            InspectorTile(title: preset.name, aspectRatio: Self.tileAspect, isSelected: isApplied) {
                guard !isMissing else {
                    presetPendingDeletion = preset
                    return
                }
                onEditorAction()
                withAnimation(.morphIfAllowed) { onApply(preset) }
            } content: {
                preview(preset)
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
                        .help("Used for new \(itemNoun)s")
                }
                Text(preset.name)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
            }
            .font(.system(size: 11, weight: isApplied ? .semibold : .regular))
            .foregroundStyle(isApplied ? Palette.label : Palette.secondaryLabel)
            .padding(.horizontal, 2)
            .frame(height: 28, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .help(isMissing ? "\(preset.name)’s wallpaper can’t be found" : preset.name)
        .contextMenu {
            if !isMissing {
                Button(isDefault ? "Stop Using for New \(newItems)" : "Use for New \(newItems)") {
                    library.setActivePreset(id: isDefault ? nil : preset.id)
                }
            }
            Button("Export…") { exportPreset(preset) }
            Divider()
            Button("Delete…", role: .destructive) {
                presetPendingDeletion = preset
            }
        }
    }

    private var addTile: some View {
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
        .accessibilityLabel("New Style")
        .closesOnEditorEscape($isNameEditorPresented)
        .popover(isPresented: $isNameEditorPresented, arrowEdge: .bottom) {
            nameEditor
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Saving

    private var duplicateNamePreset: Library.Preset? {
        library.preset(named: draftName)
    }

    private var canSaveName: Bool {
        !Library.normalizedName(draftName).isEmpty
            && duplicateNamePreset == nil
            && !hasMissingWallpaper
    }

    private var nameEditor: some View {
        InspectorPopover(
            title: "New Style",
            message: saveMessage,
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
                        let limitedName = String(newValue.prefix(Library.maximumNameLength))
                        if limitedName != newValue {
                            draftName = limitedName
                        }
                    }

                if hasMissingWallpaper {
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
        guard canSaveName, let preset = onSave(draftName) else { return }
        library.setActivePreset(id: preset.id)
        isNameEditorPresented = false
    }

    // MARK: Sharing

    private var styleNoun: String { "\(itemNoun.capitalized) Style" }

    private func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.screendropPreset]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Import \(styleNoun)s"
        panel.prompt = "Import"

        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls

            Task { @MainActor in
                var importedPresets: [Library.Preset] = []
                var omittedWallpaperCount = 0
                var failures: [String] = []

                for url in urls {
                    do {
                        let result = try library.importStyles(from: url)
                        importedPresets.append(contentsOf: result.presets)
                        omittedWallpaperCount += result.omittedWallpaperCount
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }

                if let firstImportedPreset = importedPresets.first {
                    withAnimation(.morphIfAllowed) { onApply(firstImportedPreset) }
                }

                transferAlert = Self.importAlert(
                    importedCount: importedPresets.count,
                    omittedWallpaperCount: omittedWallpaperCount,
                    failures: failures
                )
            }
        }
    }

    private func exportPreset(_ preset: Library.Preset) {
        do {
            let exported = try library.exportedData(for: preset.id)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.screendropPreset]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.title = "Export \(styleNoun)"
            panel.prompt = "Export"
            panel.nameFieldStringValue = "\(safeFilename(for: preset.name)).\(AnnotationBackgroundPresetTransferFile.filenameExtension)"

            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }

                Task { @MainActor in
                    do {
                        try exported.data.write(to: url, options: .atomic)
                        transferAlert = PresetTransferAlert(
                            title: "Style Exported",
                            message: exported.omitsWallpaper
                                ? "The local wallpaper was not included. The imported style will use no background."
                                : "“\(preset.name)” is ready to share."
                        )
                    } catch {
                        transferAlert = PresetTransferAlert(title: "Export Failed", message: error.localizedDescription)
                    }
                }
            }
        } catch {
            transferAlert = PresetTransferAlert(title: "Export Failed", message: error.localizedDescription)
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

    private func safeFilename(for presetName: String) -> String {
        let forbiddenCharacters = CharacterSet(charactersIn: "/:\n\r")
        let components = presetName.components(separatedBy: forbiddenCharacters)
        let sanitized = components.filter { !$0.isEmpty }.joined(separator: "-")
        return sanitized.isEmpty ? styleNoun : sanitized
    }
}

private struct PresetTransferAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
