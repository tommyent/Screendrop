//
//  ScrollingCapturePresenter.swift
//  Screendrop
//

import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import SwiftUI

/// Runs a scrolling capture: the user draws a region, scrolls the content
/// under it, and clicks Done. Frames are sampled while they scroll and handed
/// to `ScrollingCaptureFeed`: Vision proposes each frame's offset, exact
/// pixels confirm it, and a frame that doesn't fit is skipped until one does.
///
/// The region stays highlighted for the whole session, with a small bar below
/// it: capturing (the stitched height), waiting ("Scroll back a little", the
/// latest frame didn't fit) or at the height limit, and Done/Cancel. The app
/// being scrolled keeps the keyboard throughout, so the bar's buttons - or
/// pressing the shortcut again - are how a session ends. The bar's auto-scroll
/// button scrolls the region a step at a time instead (`ScrollingCaptureAutoScroller`).
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

    /// ponytail: stops growing at 16,384 px, the GPU texture limit on Apple
    /// silicon, because the editor isn't verified with taller images. Raise
    /// once it is.
    private static let maximumHeight = 16_384
    /// Scrolling further than the region's height between two samples leaves
    /// no overlap to line frames up with, so sample often.
    private static let frameInterval = CMTime(value: 1, timescale: 20)
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
    /// At rest, a video plays over most of the region: frames can't be placed
    /// past it, so the bar asks for it to be paused.
    private(set) var isVideoPlaying = false
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
        let allowed = Set(content.windows.filter {
            $0.windowLayer == 0 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }.map(\.windowID))
        let displayBounds = CGDisplayBounds(display.displayID)
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []).compactMap { info -> (frame: CGRect, isTarget: Bool)? in
                guard let id = info[kCGWindowNumber as String] as? UInt32,
                      info[kCGWindowOwnerPID as String] as? Int32 != ProcessInfo.processInfo.processIdentifier,
                      (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                      let bounds = info[kCGWindowBounds as String] as? [String: Any],
                      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
                return (frame.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY), allowed.contains(id))
            }
        let sourceRect = ScrollingCaptureRegion.matching(selection: selectionRect, display: filter.contentRect,
            frontToBackWindows: windows).rect
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let output = ScrollingCaptureRegion.output(selection: selectionRect, matching: sourceRect, scale: scale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int((sourceRect.width * scale).rounded()))
        configuration.height = max(1, Int((sourceRect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = Self.frameInterval
        configuration.queueDepth = 3

        stitchedHeight = output.rows.count
        isWaiting = false
        hasReachedLimit = false
        isVideoPlaying = false
        RecordingAreaHighlightPresenter.shared.show(display: display, rect: rect)
        showPanel(below: rect, on: screen)
        defer {
            panel?.orderOut(nil)
            panel = nil
            RecordingAreaHighlightPresenter.shared.hide()
        }

        let source = ScrollingCaptureStream()
        stream = source
        cutoff = nil
        defer {
            source.stop()
            stream = nil
        }
        var events = source.events.makeAsyncIterator()
        // Its monitors start before the stream; leaving by any path, a failed
        // start or Cancel included, removes them.
        autoScroller = ScrollingCaptureAutoScroller(region: rect, scale: scale, state: { [unowned self] in
            .init(height: stitchedHeight, lastFrameTime: lastFrameTime,
                  canContinue: outcome == nil && !hasReachedLimit && !isWaiting)
        }, bar: { [weak self] in self?.panel?.frame }, onStop: { [weak self] in self?.isAutoScrolling = false })
        defer { endAutoScroll() }
        let feed: ScrollingCaptureFeed
        do {
            try await source.start(filter: filter, configuration: configuration)
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
            isVideoPlaying = update.isVideoPlaying
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
            if didRequestScrollPermission {
                openScrollPermissionSettings()
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

    func openScrollPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
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

    // MARK: - Bar

    private func showPanel(below rect: CGRect, on screen: NSScreen?) {
        let size = ScrollingCaptureBar.panelSize
        let panel = ScrollingCapturePanel(contentRect: CGRect(origin: Self.panelOrigin(size: size, below: rect, on: screen),
            size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        PreviewWindowCaptureExclusion.shared.register(window: panel)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hostingView = NSHostingView(rootView: ScrollingCaptureBar())
        // Sized like the recording bar's panel: the panel sets the size and
        // the hosting view follows it, so the two never negotiate sizes
        // through constraints. That negotiation is what AppKit's constraint
        // watchdog once killed the app over in the recording bar.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hostingView
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Centered under the region, else above it, else inside its bottom edge.
    private static func panelOrigin(size: CGSize, below rect: CGRect, on screen: NSScreen?) -> CGPoint {
        let visible = screen?.visibleFrame ?? rect
        let x = min(max(rect.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let below = rect.minY - size.height
        let above = rect.maxY
        let y = if below >= visible.minY { below } else if above + size.height <= visible.maxY { above } else { rect.minY }
        return CGPoint(x: x, y: y)
    }
}

private final class ScrollingCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ScrollingCaptureBar: View {
    /// Wide enough for the auto-scroll button beside the longest titles.
    static let barSize = CGSize(width: 430, height: 52)
    /// Room around the bar for the glass shadow.
    static let margin: CGFloat = 12
    static let panelSize = CGSize(width: barSize.width + margin * 2, height: barSize.height + margin * 2)

    @State private var presenter = ScrollingCapturePresenter.shared

    /// The finish shortcut, when it registered, so the keyboard exit is
    /// discoverable while another app has the keyboard.
    private let finishShortcut: String? = HotkeyManager.shared.registrationErrors[.scrollingCapture] == nil
        ? CaptureHotkeyPreferences.shortcut(for: .scrollingCapture)?.displayString
        : nil

    var body: some View {
        // Drawn with the bar's own button style and AppKit colors, like the
        // recording bar: the panel isn't key while the scrolled app has the
        // keyboard, and the system button styles then draw for an inactive
        // window, so Done lost its accent color and looked like Cancel.
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(presenter.isWaiting || presenter.isVideoPlaying
                        ? Color(nsColor: .systemOrange) : BarMetrics.activeTint)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
            Button {
                presenter.toggleAutoScroll()
            } label: {
                Image(systemName: presenter.isAutoScrolling ? "pause.circle" : "arrow.down.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(BarMetrics.activeTint.opacity(canToggleAutoScroll ? 1 : 0.3))
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(BarButtonStyle())
            .disabled(!canToggleAutoScroll)
            .help(autoScrollHelp)
            .accessibilityLabel(presenter.isAutoScrolling ? "Pause auto-scroll" : "Auto-scroll")
            Button {
                presenter.cancel()
            } label: {
                Text("Cancel")
                    .foregroundStyle(BarMetrics.activeTint)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Color(nsColor: .labelColor).opacity(0.1), in: .capsule)
            }
            .buttonStyle(BarButtonStyle())
            Button {
                presenter.finish()
            } label: {
                Text("Done")
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Color(nsColor: .controlAccentColor), in: .capsule)
            }
            .buttonStyle(BarButtonStyle())
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(width: Self.barSize.width, height: Self.barSize.height)
        .glassEffect(.regular, in: .capsule)
        .padding(Self.margin)
    }

    /// Waiting or the height limit stops auto-scroll, and it can't start again
    /// until the user has dealt with either; pausing always works.
    private var canToggleAutoScroll: Bool {
        presenter.isAutoScrolling || presenter.canAutoScroll && !presenter.isWaiting && !presenter.hasReachedLimit
    }

    private var autoScrollHelp: String {
        if presenter.isAutoScrolling { return "Pause auto-scroll" }
        if presenter.needsScrollPermission { return "Auto-scroll needs Accessibility. Click to open Privacy & Security." }
        return "Auto-scroll"
    }

    private var title: String {
        presenter.hasReachedLimit ? "Maximum height reached"
            : presenter.isVideoPlaying ? "A video is playing."
            : presenter.isWaiting ? "Scroll back a little" : "Scroll to capture"
    }

    private var detail: String {
        guard !presenter.hasReachedLimit else { return "\(presenter.stitchedHeight.formatted()) px tall" }
        if presenter.isVideoPlaying { return "Pause it to capture." }
        if presenter.isWaiting { return "This view doesn’t line up yet" }
        let height = "\(presenter.stitchedHeight.formatted()) px tall"
        guard let finishShortcut else { return height }
        return "\(height) · \(finishShortcut) to finish"
    }
}
