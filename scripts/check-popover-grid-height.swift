import AppKit
import Observation
import SwiftUI

// xcrun swiftc -parse-as-library -default-isolation MainActor \
//   scripts/check-popover-grid-height.swift Screendrop/InspectorGridScroll.swift \
//   -o /private/tmp/check-popover-grid-height && /private/tmp/check-popover-grid-height
// Offscreen hosting views only: no windows, screen input, network or preferences.
@main
struct PopoverGridHeightChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let measured = GridMeasurement()
        let view = NSHostingView(rootView: InspectorGridScroll {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
                ForEach(0..<measured.count, id: \.self) { _ in
                    Color.gray.frame(height: 90)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured.height = $0 }
        })
        view.frame = NSRect(x: 0, y: 0, width: 292, height: 320)
        for count in [1, 24, 1] {
            measured.count = count
            for _ in 0..<5 {
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            let height = view.fittingSize.height
            let expected: CGFloat = count == 1 ? 90 : 320
            precondition(abs(height - expected) < 1, "\(count) tiles: fitted \(height), expected \(expected)")
            if count > 3 {
                precondition(measured.height > height, "Many-row content must exceed its scroll viewport")
            }
            print("\(count) tiles: content \(measured.height), fitted height \(height)")
        }
        print("popover grid height checks passed")
    }
}

@Observable @MainActor private final class GridMeasurement {
    var count = 1
    var height: CGFloat = 0
}
