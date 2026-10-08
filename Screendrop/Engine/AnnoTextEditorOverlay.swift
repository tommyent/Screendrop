import AppKit
import Foundation

/// A text view laid over the canvas while a text shape is being edited.
///
/// The canvas skips drawing the shape while this is up, so what you see is the live text view.
/// Using a real `NSTextView` means selection, arrow keys, IME and system text services all work,
/// rather than reimplementing them against a hand-rolled caret.
///
/// Ported from the drawing-app's `UI/TextEditorOverlay.swift`.
@MainActor
final class AnnoTextEditorOverlay: NSTextView {
    private weak var editor: AnnoEditor?
    private var shapeId: AnnoShapeID?

    /// Which shape this caret belongs to, so the canvas can tell a retarget from a no-op.
    var editedShapeId: AnnoShapeID? { shapeId }

    /// The box behind the text while it's edited, in view points; nil for plain text.
    private var boxFill: NSColor? {
        didSet { if boxFill != oldValue { needsDisplay = true } }
    }
    private var boxCornerRadius: CGFloat = 0
    /// The shape's own box in view points. Not the view's bounds: those leave room for the caret
    /// past the last glyph, and the box would shrink by that much when typing ends.
    private var boxSize: CGSize = .zero

    /// `NSTextView.init(frame:)` is a convenience initializer that builds the text network and then
    /// routes through this designated one, so a subclass has to implement it - otherwise the
    /// runtime traps on an unimplemented initializer.
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    convenience init(editor: AnnoEditor, shapeId: AnnoShapeID) {
        // Build the text network by hand rather than going through `init(frame:)`, which Swift no
        // longer inherits now that the designated initializer above is overridden.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)

        self.init(frame: .zero, textContainer: container)
        self.editor = editor
        self.shapeId = shapeId
    }

    private func configure() {
        isRichText = false
        importsGraphics = false
        drawsBackground = false
        isVerticallyResizable = true
        // sync() owns the width; native fitting can shift aligned text's container origin.
        isHorizontallyResizable = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        // The shape owns wrapping: it measures the text and sets the frame, so the container must
        // not impose a width of its own.
        textContainer?.widthTracksTextView = false
        allowsUndo = false
        focusRingType = .none
        delegate = self
    }

    /// Style and position the overlay to sit exactly where the shape is drawn.
    func sync() {
        guard let editor, let shapeId,
              let shape = editor.document.shape(shapeId),
              let props = shape.textProps else { return }

        let zoom = editor.viewport.scale
        // The overlay lays out in view points, so scale the shape's page-space type up by the
        // camera before styling.
        var viewProps = props
        viewProps.fontSize = Swift.max(1, props.fontSize * zoom)
        viewProps.w = props.w * zoom

        let fontSize = CGFloat(viewProps.fontSize)
        let font = TextMeasure.font(viewProps, opticalSize: props.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = props.align.nsTextAlignment
        paragraph.minimumLineHeight = TextMeasure.lineHeight(viewProps)
        paragraph.maximumLineHeight = TextMeasure.lineHeight(viewProps)
        paragraph.lineBreakMode = .byWordWrapping

        let ink = TextMeasure.ink(props).nsColor
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: ink,
        ]
        if props.isUnderline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        typingAttributes = attributes
        defaultParagraphStyle = paragraph
        self.font = font
        textColor = ink
        alignment = paragraph.alignment
        insertionPointColor = ink
        if let storage = textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }

        // A box draws behind the text (see `draw`) and pads it on every side; plain text has no
        // inset, so this is a no-op for it.
        let pageInset = TextMeasure.boxInsets(props)
        let insetX = pageInset.x * zoom
        let insetY = pageInset.y * zoom
        textContainerInset = NSSize(width: insetX, height: insetY)
        boxFill = props.hasBox ? props.swatch.nsColor : nil
        boxCornerRadius = TextMeasure.boxCornerRadius(props) * zoom

        // Everything the shape draws, in view space. The frame origin is the shape's top-left
        // corner - its local origin, or the box's corner - placed where the shape's rotation puts
        // it, so `frameRotation` turning about that corner matches the drawn shape.
        let bounds = editor.document.geometry(shape).bounds
        boxSize = CGSize(width: bounds.w * zoom, height: bounds.h * zoom)
        let origin = editor.pageToScreen(shape.pageTransform.applyToPoint(Vec(bounds.x, bounds.y)))
        var width = Swift.max(bounds.w * zoom, Double(fontSize) * 0.6 + insetX * 2)
        var height = Swift.max(bounds.h * zoom, Double(TextMeasure.lineHeight(viewProps)) + insetY * 2)

        if props.autoSize, let container = textContainer {
            // Measure independently with the overlay's exact scaled font. During native edits,
            // the attached layout manager can report the entire unbounded container as used,
            // placing centered or end-aligned glyphs far outside the canvas.
            let measured = NSAttributedString(string: string, attributes: attributes).size()
            let natural = ceil(measured.width)
            // Match TextMeasure's one-point allowance in the natural-width container.
            container.size = CGSize(width: natural + 1, height: CGFloat.greatestFiniteMagnitude)
            // Leave room for the caret past the last glyph.
            width = Swift.max(width, Double(natural + fontSize * 0.5) + insetX * 2)
            height = Swift.max(height, Double(ceil(measured.height)) + insetY * 2)
        } else {
            textContainer?.size = CGSize(width: width - insetX * 2, height: CGFloat.greatestFiniteMagnitude)
        }

        frameRotation = 0
        frame = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        // The canvas is flipped, so a positive rotation reads clockwise on screen - the same
        // direction a positive `shape.rotation` turns the drawn shape.
        frameRotation = shape.rotation * 180 / .pi
    }

    func loadText() {
        guard let editor, let shapeId,
              let props = editor.document.shape(shapeId)?.textProps else { return }
        string = props.text
        sync()
        let caret = editor.textCaretPagePoint
        editor.textCaretPagePoint = nil
        let index = caret.flatMap { characterIndex(atPage: $0) } ?? (string as NSString).length
        setSelectedRange(NSRange(location: index, length: 0))
    }

    /// Where a page point falls in this view's TextKit layout. The view is already positioned
    /// and rotated like the shape, so converting from the canvas accounts for both.
    private func characterIndex(atPage pagePoint: Vec) -> Int? {
        guard let editor, let superview, let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let screen = editor.pageToScreen(pagePoint)
        let local = convert(NSPoint(x: screen.x, y: screen.y), from: superview)
        let index = characterIndexForInsertion(at: local)
        guard index >= 0, index <= (string as NSString).length else { return nil }
        return index
    }

    /// Draw the caret's text the way the canvas draws committed text: plain antialiasing, no font
    /// smoothing. AppKit stem-darkens light text on a dark background, which made type look
    /// noticeably heavier while editing than it did the moment it committed - and heavier than the
    /// exported PNG, which is the side that has to be right.
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        // The canvas skips the shape while it's edited, so the box has to come from here.
        if let boxFill {
            boxFill.setFill()
            NSBezierPath(
                roundedRect: CGRect(origin: .zero, size: boxSize),
                xRadius: boxCornerRadius,
                yRadius: boxCornerRadius
            ).fill()
        }
        super.draw(dirtyRect)
    }

    override func cancelOperation(_ sender: Any?) {
        editor?.stopEditingText()
    }
}

extension AnnoTextEditorOverlay: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let shapeId else { return }
        editor?.updateEditingText(shapeId, to: string)
        // The shape may have grown or moved to keep its alignment anchor; follow it.
        sync()
    }
}
