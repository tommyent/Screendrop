//
//  AnnotationPresetStore.swift
//  Screendrop
//
//  Created by Codex on 01/05/26.
//

import AppKit
import Foundation

enum AnnotationPresetStore {
    private static let key = "annotationStylePreset"

    static func load() -> AnnotationStylePreset {
        guard let data = UserDefaults.standard.data(forKey: key),
              let preset = try? JSONDecoder().decode(AnnotationStylePreset.self, from: data) else {
            return AnnotationStylePreset()
        }

        return preset
    }

    static func save(_ preset: AnnotationStylePreset) {
        guard let data = try? JSONEncoder().encode(preset) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

struct AnnotationStylePreset: Codable, Equatable {
    var selectedToolRawValue = AnnotationTool.rectangle.rawValue
    var swatchID = AnnotationSwatch.red.id
    var customSwatch: CodableSwatch?
    var strokeWidth: Double = 4
    var redactionDensity: Double = 0.55
    var textFontName = AnnotationTextMetrics.defaultFontName
    /// Optional for the same reason as the box fields below. `textFontName` stays an SF family, so
    /// older builds read a face as SF Pro.
    var textFontFace: String?
    var textFontSize: Double = 48
    var textIsBold = true
    var textIsItalic = false
    var textIsUnderline = false
    var textAlignmentRawValue = NSTextAlignment.left.rawValue
    // Optional, unlike the fields above: synthesized decoding requires every non-optional key, so
    // a required new field would fail every preset saved before it and silently reset them all.
    var textBoxStyleRawValue: String?
    var geoFillRawValue: String?
    var handDrawn: Bool?

    var selectedTool: AnnotationTool {
        (AnnotationTool(rawValue: selectedToolRawValue) ?? .rectangle).paletteTool
    }

    var geoFill: AnnoFillStyle {
        geoFillRawValue.flatMap(AnnoFillStyle.init(rawValue:))
            ?? (selectedToolRawValue == AnnotationTool.filledRectangle.rawValue ? .solid : .none)
    }

    var swatch: AnnotationSwatch {
        if let customSwatch {
            return customSwatch.annotationSwatch
        }

        return AnnotationSwatch.allCases.first { $0.id == swatchID } ?? .red
    }

    var textAlignment: NSTextAlignment {
        NSTextAlignment(rawValue: textAlignmentRawValue) ?? .left
    }

    var textBoxStyle: TextBoxStyle {
        textBoxStyleRawValue.flatMap(TextBoxStyle.init(rawValue:)) ?? .plain
    }
}

struct CodableSwatch: Codable, Equatable {
    var id: String
    var title: String
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(swatch: AnnotationSwatch) {
        id = swatch.id
        title = swatch.title
        red = Double(swatch.red)
        green = Double(swatch.green)
        blue = Double(swatch.blue)
        alpha = Double(swatch.alpha)
    }

    var annotationSwatch: AnnotationSwatch {
        AnnotationSwatch(
            id,
            title: title,
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }
}
