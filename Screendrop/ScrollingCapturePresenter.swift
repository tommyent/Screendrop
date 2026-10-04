//
//  ScrollingCapturePresenter.swift
//  Screendrop
//

import AppKit
import ScreenCaptureKit
import SwiftUI

/// Runs a scrolling capture: the user draws a region and Screendrop scrolls
/// it to the end by itself, then finishes - or, without the permission to
/// post scroll events, the user scrolls by hand and clicks Done. Frames are
/// sampled throughout and handed to `ScrollingCaptureStitcher`, which keeps
/// the rows that scrolled into view, so scrolling by hand mid-run is safe.
///
/// The region stays highlighted for the whole session, with a small bar below
/// it showing the stitched height and Done/Cancel. The app being scrolled
/// keeps the keyboard: any key stops auto-scroll and keeps the capture, as in
/// Shottr, and after that Esc or Return, the shortcut again, or the bar's
/// buttons end a session.
@Observable
final class ScrollingCapturePresenter {
    static let shared = ScrollingCapturePresenter()

    struct Capture {
        let image: CGImage
        let displayID: CGDirectDisplayID
        /// Pixels per point of the captured display.
        let scale: CGFloat
    }

    /// ponytail: stops growing at 16,384 px, the GPU texture limit on Apple
    /// silicon, because the editor isn't verified with taller images. Raise
    /// once it is.
    private static let maximumHeight = 16_384
    /// Scrolling further than the region's height between two samples leaves
    /// no overlap to line frames up with, so sample often.
    private static let sampleInterval: Duration = .milliseconds(50)
    /// Right-edge strip left out of matching, where the overlay scroll bar
    /// appears while scrolling.
    private static let scrollBarWidth: CGFloat = 20
    /// An auto-scroll step as a share of the region's height: well under one
    /// region, so consecutive frames always overlap.
    private static let autoScrollFraction: CGFloat = 0.4
    /// How long a page gets to start moving after a step before auto-scroll
    /// stops. Measured in time, not frames: a page may delay or animate its
    /// response to a scroll.
    private static let stepResponseAllowance: Duration = .seconds(2)
    /// How long the content must hold still after moving part of a step
    /// before that step counts as done. One unchanged frame isn't enough: an
    /// animation can sit between ticks for a sample.
    private static let stepSettleTime: Duration = .milliseconds(300)

    private(set) var isRunning = false
    private(set) var stitchedHeight = 0
    /// The latest frame couldn't be lined up, usually from scrolling too far
    /// between samples. Scrolling back to where it left off recovers.
    private(set) var hasLostTrack = false
    /// The capture is as tall as it can get; only Done or Cancel are left.
    private(set) var hasReachedLimit = false
    /// Screendrop is scrolling the region itself, a step at a time.
    private(set) var isAutoScrolling = false
    /// Auto-scroll is off for want of the permission to post scroll events;
    /// the user scrolls by hand.
    private(set) var needsScrollPermission = false

    @ObservationIgnored private var outcome: Outcome?
    /// Where auto-scroll points its scroll events (Quartz, top-left origin)
    /// and how far each step goes, in points and in captured pixels.
    @ObservationIgnored private var autoScrollTarget: (point: CGPoint, step: Int32, stepPixels: Int)?
    @ObservationIgnored private var pendingStep: PendingStep?
    /// Where the pointer was before auto-scroll took it, to put it back.
    @ObservationIgnored private var pointerBeforeAutoScroll: CGPoint?
    @ObservationIgnored private var keyTap: CFMachPort?
    /// Keys in the scrolled app are being watched, so any key can stop
    /// auto-scroll.
    var canStopWithAnyKey: Bool { keyTap != nil }
    @ObservationIgnored private var keyTapSource: CFRunLoopSource?
    /// macOS shows its permission prompt at most once; asking on every
    /// capture would only add an entry nobody sees.
    @ObservationIgnored private var didRequestScrollPermission = false
    @ObservationIgnored private var isSelectingArea = false
    @ObservationIgnored private var panel: NSPanel?

    private enum Outcome {
        case done
        case cancelled
    }

    /// The one step in flight: when it was posted, the stitched height then,
    /// and when it last carried the content further.
    private struct PendingStep {
        let postedAt: ContinuousClock.Instant
        let startHeight: Int
        var lastHeight: Int
        var lastMovedAt: ContinuousClock.Instant
    }

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
              let rect = await selectArea(on: display),
              outcome != .cancelled else {
            return nil
        }

        // Screendrop's own windows are always left out, whatever the
        // app-windows preference says: the capture bar and highlight sit on
        // screen the whole time and must never end up in a frame.
        let filter = ScreenRecordingCapture.displayFilter(
            display: display,
            content: content,
            includesAppWindows: false
        )
        let screen = ActiveDisplayResolver.screen(for: display.displayID)
        // Whole points, so every frame maps 1:1 onto screen pixels with no
        // resampling. Stitching relies on rows matching exactly.
        let sourceRect = ScreenRecordingManager.sourceRect(
            forAppKitSelectionRect: rect,
            screenFrame: screen?.frame,
            contentRect: filter.contentRect
        ).integral.intersection(filter.contentRect)
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int((sourceRect.width * scale).rounded()))
        configuration.height = max(1, Int((sourceRect.height * scale).rounded()))
        configuration.showsCursor = false

        stitchedHeight = configuration.height
        hasLostTrack = false
        hasReachedLimit = false
        // The region's center in Quartz space, which flips AppKit's y about
        // the main display's height.
        let step = max(1, (rect.height * Self.autoScrollFraction).rounded())
        autoScrollTarget = (
            CGPoint(x: rect.midX, y: CGDisplayBounds(CGMainDisplayID()).height - rect.midY),
            Int32(step),
            Int(step * scale)
        )
        RecordingAreaHighlightPresenter.shared.show(display: display, rect: rect)
        showPanel(below: rect, on: screen)
        installKeyTap()
        defer {
            stopAutoScroll()
            autoScrollTarget = nil
            removeKeyTap()
            hidePanel()
            RecordingAreaHighlightPresenter.shared.hide()
        }

        let stitcher: ScrollingCaptureStitcher
        do {
            let firstFrame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let firstStitcher = ScrollingCaptureStitcher(
                firstFrame: firstFrame,
                ignoredTrailingColumns: Int((Self.scrollBarWidth * scale).rounded())
            ) else { return nil }
            stitcher = firstStitcher
        } catch {
            FailureAlert.present(message: "Scrolling capture couldn't start", error: error)
            return nil
        }
        startAutoScroll()

        // ponytail: a sample that fails is skipped silently; a display that
        // keeps failing leaves the height still until the user ends the session.
        while outcome == nil {
            try? await Task.sleep(for: Self.sampleInterval)
            guard outcome == nil, !hasReachedLimit,
                  let frame = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
                continue
            }
            let update = await stitcher.add(frame)
            switch update {
            case .appended, .unchanged: hasLostTrack = false
            case .noMatch: hasLostTrack = true
            }
            let height = await stitcher.stitchedHeight
            // The image is cropped to the cap on Done, so never show more.
            stitchedHeight = min(height, Self.maximumHeight)
            hasReachedLimit = stitchedHeight >= Self.maximumHeight
            // Done or Cancel may have landed while this sample was in flight.
            if isAutoScrolling, outcome == nil {
                continueAutoScroll(after: update, stitchedHeight: height)
            }
        }

        guard outcome != .cancelled, let image = await stitcher.makeImage() else { return nil }
        let capped = image.height > Self.maximumHeight
            ? image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: Self.maximumHeight))
            : image
        return capped.map { Capture(image: $0, displayID: display.displayID, scale: scale) }
    }

    /// Ends the session, keeping what was captured. While the region is
    /// still being drawn there is nothing to keep, so it cancels instead.
    func finish() {
        if isSelectingArea {
            cancel()
        } else {
            stopAutoScroll()
            outcome = outcome ?? .done
        }
    }

    func cancel() {
        stopAutoScroll()
        outcome = .cancelled
        if isSelectingArea {
            RecordingAreaSelectionPresenter.shared.cancel()
        }
    }

    // MARK: - Auto-scroll

    /// Starts scrolling as soon as the region is drawn, as Shottr does.
    /// Posting scroll events needs the Accessibility permission; without it
    /// the session stays manual and the bar offers the way to allow it.
    private func startAutoScroll() {
        // Done or Cancel may have landed while the first frame was captured.
        guard outcome == nil, let autoScrollTarget else { return }
        if !CGPreflightPostEventAccess() {
            if !didRequestScrollPermission {
                didRequestScrollPermission = true
                _ = CGRequestPostEventAccess()
            }
            needsScrollPermission = !CGPreflightPostEventAccess()
            guard !needsScrollPermission else { return }
        }
        needsScrollPermission = false
        // Scroll events go to the window under the pointer.
        pointerBeforeAutoScroll = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(autoScrollTarget.point)
        isAutoScrolling = true
        postAutoScrollStep(from: stitchedHeight)
    }

    /// Stops scrolling and puts the pointer back where the user left it.
    private func stopAutoScroll() {
        guard isAutoScrolling else { return }
        isAutoScrolling = false
        pendingStep = nil
        if let pointerBeforeAutoScroll {
            CGWarpMouseCursorPosition(pointerBeforeAutoScroll)
            self.pointerBeforeAutoScroll = nil
        }
    }

    func openScrollPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// One step in flight at a time. The next is posted once the content has
    /// moved the full step, or has held still for a moment after moving part
    /// of one (the end of the page, or an app that scrolls less than asked).
    /// A page that animates its scrolling produces partly moved frames along
    /// the way; treating those as done would pile steps up and could outrun
    /// the overlap.
    ///
    /// When a step brings no movement at all within the allowance, or the
    /// height limit is reached, the capture is complete and finishes by
    /// itself. A frame that can't be lined up only stops the scrolling -
    /// scrolling on would skip content - and leaves the user to scroll back.
    private func continueAutoScroll(after update: ScrollingCaptureStitcher.Update, stitchedHeight height: Int) {
        guard update != .noMatch, let autoScrollTarget, let pendingStep else {
            stopAutoScroll()
            return
        }
        guard !hasReachedLimit else {
            finish()
            return
        }
        let now = ContinuousClock.now
        if height > pendingStep.lastHeight {
            self.pendingStep?.lastHeight = height
            self.pendingStep?.lastMovedAt = now
        }
        let moved = height - pendingStep.startHeight
        let isSettled = moved > 0 && now - (self.pendingStep?.lastMovedAt ?? now) >= Self.stepSettleTime
        if moved >= autoScrollTarget.stepPixels {
            postAutoScrollStep(from: height)
        } else if isSettled {
            // Most of a step and then still is an app scrolling a little less
            // than asked (whole lines, say): carry on. A small remainder and
            // then still is the page running out: finish, rather than post a
            // probe that only waits out the allowance while the last step's
            // animation may still be running.
            // ponytail: an app that scrolls under half of every step would
            // stop after one; give such apps the allowance if one turns up.
            if moved * 2 >= autoScrollTarget.stepPixels {
                postAutoScrollStep(from: height)
            } else {
                finish()
            }
        } else if moved == 0, now - pendingStep.postedAt > Self.stepResponseAllowance {
            finish()
        }
    }

    /// Watches keys in whatever app is being scrolled. While auto-scroll
    /// runs, any key stops it and keeps the capture, as in Shottr, and is
    /// swallowed so it doesn't also type into that app. Once auto-scroll has
    /// stopped - lost track, or no permission - only Esc and Return end the
    /// session and every key passes through, so the keyboard can still scroll.
    /// Seeing other apps' keys needs the Accessibility permission; without it
    /// no tap is made, and the bar and the shortcut still end the session.
    private func installKeyTap() {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, _ in
                // The tap is on the main run loop, so this runs on the main thread.
                MainActor.assumeIsolated {
                    ScrollingCapturePresenter.shared.handleKeyTap(type: type, event: event)
                }
            },
            userInfo: nil
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keyTap = tap
        keyTapSource = source
    }

    private func handleKeyTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches off a tap it thinks is too slow; switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let keyTap {
                CGEvent.tapEnable(tap: keyTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        if isAutoScrolling {
            finish()
            return nil
        }
        if [53, 36, 76].contains(event.getIntegerValueField(.keyboardEventKeycode)) {
            finish()
        }
        return Unmanaged.passUnretained(event)
    }

    private func removeKeyTap() {
        if let keyTap {
            CGEvent.tapEnable(tap: keyTap, enable: false)
        }
        if let keyTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), keyTapSource, .commonModes)
        }
        keyTap = nil
        keyTapSource = nil
    }

    private func postAutoScrollStep(from height: Int) {
        guard let autoScrollTarget else { return }
        let now = ContinuousClock.now
        pendingStep = PendingStep(postedAt: now, startHeight: height, lastHeight: height, lastMovedAt: now)
        // Pixel units scroll the same distance in every app. A negative delta
        // moves the content up, as scrolling down a page does. While it runs
        // the pointer stays at the region's center, where these events land.
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: -autoScrollTarget.step,
            wheel2: 0,
            wheel3: 0
        )
        event?.location = autoScrollTarget.point
        event?.post(tap: .cghidEventTap)
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
        let panel = ScrollingCapturePanel(
            contentRect: CGRect(origin: Self.panelOrigin(size: size, below: rect, on: screen), size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: ScrollingCaptureBar())
        hostingView.sizingOptions = []
        hostingView.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hostingView
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Centered under the region, else above it, else inside its bottom edge.
    private static func panelOrigin(size: CGSize, below rect: CGRect, on screen: NSScreen?) -> CGPoint {
        let visible = screen?.visibleFrame ?? rect
        let x = min(max(rect.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let below = rect.minY - size.height
        let above = rect.maxY
        let y = if below >= visible.minY {
            below
        } else if above + size.height <= visible.maxY {
            above
        } else {
            rect.minY
        }
        return CGPoint(x: x, y: y)
    }
}

private final class ScrollingCapturePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    /// Esc on the bar matches Esc in the scrolled app: stop and keep.
    override func cancelOperation(_ sender: Any?) {
        ScrollingCapturePresenter.shared.finish()
    }
}

private struct ScrollingCaptureBar: View {
    static let barSize = CGSize(width: 380, height: 52)
    /// Room around the bar for the glass shadow.
    static let margin: CGFloat = 12
    static let panelSize = CGSize(width: barSize.width + margin * 2, height: barSize.height + margin * 2)

    @State private var presenter = ScrollingCapturePresenter.shared

    /// The finish shortcut, when it registered, so the keyboard exit is
    /// discoverable while another app has the keyboard.
    private let finishShortcut: String? = HotkeyManager.shared.registrationErrors[.scrollingCapture] == nil
        ? CaptureHotkeyPreferences.shortcut(for: .scrollingCapture).displayString
        : nil

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(presenter.hasLostTrack ? .orange : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if presenter.needsScrollPermission && !presenter.hasLostTrack {
                    Button("Allow auto-scroll…") {
                        presenter.openScrollPermissionSettings()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Auto-scroll needs Screendrop allowed in Privacy & Security")
                } else {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 8)
            Button("Cancel") {
                presenter.cancel()
            }
            Button("Done") {
                presenter.finish()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(width: Self.barSize.width, height: Self.barSize.height)
        // An almost opaque backing keeps the status legible over any page;
        // glass alone, even tinted, let dark page text show through.
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
        .glassEffect(.regular, in: .capsule)
        .padding(Self.margin)
    }

    private var title: String {
        if presenter.hasReachedLimit {
            "Maximum height reached"
        } else if presenter.hasLostTrack {
            "Scroll back to resume"
        } else if presenter.isAutoScrolling {
            "Scrolling…"
        } else {
            "Scroll to capture"
        }
    }

    private var detail: String {
        if presenter.hasLostTrack && !presenter.hasReachedLimit {
            return "Couldn't line this view up"
        }
        let height = "\(presenter.stitchedHeight.formatted()) px tall"
        if presenter.isAutoScrolling && presenter.canStopWithAnyKey {
            return "\(height) · Any key to finish"
        }
        guard let finishShortcut else { return height }
        return "\(height) · \(finishShortcut) to finish"
    }
}
