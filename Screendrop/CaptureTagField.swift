import SwiftUI

/// The inspector's tag field. Typing filters the existing tags into a list
/// under the field; an empty focused field lists them all. ↓/↑ choose one,
/// Return applies the chosen tag or else the typed name (an existing tag
/// that differs only in case is reused), a click applies at once, Tab
/// completes the name without applying, Esc closes the list.
///
/// A custom list rather than native `textInputSuggestions`: in the VM on
/// macOS 27.0.1, clicking a native suggestion only filled the field and a
/// second Return was needed (sd-1iz).
struct CaptureTagField: View {
    /// Tags that can still be added: every tag except those on all the
    /// selected captures.
    let available: [String]
    let placeholder: String
    let onApply: (String) -> Void

    @State private var text = ""
    @State private var highlighted: Int?
    @State private var dismissed = false
    @State private var hoveringList = false
    @FocusState private var focused: Bool

    private static let rowHeight: CGFloat = 24
    private static let visibleRows = 8

    /// Case-insensitive matches: an exact name first, then names starting
    /// with the text, then names containing it, each in the given order.
    nonisolated static func matches(_ query: String, in tags: [String]) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tags }
        func rank(_ tag: String) -> Int {
            if tag.compare(query, options: .caseInsensitive) == .orderedSame { return 0 }
            if tag.range(of: query, options: [.caseInsensitive, .anchored]) != nil { return 1 }
            return 2
        }
        return tags.enumerated()
            .filter { $0.element.range(of: query, options: .caseInsensitive) != nil }
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    var body: some View {
        let suggestions = Self.matches(text, in: available)
        // Kept while the pointer is over the list, so a click on a row lands
        // even if the field gives up focus first.
        let showsList = (focused || hoveringList) && !dismissed && !suggestions.isEmpty
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($focused)
                .onSubmit {
                    let chosen = highlighted.flatMap { suggestions.indices.contains($0) ? suggestions[$0] : nil }
                    apply(chosen ?? text)
                }
                .onKeyPress(.downArrow) { move(1, count: suggestions.count) }
                .onKeyPress(.upArrow) { move(-1, count: suggestions.count) }
                .onKeyPress(.tab) { complete(suggestions) }
                .onKeyPress(.escape) {
                    guard showsList else { return .ignored }
                    dismissed = true
                    highlighted = nil
                    return .handled
                }
                .onChange(of: text) { _, _ in
                    highlighted = nil
                    dismissed = false
                }
                .accessibilityHint("Type to find a tag. Down Arrow chooses one, Return adds it.")
            if showsList {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.element) { index, tag in
                            row(tag, isHighlighted: index == highlighted)
                                .onHover { if $0 { highlighted = index } }
                        }
                    }
                    .padding(3)
                }
                .frame(height: CGFloat(min(suggestions.count, Self.visibleRows)) * Self.rowHeight + 6)
                .background(.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
                .onHover { hoveringList = $0 }
                .accessibilityLabel("Existing tags")
            }
        }
    }

    private func row(_ tag: String, isHighlighted: Bool) -> some View {
        Button { apply(tag) } label: {
            HStack(spacing: 6) {
                CaptureTagIcon(tag: tag)
                Text(tag).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 7)
            .frame(height: Self.rowHeight)
            .contentShape(.rect)
            .background(isHighlighted ? Color.accentColor.opacity(0.22) : .clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add tag \(tag)")
    }

    /// ↓ from the field takes the first row; ↑ from the first row goes back
    /// to the typed text.
    private func move(_ step: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        dismissed = false
        if let current = highlighted {
            let next = current + step
            highlighted = next < 0 ? nil : min(next, count - 1)
        } else {
            highlighted = step > 0 ? 0 : count - 1
        }
        return .handled
    }

    /// Tab fills in the chosen tag, or the best match, without applying it.
    /// With nothing typed and nothing chosen, Tab moves on as usual.
    private func complete(_ suggestions: [String]) -> KeyPress.Result {
        let chosen = highlighted.flatMap { suggestions.indices.contains($0) ? suggestions[$0] : nil }
        guard let tag = chosen ?? (text.isEmpty ? nil : suggestions.first), tag != text else { return .ignored }
        text = tag
        return .handled
    }

    private func apply(_ tag: String) {
        let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        onApply(name)
        text = ""
        highlighted = nil
        dismissed = false
        focused = true
    }
}
