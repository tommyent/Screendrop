import AppKit
import SwiftUI

/// A value-only view so recovery can be rendered without a capture session.
struct ScrollingCaptureRecoveryStrip: View {
    static let pauseMessage = "Part of the page kept changing, probably a video. Pause it, then Continue."
    static let imageSize = CGSize(width: 356, height: 72)
    static let stripSize = CGSize(width: 380, height: 184)
    static let panelSize = CGSize(width: 404, height: 208)

    let target: CGImage?
    let hasRecovered: Bool
    let isPausedForVideo: Bool
    let onContinue: () -> Void

    private var tint: Color { Color(nsColor: hasRecovered ? .systemGreen : .systemOrange) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if hasRecovered {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(tint)
                }
                Text(hasRecovered ? "Back on track" : "Where you left off")
                    .foregroundStyle(BarMetrics.activeTint)
                Spacer()
                if isPausedForVideo {
                    Button(action: onContinue) {
                        Text("Continue")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 24)
                            .background(Color(nsColor: .controlAccentColor), in: .capsule)
                    }
                    .buttonStyle(BarButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Continue scrolling capture")
                    .accessibilityHint("Pause the video first. Retry from the last captured rows.")
                }
            }
            .font(.caption.weight(.semibold))
            .frame(height: 24)
            Text(isPausedForVideo ? Self.pauseMessage : hasRecovered
                 ? "Continue scrolling to capture."
                 : "Scroll back to where you left off.")
                .font(.callout)
                .foregroundStyle(BarMetrics.activeTint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 48, alignment: .topLeading)
                .accessibilityLabel(isPausedForVideo ? "Scrolling capture paused. \(Self.pauseMessage)" : hasRecovered
                    ? "Frames line up again. Continue scrolling to capture."
                    : "Scroll back to the last captured rows shown in the preview.")
            Group {
                if let target {
                    Image(decorative: target, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(nsColor: .quaternaryLabelColor)
                }
            }
            .frame(width: Self.imageSize.width, height: Self.imageSize.height, alignment: .bottom)
            .clipShape(.rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(tint, lineWidth: 1.5) }
            .accessibilityLabel("Preview of the last captured rows")
        }
        .padding(.horizontal, 12)
        .frame(width: Self.stripSize.width, height: Self.stripSize.height)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(12)
        .accessibilityElement(children: .contain)
    }
}
