import SwiftUI

/// A fitting popover needs an explicit scroll height, not only a maximum.
struct InspectorGridScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    // Start at the cap so a lazy grid lays out before reporting its height.
    @State private var contentHeight: CGFloat = 320

    var body: some View {
        ScrollView {
            content()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    ceil(proxy.size.height)
                } action: { height in
                    contentHeight = max(1, height)
                }
        }
        .frame(height: min(contentHeight, 320))
    }
}
