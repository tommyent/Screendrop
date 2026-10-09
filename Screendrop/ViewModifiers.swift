//
//  ViewModifiers.swift
//  Screendrop
//
//  Reusable SwiftUI view modifiers and extensions.
//

import AppKit
import SwiftUI

// MARK: - On Click Outside

/// Fires when a mouse-down occurs outside the view's bounds within the same window.
/// The click is not consumed - the target element still receives it.
private struct OnClickOutsideModifier: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .background(ClickOutsideDetector(enabled: enabled, action: action))
    }
}

private struct ClickOutsideDetector: NSViewRepresentable {
    let enabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ClickOutsideNSView()
        view.action = action
        view.isMonitorEnabled = enabled
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ClickOutsideNSView else { return }
        view.action = action
        view.isMonitorEnabled = enabled
    }
}

private final class ClickOutsideNSView: NSView {
    var action: (() -> Void)?
    private var monitor: Any?

    var isMonitorEnabled: Bool = false {
        didSet {
            if isMonitorEnabled {
                installMonitor()
            } else {
                removeMonitor()
            }
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window else { return event }
            let locationInWindow = event.locationInWindow
            let locationInView = self.convert(locationInWindow, from: nil)
            if !self.bounds.contains(locationInView) {
                self.action?()
            }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

extension View {
    /// Fires when a click lands outside this view's bounds. The click is not consumed.
    func onClickOutside(enabled: Bool = true, perform action: @escaping () -> Void) -> some View {
        modifier(OnClickOutsideModifier(enabled: enabled, action: action))
    }
}

// MARK: - Window Accessor

/// Fires a callback whenever the SwiftUI view's hosting NSWindow changes.
private struct WindowAccessorModifier: ViewModifier {
    let onChange: (NSWindow?) -> Void

    func body(content: Content) -> some View {
        content.background(WindowAccessorView(onChange: onChange))
    }
}

private struct WindowAccessorView: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowAccessorNSView {
        let view = WindowAccessorNSView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: WindowAccessorNSView, context: Context) {
        nsView.onChange = onChange
    }
}

private final class WindowAccessorNSView: NSView {
    var onChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onChange?(window)
    }
}

extension View {
    /// Fires when this view's hosting NSWindow changes (attached or detached).
    func onWindowChange(_ onChange: @escaping (NSWindow?) -> Void) -> some View {
        modifier(WindowAccessorModifier(onChange: onChange))
    }
}
