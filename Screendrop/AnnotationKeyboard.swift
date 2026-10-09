//
//  AnnotationKeyboard.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct AnnotationKeyCommandHandler: NSViewRepresentable {
    let isEnabled: () -> Bool
    let onDelete: () -> Void
    let onSave: () -> Void
    let onCopy: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onSelectAll: () -> Void
    let onSelectTool: (AnnotationTool) -> Void
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onFitCanvas: () -> Void
    let onActualSize: () -> Void
    let onToggleCrop: () -> Void
    let onApplyCrop: () -> Void
    let onCancelCrop: () -> Void
    let isCropping: () -> Bool
    /// Tab: copies the colour under the pointer; false when it isn't over the image.
    let onCopyColor: () -> Bool
    /// A held arrow key measures (an axis); its release, or the window
    /// losing focus, ends that (nil). Returns whether the key was used.
    let onMeasure: (PixelMeasureAxis?) -> Bool
    let onEscape: () -> Void

    func makeNSView(context: Context) -> AnnotationKeyCommandHandlerView {
        let view = AnnotationKeyCommandHandlerView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: AnnotationKeyCommandHandlerView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: AnnotationKeyCommandHandlerView) {
        view.isEnabled = isEnabled
        view.onDelete = onDelete
        view.onSave = onSave
        view.onCopy = onCopy
        view.onUndo = onUndo
        view.onRedo = onRedo
        view.onSelectAll = onSelectAll
        view.onSelectTool = onSelectTool
        view.onZoomIn = onZoomIn
        view.onZoomOut = onZoomOut
        view.onFitCanvas = onFitCanvas
        view.onActualSize = onActualSize
        view.onToggleCrop = onToggleCrop
        view.onApplyCrop = onApplyCrop
        view.onCancelCrop = onCancelCrop
        view.isCropping = isCropping
        view.onCopyColor = onCopyColor
        view.onMeasure = onMeasure
        view.onEscape = onEscape
    }
}

final class AnnotationKeyCommandHandlerView: NSView {
    var isEnabled: (() -> Bool)?
    var onDelete: (() -> Void)?
    var onSave: (() -> Void)?
    var onCopy: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onSelectTool: ((AnnotationTool) -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onFitCanvas: (() -> Void)?
    var onActualSize: (() -> Void)?
    var onToggleCrop: (() -> Void)?
    var onApplyCrop: (() -> Void)?
    var onCancelCrop: (() -> Void)?
    var isCropping: (() -> Bool)?
    var onCopyColor: (() -> Bool)?
    var onMeasure: ((PixelMeasureAxis?) -> Bool)?
    var onEscape: (() -> Void)?

    private var localKeyMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLocalKeyMonitor()
        // A key released while another window has focus never reaches us.
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.onMeasure?(nil) }
            }
        }
    }

    deinit {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let localKeyUpMonitor {
            NSEvent.removeMonitor(localKeyUpMonitor)
        }
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
    }

    private func updateLocalKeyMonitor() {
        guard localKeyMonitor == nil else { return }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else {
                return event
            }

            guard self.isEnabled?() != false else { return nil }

            if Self.isSave(event) {
                self.onSave?()
                return nil
            }

            if Self.isEditingText(in: self.window) {
                return event
            }

            // Crop mode is modal: Return applies, Escape cancels, and all other
            // editing shortcuts are swallowed so they can't act on the hidden
            // annotation layer.
            if self.isCropping?() == true {
                if Self.isReturn(event) {
                    self.onApplyCrop?()
                    return nil
                }
                if Self.isEscape(event) {
                    self.onCancelCrop?()
                    return nil
                }
                if Self.isUndo(event) || Self.isRedo(event) {
                    return event
                }
                return nil
            }

            // Tab and the arrow keys belong to whichever inspector control
            // has keyboard focus, held repeats included (a slider steps its
            // value with them). Only with nothing focused do they act on the
            // pixels under the pointer.
            let nothingFocused = self.window?.firstResponder === self.window

            // Tab copies the colour under the pointer, as in Shottr. Off the
            // image it keeps moving the keyboard focus.
            if nothingFocused, Self.isPlainTab(event), self.onCopyColor?() == true {
                return nil
            }

            // Holding an arrow key over the image measures, as in Shottr:
            // up or down the height under the pointer, left or right the
            // width. Shift may be held too; it includes the border.
            if nothingFocused, let axis = Self.measureAxis(event), self.onMeasure?(axis) == true {
                return nil
            }

            if Self.isEscape(event) {
                self.onEscape?()
                return nil
            }

            if Self.isCopy(event) {
                self.onCopy?()
                return nil
            }

            if Self.isCropToggle(event) {
                self.onToggleCrop?()
                return nil
            }

            if Self.isPlainDelete(event) {
                self.onDelete?()
                return nil
            }

            if Self.isUndo(event) {
                self.onUndo?()
                return nil
            }

            if Self.isRedo(event) {
                self.onRedo?()
                return nil
            }

            if Self.isSelectAll(event) {
                self.onSelectAll?()
                return nil
            }

            if Self.isZoomIn(event) {
                self.onZoomIn?()
                return nil
            }

            if Self.isZoomOut(event) {
                self.onZoomOut?()
                return nil
            }

            if Self.isFitCanvas(event) {
                self.onFitCanvas?()
                return nil
            }

            if Self.isActualSize(event) {
                self.onActualSize?()
                return nil
            }

            if let tool = Self.toolShortcut(for: event) {
                self.onSelectTool?(tool)
                return nil
            }

            return event
        }

        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            // Any arrow released ends a measurement, even with a modifier
            // pressed since it went down.
            if Self.isArrow(event), self?.window?.isKeyWindow == true {
                _ = self?.onMeasure?(nil)
            }
            return event
        }
    }

    private static func isArrow(_ event: NSEvent) -> Bool {
        (123...126).contains(event.keyCode)
    }

    /// ←/→ measure across, ↑/↓ down; with Command, Option or Control they
    /// are left alone.
    private static func measureAxis(_ event: NSEvent) -> PixelMeasureAxis? {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return nil }
        switch event.keyCode {
        case 123, 124: return .horizontal
        case 125, 126: return .vertical
        default: return nil
        }
    }

    private static func isPlainDelete(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            && (event.keyCode == 51 || event.keyCode == 117)
    }

    private static func isReturn(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }

    private static func isEscape(_ event: NSEvent) -> Bool {
        event.keyCode == 53
    }

    private static func isPlainTab(_ event: NSEvent) -> Bool {
        event.keyCode == 48 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    private static func isCropToggle(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            && event.charactersIgnoringModifiers?.lowercased() == "c"
    }

    private static func isEditingText(in window: NSWindow?) -> Bool {
        window?.firstResponder is NSTextView
    }

    /// Save stays live even while a text field has focus: losing annotations
    /// because the caret happened to be in the inspector is exactly what this
    /// shortcut exists to prevent.
    private static func isSave(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.shift)
            && !event.modifierFlags.contains(.option)
            && event.charactersIgnoringModifiers?.lowercased() == "s"
    }

    /// Only reached when no text is being edited, so Cmd-C in a text
    /// annotation or an inspector field still copies the text.
    private static func isCopy(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && event.modifierFlags.intersection([.shift, .option, .control]).isEmpty
            && event.charactersIgnoringModifiers?.lowercased() == "c"
    }

    private static func isUndo(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.shift)
            && event.charactersIgnoringModifiers?.lowercased() == "z"
    }

    private static func isRedo(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && event.modifierFlags.contains(.shift)
            && event.charactersIgnoringModifiers?.lowercased() == "z"
    }

    private static func isSelectAll(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.shift)
            && event.charactersIgnoringModifiers?.lowercased() == "a"
    }

    private static func isZoomIn(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        let character = event.charactersIgnoringModifiers
        return character == "+" || character == "="
    }

    private static func isZoomOut(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && (event.charactersIgnoringModifiers == "-" || event.charactersIgnoringModifiers == "_")
    }

    private static func isFitCanvas(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.shift)
            && event.charactersIgnoringModifiers == "1"
    }

    private static func isActualSize(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.shift)
            && event.charactersIgnoringModifiers == "0"
    }

    private static func toolShortcut(for event: NSEvent) -> AnnotationTool? {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let character = event.charactersIgnoringModifiers?.lowercased(),
              character.count == 1 else {
            return nil
        }

        switch character {
        case "r": return .rectangle
        case "o": return .ellipse
        case "t": return .text
        case "l": return .line
        case "a": return .arrow
        case "p": return .pixelate
        case "b": return .blur
        case "1": return .numberedCircle
        default: return nil
        }
    }
}
