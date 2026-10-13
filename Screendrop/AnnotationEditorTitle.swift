import AppKit
import Foundation
import SwiftUI

struct AnnotationEditorTitle: View {
    let title: String
    let status: String
    let item: ScreenshotHistoryItem?
    @State private var isRenaming = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if isRenaming {
                    AnnotationTitleNameField(
                        text: $draft,
                        placeholder: item.map { CaptureLibraryItem.dateTitle($0.createdAt) } ?? title,
                        onCommit: { finishRename(commit: true) },
                        onCancel: { finishRename(commit: false) }
                    )
                        .onClickOutside { finishRename(commit: true) }
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
            .frame(maxWidth: .infinity, alignment: .leading)

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // Keep the toolbar item's width stable when its label becomes a field.
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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
        if commit { Self.rename(item, to: draft) }
    }

    static func rename(_ item: ScreenshotHistoryItem?, to draft: String) {
        guard let item else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != (item.displayName ?? "") else { return }
        ScreenshotHistoryStore.shared.rename(id: item.id, to: name)
    }
}

struct AnnotationTitleNameField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> AnnotationTitleNSTextField {
        AnnotationTitleNSTextField(frame: .zero)
    }

    func updateNSView(_ field: AnnotationTitleNSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.onChange = { text = $0 }
        field.onCommit = onCommit
        field.onCancel = onCancel
    }

    static func dismantleNSView(_ field: AnnotationTitleNSTextField, coordinator: Void) {
        field.onChange = nil
        field.onCommit = nil
        field.onCancel = nil
        if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
    }
}

final class AnnotationTitleNSTextField: NSTextField, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    private var didFocus = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        isEditable = true
        isSelectable = true
        usesSingleLineMode = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        font = .preferredFont(forTextStyle: .headline)
        cell?.setAccessibilityLabel("Name")
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didFocus else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !self.didFocus,
                  window.makeFirstResponder(self) else { return }
            self.didFocus = true
            if let editor = self.currentEditor() as? NSTextView {
                editor.setSelectedRange(NSRange(location: 0, length: self.stringValue.utf16.count))
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) { onChange?(stringValue) }

    func controlTextDidEndEditing(_ notification: Notification) {
        onChange?(stringValue)
        onCommit?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onChange?(stringValue)
            onCommit?()
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        default:
            return false
        }
        return true
    }
}
