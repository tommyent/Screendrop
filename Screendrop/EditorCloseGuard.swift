//
//  EditorCloseGuard.swift
//  Screendrop
//
//  Closing an editor window with uncommitted edits asks first - Studio and
//  the annotation editor both use this. SwiftUI has no
//  `windowShouldClose` hook, so this installs itself as the window delegate
//  and forwards every other message to the delegate SwiftUI already set -
//  taking over the window outright would break scene teardown.
//

import AppKit

@MainActor
final class EditorCloseGuard: NSObject, NSWindowDelegate {
    enum Decision {
        case save
        case discard
        case delete
        case cancel
    }

    /// Nothing to ask about when this is false.
    var hasUnsavedChanges: () -> Bool = { false }
    var canClose: () -> Bool = { true }
    /// Only a project that was never saved offers "Delete and close":
    /// discarding a project the user already committed to is unrecoverable,
    /// so that case reverts to the saved state instead.
    var offersDelete: () -> Bool = { false }
    var projectName: () -> String = { "" }
    /// Call `done(true)` once the work is saved or discarded and the window
    /// may close, or `done(false)` when it must stay open (a failed save).
    var onDecision: (Decision, @escaping (Bool) -> Void) -> Void = { _, done in done(true) }
    /// Studio keeps unsaved edits as a draft across launches, so quitting
    /// costs it nothing. The annotation editor has no draft, so it asks.
    let asksBeforeQuit: Bool

    private weak var attachedWindow: NSWindow?
    private nonisolated(unsafe) weak var previousDelegate: NSWindowDelegate?
    private var isPrompting = false
    private var isCloseApproved = false

    init(asksBeforeQuit: Bool = false) {
        self.asksBeforeQuit = asksBeforeQuit
        super.init()
    }

    /// Quitting (⌘Q, a Sparkle relaunch, logout) never calls
    /// `windowShouldClose`, so the app delegate runs the same prompt through
    /// this, one editor at a time. Returns false when nothing needs asking.
    /// Otherwise `completion(true)` follows once every editor was saved or
    /// discarded and closed; `completion(false)` on Cancel or a failed save.
    static func reviewBeforeQuit(completion: @escaping (Bool) -> Void) -> Bool {
        let editor = NSApp.windows.lazy
            .compactMap { window in (window.delegate as? EditorCloseGuard).map { (window, $0) } }
            .first { $0.1.asksBeforeQuit && $0.1.hasUnsavedChanges() }
        guard let (window, closeGuard) = editor else { return false }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Already asking about this window, or mid-save: let that finish and
        // leave quitting again to the user.
        guard !closeGuard.isPrompting, closeGuard.canClose() else {
            Task { completion(false) }
            return true
        }
        closeGuard.isPrompting = true
        closeGuard.present(on: window) { closed in
            guard closed else { return completion(false) }
            if !reviewBeforeQuit(completion: completion) { completion(true) }
        }
        return true
    }

    func attach(to window: NSWindow?) {
        guard let window else {
            detach()
            return
        }
        guard window !== attachedWindow else { return }
        // Callers configure the callbacks before attaching. Moving between
        // windows must preserve that configuration; final teardown must not.
        detachFromWindow()
        isPrompting = false
        isCloseApproved = false
        attachedWindow = window
        previousDelegate = window.delegate
        window.delegate = self
    }

    func detach() {
        detachFromWindow()
        hasUnsavedChanges = { false }
        canClose = { true }
        offersDelete = { false }
        projectName = { "" }
        onDecision = { _, done in done(true) }
        isPrompting = false
        isCloseApproved = false
    }

    private func detachFromWindow() {
        if let attachedWindow, attachedWindow.delegate === self {
            attachedWindow.delegate = previousDelegate
        }
        attachedWindow = nil
        previousDelegate = nil
    }

    /// Mirrors the dirty state onto the close button's dot, so the prompt is
    /// never the first hint that something is unsaved.
    func refreshDocumentEdited() {
        attachedWindow?.isDocumentEdited = hasUnsavedChanges()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard canClose() else { return false }
        if isCloseApproved { return true }
        guard hasUnsavedChanges() else { return true }
        guard !isPrompting else { return false }

        isPrompting = true
        present(on: sender)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // Break callback ownership at the AppKit close boundary, even if
        // SwiftUI keeps the scene's state around after its window closes.
        let delegate = previousDelegate
        detach()
        // We implement this delegate method, so forwardingTarget no longer
        // forwards it. SwiftUI still needs the notification to tear down.
        delegate?.windowWillClose?(notification)
    }

    private func present(on window: NSWindow, then finished: ((Bool) -> Void)? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = offersDelete()
            ? "Do you want to save your project before closing or delete it?"
            : "Do you want to save the changes to “\(projectName())”?"
        alert.informativeText = offersDelete()
            ? "This recording has never been saved. Deleting it removes the footage as well."
            : "Your changes since the last save will be lost if you don't save them."

        alert.addButton(withTitle: "Save and Close")
        alert.addButton(withTitle: offersDelete() ? "Delete and Close" : "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        // Escape and ⌘. land on Cancel rather than destroying anything.
        alert.buttons[2].keyEquivalent = "\u{1b}"

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isPrompting = false

            let decision: Decision
            switch response {
            case .alertFirstButtonReturn:
                decision = .save
            case .alertSecondButtonReturn:
                decision = self.offersDelete() ? .delete : .discard
            default:
                decision = .cancel
            }

            guard decision != .cancel else {
                finished?(false)
                return
            }

            self.onDecision(decision) { [weak self, weak window] closes in
                guard closes, let self, let window else {
                    finished?(false)
                    return
                }
                // Deleting already tore the project down; either way the
                // window is now free to go.
                self.isCloseApproved = true
                window.close()
                finished?(true)
            }
        }
    }

    // MARK: - Delegate passthrough

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return previousDelegate?.responds(to: aSelector) ?? false
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        previousDelegate
    }
}
