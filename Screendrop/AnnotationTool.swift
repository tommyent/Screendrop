//
//  AnnotationTool.swift
//  Screendrop
//

enum AnnotationTool: String, CaseIterable, Identifiable, Codable {
    case select
    case rectangle
    case filledRectangle
    case ellipse
    case line
    case arrow
    case freehand
    case numberedCircle
    case text
    case highlight
    case pixelate
    case blur
    case magnifier

    var id: String { rawValue }

    /// Keep the old raw value readable without giving a fill style its own tool.
    var paletteTool: AnnotationTool { self == .filledRectangle ? .rectangle : self }

    static var paletteTools: [AnnotationTool] { allCases.filter { $0 != .select && $0 != .filledRectangle } }

    var title: String {
        switch self {
        case .select:
            "Select"
        case .rectangle:
            "Rectangle"
        case .filledRectangle:
            "Solid rectangle"
        case .ellipse:
            "Circle"
        case .line:
            "Straight line"
        case .arrow:
            "Arrow"
        case .freehand:
            "Freehand"
        case .numberedCircle:
            "Numbered circle"
        case .pixelate:
            "Pixelate"
        case .blur:
            "Blur"
        case .text:
            "Text"
        case .highlight:
            "Highlight"
        case .magnifier:
            "Magnifier"
        }
    }

    var systemImage: String {
        switch self {
        case .select:
            "hand.point.up.left"
        case .rectangle:
            "rectangle"
        case .filledRectangle:
            "square.fill"
        case .ellipse:
            "circle"
        case .line:
            "line.diagonal"
        case .arrow:
            "arrow.up.right"
        case .freehand:
            "scribble"
        case .numberedCircle:
            "1.circle.fill"
        case .pixelate:
            "app.background.dotted"
        case .blur:
            "drop.fill"
        case .text:
            "textformat"
        case .highlight:
            "square.dashed.inset.filled"
        case .magnifier:
            "plus.magnifyingglass"
        }
    }

    var helpText: String {
        let shortcut: String
        switch self {
        case .select, .filledRectangle, .freehand: return title
        case .rectangle: shortcut = "R"
        case .ellipse: shortcut = "O"
        case .line: shortcut = "L"
        case .arrow: shortcut = "A"
        case .numberedCircle: shortcut = "1"
        case .text: shortcut = "T"
        case .highlight: return "Highlight: keep this area visible and dim everything outside"
        case .pixelate: shortcut = "P"
        case .blur: shortcut = "B"
        case .magnifier: shortcut = "M"
        }
        return "\(title) (\(shortcut))"
    }

    var isFilledShape: Bool {
        self == .filledRectangle
    }

    var usesEndpoints: Bool {
        self == .line || self == .arrow
    }

    var isRedactionTool: Bool {
        self == .pixelate || self == .blur
    }

    var supportsColorStyle: Bool {
        switch self {
        case .rectangle, .filledRectangle, .ellipse, .line, .arrow, .freehand, .numberedCircle, .text, .magnifier:
            true
        case .select, .pixelate, .blur, .highlight:
            false
        }
    }

    var supportsStrokeStyle: Bool {
        switch self {
        case .rectangle, .ellipse, .line, .arrow, .freehand, .magnifier:
            true
        case .select, .filledRectangle, .numberedCircle, .pixelate, .blur, .text, .highlight:
            false
        }
    }

    var supportsRedactionDensityStyle: Bool {
        isRedactionTool
    }

    var supportsHandDrawnStyle: Bool {
        [.rectangle, .filledRectangle, .ellipse, .line, .arrow].contains(self)
    }

    var supportsAspectLock: Bool {
        switch self {
        case .rectangle, .filledRectangle, .ellipse, .highlight:
            true
        case .select, .line, .arrow, .freehand, .numberedCircle, .pixelate, .blur, .text, .magnifier:
            false
        }
    }

    var createsAnnotation: Bool {
        self != .select
    }
}
