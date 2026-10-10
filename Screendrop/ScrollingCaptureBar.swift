//
//  ScrollingCaptureBar.swift
//  Screendrop
//

import AppKit
import SwiftUI

private final class ScrollingCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct ScrollingCaptureBar: View {
    /// Wide enough for the auto-scroll button beside the longest message.
    static let barSize = CGSize(width: 500, height: 52)
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
                    .foregroundStyle(presenter.isWaiting ? Color(nsColor: .systemOrange) : BarMetrics.activeTint)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(presenter.keepsChanging ? 2 : 1)
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
            : presenter.keepsChanging ? "Something on the page keeps changing"
            : presenter.isWaiting ? "Scroll back a little" : "Scroll to capture"
    }

    private var detail: String {
        guard !presenter.hasReachedLimit else { return "\(presenter.stitchedHeight.formatted()) px tall" }
        if presenter.keepsChanging {
            return "Video, animation or hover: pause it or move the pointer away, then scroll back a little."
        }
        if presenter.isWaiting { return "This view doesn’t line up yet" }
        let height = "\(presenter.stitchedHeight.formatted()) px tall"
        guard let finishShortcut else { return height }
        return "\(height) · \(finishShortcut) to finish"
    }
}

extension ScrollingCaptureBar {
    /// The bar's panel, below the region: borderless, never key-stealing,
    /// above everything and left out of every capture.
    static func makePanel(below rect: CGRect, on screen: NSScreen?) -> NSPanel {
        let size = panelSize
        let panel = ScrollingCapturePanel(contentRect: CGRect(origin: panelOrigin(size: size, below: rect, on: screen),
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
        return panel
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
