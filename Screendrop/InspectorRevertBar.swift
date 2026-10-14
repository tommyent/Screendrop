//
//  InspectorRevertBar.swift
//  Screendrop
//
//  Revert To…, pinned under the inspector of the image editor and Studio. It
//  opens the same items as File › Revert To; each editor builds that list
//  once and hands it to both.
//

import SwiftUI

struct InspectorRevertBar<Items: View>: View {
    let background: Color
    @ViewBuilder let items: () -> Items

    @AppStorage(ScreendropPreferences.previewPositionKey)
    private var previewPositionRaw = PreviewOverlayPosition.right.rawValue
    private let previewStack = ScreenshotPreviewStack.shared

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.secondaryLabel)
                Text("Revert To…")
                    .font(.inspectorValue)
                    .foregroundStyle(Palette.label)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, InspectorMetrics.fieldInset)
            .inspectorField()
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .help("Go back to the original, to how this window opened, or to an earlier session")
        .accessibilityLabel("Revert To")
        .padding(.horizontal, InspectorMetrics.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, clearsPeekPill ? PreviewPeekTab.pillHeight * 1.1 : 12)
        .background(background)
    }

    /// While an editor is open the preview stack waits as a pill at the
    /// bottom of the screen; on the right, it can cover the bar.
    private var clearsPeekPill: Bool {
        (PreviewOverlayPosition(rawValue: previewPositionRaw) ?? .right) == .right
            && !previewStack.items.isEmpty
            && previewStack.isCollapsed
    }
}

/// File › Revert To's items for the image editor, for the menu and the
/// inspector's button alike.
struct AnnotationEditorRevertItems: View {
    let editor: AnnotationEditorModel

    var body: some View {
        Button("Original") { editor.revertToOriginal() }
            .disabled(!editor.canRevertToOriginal)
        Button("Last Opened") { editor.revertToLastOpened() }
            .disabled(!editor.canRevertToLastOpened)
        if !editor.previousSessionSnapshots.isEmpty { Divider() }
        ForEach(editor.previousSessionSnapshots) { snapshot in
            Button(snapshot.title) { editor.revertToSession(snapshot) }
                .disabled(editor.isCropping || editor.isBlockingCommit)
        }
    }
}

/// File › Revert To's items for Studio, for the menu and the inspector's
/// button alike. The whole menu is off while `canRevert` is false.
struct RecordingStudioRevertItems: View {
    let studio: RecordingStudioModel

    var body: some View {
        Button("Original") { studio.revertToOriginal() }
        Button("Last Opened") { studio.revertToLastOpened() }
            .disabled(!studio.hasEditsSinceOpening)
        if !studio.previousSessionSnapshots.isEmpty { Divider() }
        ForEach(studio.previousSessionSnapshots) { snapshot in
            Button(snapshot.title) { studio.revertToSession(snapshot) }
        }
    }
}
