import CoreGraphics
import Foundation
import ScreenCaptureKit

nonisolated struct RecordingDesktopFilter {
    let cleanDesktop: Bool
    let excludedApplications: [SCRunningApplication]
    let excludedWindows: [SCWindow]

    init(content: SCShareableContent, includesAppWindows: Bool, cleanDesktop: Bool) {
        self.cleanDesktop = cleanDesktop
        excludedApplications = content.applications.filter {
            Self.excludesApplication(
                bundleIdentifier: $0.bundleIdentifier,
                ownBundleIdentifier: Bundle.main.bundleIdentifier,
                includesAppWindows: includesAppWindows,
                cleanDesktop: cleanDesktop
            )
        }
        excludedWindows = content.windows.filter {
            Self.excludesWindow(
                bundleIdentifier: $0.owningApplication?.bundleIdentifier,
                layer: $0.windowLayer,
                cleanDesktop: cleanDesktop
            )
        }
    }

    func makeFilter(for display: SCDisplay) -> SCContentFilter {
        // shortcut: Dock, Notification Center or Finder restarts aren't re-excluded until the next recording; revisit if live updates are needed.
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: excludedWindows
        )
        filter.includeMenuBar = !cleanDesktop
        return filter
    }

    static func excludesApplication(
        bundleIdentifier: String,
        ownBundleIdentifier: String?,
        includesAppWindows: Bool,
        cleanDesktop: Bool
    ) -> Bool {
        if !includesAppWindows && bundleIdentifier == ownBundleIdentifier { return true }
        // shortcut: macOS supplies no semantic notification/Dock filter; recheck these owners in live OS QA.
        return cleanDesktop && (bundleIdentifier == "com.apple.dock"
            || bundleIdentifier == "com.apple.notificationcenterui")
    }

    static func excludesWindow(bundleIdentifier: String?, layer: Int, cleanDesktop: Bool) -> Bool {
        cleanDesktop && bundleIdentifier == "com.apple.finder"
            && layer == Int(CGWindowLevelForKey(.desktopIconWindow))
    }
}
