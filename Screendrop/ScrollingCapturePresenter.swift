//
//  ScrollingCapturePresenter.swift
//  Screendrop
//

import AppKit
import ScreenCaptureKit
import SwiftUI

/// Runs a scrolling capture: the user draws a region, scrolls the content
/// under it, and clicks Done. Frames are sampled while they scroll and handed
/// to `ScrollingCaptureStitcher`, which keeps the rows that scrolled into view.
///
/// The region stays highlighted for the whole session, with a small bar below
/// it showing the stitched height and Done/Cancel. The app being scrolled
/// keeps the keyboard throughout, so the bar's buttons - or pressing the
/// shortcut again - are how a session ends.
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

    private(set) var isRunning = false
    private(set) var stitchedHeight = 0
    /// The latest frame couldn't be lined up, usually from scrolling too far
    /// between samples. Scrolling back to where it left off recovers.
    private(set) var hasLostTrack = false
    /// The capture is as tall as it can get; only Done or Cancel are left.
    private(set) var hasReachedLimit = false
    /// The end of the stitch so far, downscaled: what a capture that lost
    /// track has to scroll back to, shown in the recovery strip.
    private(set) var recoveryTarget: CGImage?
    /// Frames line up again after track was lost; the strip says so briefly.
    private(set) var hasRecovered = false

    @ObservationIgnored private var outcome: Outcome?
    @ObservationIgnored private var isSelectingArea = false
    @ObservationIgnored private var isCapturing = false
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var recoveryPanel: NSPanel?
    @ObservationIgnored private var recoveryHideTask: Task<Void, Never>?
    /// The stitched height `recoveryTarget` was taken at. The last accepted
    /// frame only changes on an append, so the same height means the same
    /// rows and no refetch.
    @ObservationIgnored private var recoveryTargetHeight = 0
    @ObservationIgnored private var region: CGRect = .zero

    /// How long the strip shows that frames line up again before it goes.
    private static let recoveredDisplayTime: Duration = .milliseconds(1500)

    private enum Outcome {
        case done
        case cancelled
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
              outcome == nil,
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
        recoveryTarget = nil
        recoveryTargetHeight = 0
        // Rows of the last frame that fill the strip's image at full width.
        let recoveryRows = Int((CGFloat(configuration.width) * ScrollingCaptureRecoveryStrip.imageSize.height
            / ScrollingCaptureRecoveryStrip.imageSize.width).rounded())
        let recoveryPixelWidth = Int((ScrollingCaptureRecoveryStrip.imageSize.width * scale).rounded())
        RecordingAreaHighlightPresenter.shared.show(display: display, rect: rect)
        showPanel(below: rect, on: screen)
        defer {
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

        isCapturing = true
        defer { isCapturing = false }
        // ponytail: a sample that fails is skipped silently; a display that
        // keeps failing leaves the height still until the user ends the session.
        while outcome == nil {
            try? await Task.sleep(for: Self.sampleInterval)
            guard outcome == nil, !hasReachedLimit,
                  let frame = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
                continue
            }
            let wasLost = hasLostTrack
            switch await stitcher.add(frame) {
            case .appended, .unchanged: hasLostTrack = false
            case .noMatch: hasLostTrack = true
            }
            let height = await stitcher.stitchedHeight
            // The image is cropped to the cap on Done, so never show more.
            stitchedHeight = min(height, Self.maximumHeight)
            hasReachedLimit = stitchedHeight >= Self.maximumHeight
            if hasLostTrack, !wasLost, outcome == nil {
                if recoveryTarget == nil || recoveryTargetHeight != height,
                   let rows = await stitcher.lastAcceptedRows(recoveryRows) {
                    recoveryTarget = Self.downscaled(rows, toWidth: recoveryPixelWidth)
                    recoveryTargetHeight = height
                }
                showRecoveryStrip()
            } else if wasLost, !hasLostTrack {
                showRecovered()
            }
        }

        guard outcome != .cancelled, let image = await stitcher.makeImage() else { return nil }
        let capped = image.height > Self.maximumHeight
            ? image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: Self.maximumHeight))
            : image
        return capped.map { Capture(image: $0, displayID: display.displayID, scale: scale) }
    }

    /// Ends the session, keeping what was captured. Until frames are being
    /// captured - the region still being drawn, or not yet on screen - there
    /// is nothing to keep, so it cancels instead.
    func finish() {
        if isCapturing {
            outcome = outcome ?? .done
        } else {
            cancel()
        }
    }

    func cancel() {
        outcome = .cancelled
        if isSelectingArea {
            RecordingAreaSelectionPresenter.shared.cancel()
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
        let panel = Self.makePanel(ScrollingCaptureBar(), size: size, origin: Self.panelOrigin(size: size, below: rect, on: screen))
        panel.orderFrontRegardless()
        self.panel = panel
        region = rect
    }

    private func hidePanel() {
        hideRecoveryStrip()
        recoveryPanel = nil
        recoveryTarget = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private static func makePanel(_ content: some View, size: CGSize, origin: CGPoint) -> NSPanel {
        let panel = ScrollingCapturePanel(
            contentRect: CGRect(origin: origin, size: size),
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

        let hostingView = NSHostingView(rootView: content)
        // Sized like the recording bar's panel: the panel sets the size and
        // the hosting view follows it, so the two never negotiate sizes
        // through constraints. That negotiation is what AppKit's constraint
        // watchdog once killed the app over in the recording bar.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hostingView
        return panel
    }

    // MARK: - Recovery strip

    /// A panel of its own, shown only while track is lost and briefly after,
    /// so the bar's fixed-size panel never changes and nothing sits on screen
    /// during a normal capture.
    private func showRecoveryStrip() {
        guard let panel else { return }
        recoveryHideTask?.cancel()
        hasRecovered = false
        let size = ScrollingCaptureRecoveryStrip.panelSize
        let strip = recoveryPanel ?? Self.makePanel(ScrollingCaptureRecoveryStrip(), size: size, origin: .zero)
        strip.setFrameOrigin(Self.recoveryStripOrigin(size: size, besideBar: panel.frame, region: region, on: panel.screen))
        strip.orderFrontRegardless()
        recoveryPanel = strip
    }

    private func showRecovered() {
        guard recoveryPanel?.isVisible == true else { return }
        hasRecovered = true
        recoveryHideTask?.cancel()
        recoveryHideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.recoveredDisplayTime)
            guard !Task.isCancelled else { return }
            self?.hideRecoveryStrip()
        }
    }

    private func hideRecoveryStrip() {
        recoveryHideTask?.cancel()
        recoveryHideTask = nil
        recoveryPanel?.orderOut(nil)
        hasRecovered = false
    }

    /// On the far side of the bar from the region, so it never covers what
    /// is being scrolled; the near side when the far side is off screen.
    private static func recoveryStripOrigin(size: CGSize, besideBar bar: CGRect, region: CGRect, on screen: NSScreen?) -> CGPoint {
        let visible = screen?.visibleFrame ?? bar
        // The two panels' transparent margins overlap so the glass edges sit
        // 8 pt apart.
        let overlap = ScrollingCaptureBar.margin * 2 - 8
        let below = bar.minY + overlap - size.height
        let above = bar.maxY - overlap
        let barIsAboveRegion = bar.minY >= region.maxY
        let preferred = barIsAboveRegion ? above : below
        let fits = preferred >= visible.minY && preferred + size.height <= visible.maxY
        let y = fits ? preferred : (preferred == above ? below : above)
        return CGPoint(x: bar.midX - size.width / 2, y: y)
    }

    /// The strip shows a few hundred points of the rows; a full-resolution
    /// copy would hold megabytes for as long as track stays lost.
    private static func downscaled(_ image: CGImage, toWidth width: Int) -> CGImage? {
        guard image.width > width else { return image }
        let height = max(1, image.height * width / image.width)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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
        // Drawn with the bar's own button style and AppKit colors, like the
        // recording bar: the panel isn't key while the scrolled app has the
        // keyboard, and the system button styles then draw for an inactive
        // window, so Done lost its accent color and looked like Cancel.
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(presenter.hasLostTrack ? Color(nsColor: .systemOrange) : BarMetrics.activeTint)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
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

    private var title: String {
        if presenter.hasReachedLimit {
            "Maximum height reached"
        } else if presenter.hasLostTrack {
            "Scroll back to where you left off"
        } else {
            "Scroll to capture"
        }
    }

    private var detail: String {
        if presenter.hasLostTrack && !presenter.hasReachedLimit {
            return "Couldn't line this view up"
        }
        let height = "\(presenter.stitchedHeight.formatted()) px tall"
        guard let finishShortcut else { return height }
        return "\(height) · \(finishShortcut) to finish"
    }
}

/// The end of the stitch so far, shown while track is lost: the content to
/// bring back into the region. There's no "you are here" mark - with track
/// lost, where the view sits relative to it is exactly what isn't known.
private struct ScrollingCaptureRecoveryStrip: View {
    static let imageSize = CGSize(width: 356, height: 72)
    static let stripSize = CGSize(width: 380, height: 116)
    static let panelSize = CGSize(
        width: stripSize.width + ScrollingCaptureBar.margin * 2,
        height: stripSize.height + ScrollingCaptureBar.margin * 2
    )

    @State private var presenter = ScrollingCapturePresenter.shared

    private var tint: Color {
        Color(nsColor: presenter.hasRecovered ? .systemGreen : .systemOrange)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if presenter.hasRecovered {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(tint)
                }
                Text(presenter.hasRecovered ? "Back on track" : "Where you left off")
                    .foregroundStyle(BarMetrics.activeTint)
            }
            .font(.caption.weight(.semibold))
            .frame(height: 16)
            Group {
                if let target = presenter.recoveryTarget {
                    Image(decorative: target, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(nsColor: .quaternaryLabelColor)
                }
            }
            .frame(width: Self.imageSize.width, height: Self.imageSize.height, alignment: .bottom)
            .clipShape(.rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint, lineWidth: 1.5)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: Self.stripSize.width, height: Self.stripSize.height)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(ScrollingCaptureBar.margin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presenter.hasRecovered
            ? "Back on track"
            : "Where you left off: the last captured rows. Scroll back until they're in the region.")
    }
}
