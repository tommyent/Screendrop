//
//  ScrollingCaptureAutoScroll.swift
//  Screendrop
//

import AppKit

/// Scrolls the region of a Scrolling Capture a step at a time, paced by
/// `AutoScrollPacer` from what was actually stitched.
///
/// Steps are posted as pixel scroll events at the region's center, tagged so
/// the monitors here can tell them from the user's own scrolling. The
/// pointer is never moved. Scrolling by hand or moving the pointer off the
/// bar hands the session back, and so do a frame that doesn't fit, the height
/// limit and the end of the page; only Done finishes. No key is watched.
/// Watching scrolling needs no permission; only posting does.
final class ScrollingCaptureAutoScroller {
    struct State {
        /// The stitched height, in captured pixels.
        let height: Int
        /// The display time of the newest frame taken, on the stream's clock.
        let lastFrameTime: TimeInterval
        /// False while the latest frame doesn't fit, once the height limit is
        /// reached and when the session has ended.
        let canContinue: Bool
    }

    /// A step is a quarter of the region's height, 40-240 pt. For regions
    /// 160 pt and taller that's at most a quarter, so the pacer's two steps
    /// without progress stay within half a region; smaller regions step 40 pt,
    /// a bigger share, so fewer steps fit before frames stop overlapping. The
    /// floor keeps a small region from crawling.
    private static let stepFraction: CGFloat = 0.25
    private static let stepRange: ClosedRange<CGFloat> = 40...240
    /// Marks auto-scroll's own scroll events.
    private static let eventTag: Int64 = 0x5344_4153
    /// Pointer travel, in points, that counts as the user taking over. Below
    /// it is the hand still resting after the click that started auto-scroll.
    private static let pointerMoveTolerance: CGFloat = 10
    private static let pollInterval: Duration = .milliseconds(30)

    private let point: CGPoint
    private let stepPoints: Int32
    private let stepPixels: Int
    private let state: () -> State
    private let bar: () -> CGRect?
    private let onStop: () -> Void
    private var pacer: AutoScrollPacer?
    private var monitors: [Any] = []
    private var poller: Task<Void, Never>?
    private var pointerAtStart: CGPoint = .zero
    private(set) var isRunning = false

    /// `region` is the selection in AppKit screen coordinates.
    init(region: CGRect, scale: CGFloat, state: @escaping () -> State,
         bar: @escaping () -> CGRect?, onStop: @escaping () -> Void) {
        // Quartz flips AppKit's y about the main display's height.
        point = CGPoint(x: region.midX, y: CGDisplayBounds(CGMainDisplayID()).height - region.midY)
        let step = min(max((region.height * Self.stepFraction).rounded(), Self.stepRange.lowerBound), Self.stepRange.upperBound)
        stepPoints = Int32(step)
        stepPixels = Int((step * scale).rounded())
        self.state = state
        self.bar = bar
        self.onStop = onStop
        installMonitors()
    }

    /// Posting scroll events to another app needs the Accessibility
    /// permission; the caller checks it first.
    func start() {
        guard !isRunning, state().canContinue else { return }
        isRunning = true
        pointerAtStart = NSEvent.mouseLocation
        pacer = AutoScrollPacer(stepPixels: stepPixels, height: state().height, now: ScrollingCaptureSampleTiming.now())
        post()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                self?.tick()
            }
        }
    }

    /// Hands the session back to the user. Nothing to put back: the pointer
    /// was never moved.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        poller?.cancel()
        poller = nil
        pacer = nil
        onStop()
    }

    /// Ends the session: stops scrolling and removes the monitors.
    func invalidate() {
        stop()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
    }

    private func tick() {
        guard isRunning, var pacer else { return }
        let current = state()
        guard current.canContinue else { return stop() }
        let action = pacer.update(height: current.height, lastFrameTime: current.lastFrameTime,
                                  now: ScrollingCaptureSampleTiming.now())
        self.pacer = pacer
        switch action {
        case .step: post()
        case .endOfPage: stop()
        case .wait: break
        }
    }

    private func post() {
        // Pixel units scroll the same distance in every app. A negative
        // delta moves the content up, as scrolling down a page does.
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                            wheel1: -stepPoints, wheel2: 0, wheel3: 0)
        event?.location = point
        event?.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event?.post(tap: .cghidEventTap)
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(monitor)
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .scrollWheel {
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.eventTag { stop() }
            return
        }
        guard isRunning else { return }
        // The pointer starts on the bar, where auto-scroll was turned on, and
        // goes back there to pause it or click Done; only leaving it counts.
        let location = NSEvent.mouseLocation
        guard bar()?.contains(location) != true else { return }
        if hypot(location.x - pointerAtStart.x, location.y - pointerAtStart.y) > Self.pointerMoveTolerance {
            stop()
        }
    }
}
