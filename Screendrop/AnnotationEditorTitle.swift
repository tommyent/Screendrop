import Foundation
import SwiftUI

struct AnnotationEditorTitle: View {
    let title: String
    let status: String
    let item: ScreenshotHistoryItem?
    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if isRenaming {
                    TextField("Name", text: $draft, prompt: Text(item.map { CaptureLibraryItem.dateTitle($0.createdAt) } ?? title))
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .frame(minWidth: 180)
                        .onSubmit { finishRename(commit: true) }
                        .onExitCommand { finishRename(commit: false) }
                        .onClickOutside { finishRename(commit: true) }
                        .onAppear {
                            DispatchQueue.main.async {
                                if isRenaming { isFocused = true }
                            }
                        }
                } else if item != nil {
                    titleText
                        .onTapGesture(count: 2, perform: beginRename)
                        .focusable(interactions: .activate)
                        .onKeyPress(keys: [.return, .space], phases: .down) { _ in
                            beginRename()
                            return .handled
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(.default) { beginRename() }
                        .accessibilityHint("Rename capture")
                } else {
                    titleText
                }
            }
            .font(.headline)

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: isFocused) { _, focused in
            if !focused { finishRename(commit: true) }
        }
        .onDisappear { finishRename(commit: true) }
    }

    private var titleText: some View {
        Text(title)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(title)
    }

    private func beginRename() {
        guard let item, !isRenaming else { return }
        draft = item.displayName ?? ""
        isRenaming = true
    }

    private func finishRename(commit: Bool) {
        guard isRenaming else { return }
        isRenaming = false
        isFocused = false
        if commit { Self.rename(item, to: draft) }
    }

    static func rename(_ item: ScreenshotHistoryItem?, to draft: String) {
        guard let item else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != (item.displayName ?? "") else { return }
        ScreenshotHistoryStore.shared.rename(id: item.id, to: name)
    }
}
