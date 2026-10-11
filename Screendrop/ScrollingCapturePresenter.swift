//
//  ScrollingCapturePresenter.swift
//  Screendrop
//

import AppKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

/// Runs a scrolling capture: the user draws a region, scrolls under it, and
/// clicks Done. Frames go to `ScrollingCaptureFeed`: Vision proposes, exact
/// pixels confirm, and a frame that doesn't fit is skipped until one does.
/// The region stays highlighted, with `ScrollingCaptureBar` below it; the
/// scrolled app keeps the keyboard, so the bar or the shortcut ends a session,
/// or auto-scroll reaching the end of the page.
@Observable
final class ScrollingCapturePresenter {
    static let shared = ScrollingCapturePresenter()

    struct Capture {
        let image: CGImage
        let displayID: CGDirectDisplayID
        /// Pixels per point of the captured display.
        let scale: CGFloat
    }

    private enum Outcome { case done, cancelled }

    /// ponytail: stops at 16,384 px, the GPU texture limit on Apple silicon:
    /// the editor isn't verified with taller images. Raise once it is.
    private static let maximumHeight = 16_384
    /// Right-edge strip left out of matching, where the overlay scroll bar
    /// appears while scrolling.
    private static let scrollBarWidth: CGFloat = 20

    private(set) var isRunning = false
    private(set) var stitchedHeight = 0
    /// The latest frame didn't fit the last one placed; scrolling back a
    /// little brings the view back to where it does.
    private(set) var isWaiting = false
    /// The capture is as tall as it can get; only Done or Cancel are left.
    private(set) var hasReachedLimit = false
    /// Waiting, and the page keeps changing: the bar asks for it to be paused.
    private(set) var keepsChanging = false
    /// Screendrop is scrolling the region itself, a step at a time.
    private(set) var isAutoScrolling = false
    /// Frames are coming in, so auto-scroll has something to follow.
    private(set) var canAutoScroll = false
    /// Auto-scroll was asked for without the Accessibility permission it
    /// needs to post scroll events; the user scrolls by hand.
    private(set) var needsScrollPermission = false

    @ObservationIgnored private var outcome: Outcome?
    @ObservationIgnored private var isSelectingArea = false
    @ObservationIgnored private var isCapturing = false
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var stream: ScrollingCaptureStream?
    /// Done's or Cancel's click, on the stream's clock: frames shown after it aren't kept.
    @ObservationIgnored private var cutoff: TimeInterval?
    @ObservationIgnored private var autoScroller: ScrollingCaptureAutoScroller?
    /// The display time of the newest frame placed or skipped, which
    /// auto-scroll waits for before each step.
    @ObservationIgnored private var lastFrameTime: TimeInterval = 0
    /// macOS shows the Accessibility prompt at most once, so it's asked for
    /// on the first press only; after that the button opens Settings.
    @ObservationIgnored private var didRequestScrollPermission = false

    private init() {}

    /// Returns the stitched capture, or nil if the user cancelled or nothing
    /// could be captured.
    func run() async -> Capture? {
        // An area recording is using the region highlight.
        guard !isRunning, !ScreenRecordingManager.shared.isActive else {
            NSSound.beep()
            return nil
        }
        isRunning = true
        outcome = nil
        defer { isRunning = false }

        guard ScreenRecordingManager.ensureScreenCapturePermission(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        let pointerDisplayID = ActiveDisplayResolver.activeDisplayID(preferPointer: true)
        guard let display = content.displays.first(where: { $0.displayID == pointerDisplayID }) ?? content.displays.first,
              outcome == nil, let rect = await selectArea(on: display), outcome != .cancelled else {
            return nil
        }

        // Screendrop's own windows are always left out, whatever the
        // app-windows preference says: the capture bar and highlight sit on
        // screen the whole time and must never end up in a frame.
        let filter = ScreenRecordingCapture.displayFilter(display: display, content: content, includesAppWindows: false)
        let screen = ActiveDisplayResolver.screen(for: display.displayID)
        // Whole points, so every frame maps 1:1 onto screen pixels with no
        // resampling. Stitching relies on rows matching exactly.
        let selectionRect = ScreenRecordingManager.sourceRect(forAppKitSelectionRect: rect, screenFrame: screen?.frame,
            contentRect: filter.contentRect).integral.intersection(filter.contentRect)
        let targets = Set(content.windows.filter {
            $0.windowLayer == 0 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }.map(\.windowID))
        let sourceRect = ScrollingCaptureRegion.matching(selection: selectionRect, display: filter.contentRect,
            frontToBackWindows: ScrollingCaptureRegion.frontToBackWindows(on: display.displayID, targets: targets)).rect
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let output = ScrollingCaptureRegion.output(selection: selectionRect, matching: sourceRect, scale: scale)

        stitchedHeight = output.rows.count
        isWaiting = false
        hasReachedLimit = false
        keepsChanging = false
        RecordingAreaHighlightPresenter.shared.show(display: display, rect: rect)
        panel = ScrollingCaptureBar.makePanel(below: rect, on: screen)
        panel?.orderFrontRegardless()
        defer {
            panel?.orderOut(nil)
            panel = nil
            RecordingAreaHighlightPresenter.shared.hide()
        }

        let source = ScrollingCaptureStream()
        stream = source
        cutoff = nil
        defer { source.stop(); stream = nil }
        var events = source.events.makeAsyncIterator()
        // Its monitors start before the stream; leaving by any path, a failed
        // start or Cancel included, removes them.
        autoScroller = ScrollingCaptureAutoScroller(region: rect, scale: scale, state: { [unowned self] in
            .init(height: stitchedHeight, lastFrameTime: lastFrameTime,
                  canContinue: outcome == nil && !hasReachedLimit && !isWaiting)
        }, bar: { [weak self] in self?.panel?.frame }, onStop: { [weak self] in self?.isAutoScrolling = false },
           onEndOfPage: { [weak self] in self?.finish() })
        defer { endAutoScroll() }
        let feed: ScrollingCaptureFeed
        do {
            try await source.start(filter: filter, configuration: ScrollingCaptureStream.configuration(
                sourceRect: sourceRect, scale: scale))
            // Cancel, or Done before capturing starts, ends the stream here.
            var first: ScrollingCaptureStream.Frame?
            while first == nil, let event = await events.next() {
                if case .frame(let frame) = event { first = frame }
            }
            guard let firstFrame = first, outcome == nil,
                  let firstFeed = ScrollingCaptureFeed(firstFrame: firstFrame.image, at: firstFrame.time, selection: output,
                      ignoredTrailingColumns: Int((Self.scrollBarWidth * scale).rounded())) else { return nil }
            feed = firstFeed
        } catch {
            FailureAlert.present(message: "Scrolling capture couldn't start", error: error)
            return nil
        }

        isCapturing = true
        defer { isCapturing = false }
        canAutoScroll = true
        // Frames arrive until Done, Cancel, the height limit or a stream error
        // stops the stream. Idle ticks say nothing moved, so there's nothing to place.
        events: while let event = await events.next() {
            guard outcome != .cancelled, !hasReachedLimit else { break }
            guard case .frame(let frame) = event else { continue }
            guard frame.time <= cutoff ?? .infinity else { break events }
            let update = await feed.add(frame.image, at: frame.time)
            lastFrameTime = frame.time
            stitchedHeight = update.height
            isWaiting = update.placement == .skipped
            keepsChanging = update.keepsChanging
            hasReachedLimit = stitchedHeight >= Self.maximumHeight
            if hasReachedLimit { source.stop() }
        }
        // The stream has ended (Done, Cancel, the height limit or an error):
        // nothing more can be captured, so nothing more may be scrolled.
        endAutoScroll()

        // ponytail: after a stream error the bar doesn't say capture stopped;
        // it waits for Done, which keeps what's captured, or Cancel.
        while outcome == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard outcome != .cancelled, let image = await feed.makeImage() else { return nil }
        let capped = image.height > Self.maximumHeight
            ? image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: Self.maximumHeight)) : image
        return capped.map { Capture(image: $0, displayID: display.displayID, scale: scale) }
    }

    /// Ends the session, keeping what was captured. Until frames are being
    /// captured - the region still being drawn, or not yet on screen - there
    /// is nothing to keep, so it cancels instead.
    func finish() {
        autoScroller?.stop()
        if isCapturing {
            cutoff = cutoff ?? ScrollingCaptureSampleTiming.now()
            outcome = outcome ?? .done
            stream?.stop()
        } else {
            cancel()
        }
    }

    func cancel() {
        autoScroller?.stop()
        cutoff = cutoff ?? ScrollingCaptureSampleTiming.now()
        outcome = .cancelled
        stream?.stop()
        if isSelectingArea {
            RecordingAreaSelectionPresenter.shared.cancel()
        }
    }

    // MARK: - Auto-scroll

    /// The bar's auto-scroll button: starts scrolling, or pauses it.
    func toggleAutoScroll() {
        guard let autoScroller else { return }
        if isAutoScrolling { return autoScroller.stop() }
        guard AXIsProcessTrusted() else {
            if didRequestScrollPermission, let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            } else {
                didRequestScrollPermission = true
                // kAXTrustedCheckOptionPrompt's value, spelled out: the imported
                // constant is a mutable global.
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            needsScrollPermission = true
            return
        }
        needsScrollPermission = false
        autoScroller.start()
        isAutoScrolling = autoScroller.isRunning
    }

    private func endAutoScroll() {
        autoScroller?.invalidate()
        autoScroller = nil
        canAutoScroll = false
    }

    private func selectArea(on display: SCDisplay) async -> CGRect? {
        isSelectingArea = true
        defer { isSelectingArea = false }
        return await withCheckedContinuation { continuation in
            RecordingAreaSelectionPresenter.shared.selectArea(on: display) { rect in
                continuation.resume(returning: rect)
            }
        }
    }
}
