//
//  QuickLookPreviewPresenter.swift
//  Screendrop
//
//  Created by Codex on 26/04/26.
//

import AppKit
import QuickLookUI

@MainActor
final class QuickLookPreviewPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreviewPresenter()
    
    private var previewURL: NSURL?
    /// Set when Quick Look itself tucked an expanded stack into its peek tab,
    /// so closing Quick Look expands only a stack it tucked. It records that
    /// first collapse, not later changes: if the stack is expanded and tucked
    /// again by something else while Quick Look stays open, closing still
    /// expands it.
    private var collapsedPreviewStack = false
    
    static var isShown: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    static var currentURL: URL? { shared.previewURL as URL? }
    
    /// Pass `collapsingPreviewStack: true` when previewing from the floating
    /// stack, so its cards don't sit on top of the Quick Look window.
    static func show(url: URL, collapsingPreviewStack: Bool = false) {
        shared.show(url: url, collapsingPreviewStack: collapsingPreviewStack)
    }
    
    static func dismiss() {
        shared.dismiss()
    }
    
    private func show(url: URL, collapsingPreviewStack: Bool) {
        previewURL = url as NSURL
        
        guard let panel = QLPreviewPanel.shared() else {
            restorePreviewStack()
            return
        }

        // Activate the app *before* presenting the panel so macOS considers
        // it the frontmost process. Without this, the QuickLook window opens
        // unfocused and videos won't autoplay until manually clicked.
        NSApp.activate()

        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        // Collapse the floating overlay into the peek tab so it doesn't sit on
        // top of the Quick Look window. Expanded again when Quick Look closes.
        let stack = ScreenshotPreviewStack.shared
        if collapsingPreviewStack, !stack.isCollapsed {
            stack.collapse()
            collapsedPreviewStack = stack.isCollapsed
        }
        if panel.isVisible {
            panel.refreshCurrentPreviewItem()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }

        // Re-assert key status on the next runloop pass. The window server
        // sometimes needs a tick to finish processing the activation, so an
        // immediate makeKey can be silently dropped when the app was inactive.
        DispatchQueue.main.async {
            panel.makeKeyAndOrderFront(nil)
        }
    }
    
    private func dismiss() {
        // Only restore (expand) the overlay if Quick Look is actually on screen.
        // This method doubles as generic cleanup that's called whenever cards are
        // inserted or removed; in those cases there's no Quick Look window to
        // close, and unconditionally expanding would pop the collapsed peek stack
        // back open (e.g. when an auto-close timer fires in peek mode).
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible else {
            previewURL = nil
            return
        }

        panel.orderOut(nil)
        previewURL = nil
        restorePreviewStack()
    }

    /// Fires when Quick Look closes on its own (e.g. the user clicks its close
    /// button or it loses key focus), which bypasses `dismiss()`.
    func windowWillClose(_ notification: Notification) {
        previewURL = nil
        restorePreviewStack()
    }

    /// Expands the stack only if Quick Look tucked it (see `collapsedPreviewStack`).
    private func restorePreviewStack() {
        guard collapsedPreviewStack else { return }
        collapsedPreviewStack = false
        ScreenshotPreviewStack.shared.expand()
    }
    
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            previewURL == nil ? 0 : 1
        }
    }
    
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            previewURL
        }
    }
}
