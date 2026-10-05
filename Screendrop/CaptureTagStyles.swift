//
//  CaptureTagStyles.swift
//  Screendrop
//

import Foundation
import Observation
import SwiftUI

/// A tag's look: a colour from Finder's palette and an outline symbol, both
/// optional. Tags stay plain names on each capture; how each one looks is
/// kept once, here, for the whole Library.
nonisolated struct CaptureTagStyle: Codable, Equatable {
    var color: CaptureTagColor?
    var symbol: String?
}

nonisolated enum CaptureTagColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, gray

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}

@Observable
final class CaptureTagStyles {
    static let shared = CaptureTagStyles()

    /// The outline symbols on offer, with their menu titles. A stored symbol
    /// not on this list shows as the plain tag.
    static let symbols: [(name: String, title: String)] = [
        ("tag", "Tag"), ("star", "Star"), ("flag", "Flag"), ("bookmark", "Bookmark"),
        ("bug", "Bug"), ("lightbulb", "Idea"), ("briefcase", "Work"), ("person", "Person"),
        ("house", "Home"), ("heart", "Heart"), ("doc", "Document"), ("paintbrush", "Design"),
        ("sparkles", "Sparkles"), ("exclamationmark.triangle", "Warning"),
    ]

    private static let defaultsKey = "captureLibrary.tagStyles"

    /// Keyed by the tag's lowercased name, since tags differing only in case
    /// are one tag.
    private var styles: [String: CaptureTagStyle] = [:]

    private init() {
        // Entry by entry, so one unreadable style can't wipe the others.
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (key, value) in entries {
            // Only an object can be re-encoded; anything else (null, a
            // string, a number) would raise rather than fail.
            guard let object = value as? [String: Any],
                  let entry = try? JSONSerialization.data(withJSONObject: object),
                  let style = try? JSONDecoder().decode(CaptureTagStyle.self, from: entry) else { continue }
            styles[key] = style
        }
    }

    func style(for tag: String) -> CaptureTagStyle {
        styles[tag.lowercased()] ?? CaptureTagStyle()
    }

    func symbol(for tag: String) -> String {
        let symbol = style(for: tag).symbol
        return Self.symbols.contains { $0.name == symbol } ? symbol ?? "tag" : "tag"
    }

    func color(for tag: String) -> Color? {
        style(for: tag).color?.color
    }

    func setColor(_ color: CaptureTagColor?, for tag: String) {
        update(tag) { $0.color = color }
    }

    func setSymbol(_ symbol: String, for tag: String) {
        update(tag) { $0.symbol = symbol == "tag" ? nil : symbol }
    }

    private func update(_ tag: String, _ change: (inout CaptureTagStyle) -> Void) {
        var style = style(for: tag)
        change(&style)
        styles[tag.lowercased()] = style == CaptureTagStyle() ? nil : style
        if let data = try? JSONEncoder().encode(styles) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// A tag's symbol in its colour, or in secondary gray without one.
struct CaptureTagIcon: View {
    let tag: String
    private var styles: CaptureTagStyles { .shared }

    var body: some View {
        Image(systemName: styles.symbol(for: tag))
            .foregroundStyle(styles.color(for: tag) ?? .secondary)
    }
}

/// Colour and icon choices for one tag. They change the tag everywhere in
/// the Library, not only on the selected captures.
struct CaptureTagAppearanceMenu: View {
    let tag: String
    private var styles: CaptureTagStyles { .shared }

    var body: some View {
        Picker("Color", selection: Binding(
            get: { styles.style(for: tag).color },
            set: { styles.setColor($0, for: tag) }
        )) {
            Text("None").tag(CaptureTagColor?.none)
            ForEach(CaptureTagColor.allCases) { color in
                Text(color.title).tag(Optional(color))
            }
        }
        .pickerStyle(.menu)
        Picker("Icon", selection: Binding(
            get: { styles.symbol(for: tag) },
            set: { styles.setSymbol($0, for: tag) }
        )) {
            ForEach(CaptureTagStyles.symbols, id: \.name) { symbol in
                Label(symbol.title, systemImage: symbol.name).tag(symbol.name)
            }
        }
        .pickerStyle(.menu)
    }
}
