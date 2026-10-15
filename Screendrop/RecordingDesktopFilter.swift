import CoreGraphics
import Foundation
import ScreenCaptureKit

nonisolated struct RecordingDesktopFilter {
    let includesAppWindows: Bool
    let cleanDesktop: Bool
    let excludedApplications: [SCRunningApplication]
    let excludedWindows: [SCWindow]

    init(content: SCShareableContent, includesAppWindows: Bool, cleanDesktop: Bool) {
        self.includesAppWindows = includesAppWindows
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
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: excludedWindows
        )
        filter.includeMenuBar = !cleanDesktop
        return filter
    }

    func hasSameExclusions(as other: RecordingDesktopFilter) -> Bool {
        Set(excludedApplications.map(\.processID)) == Set(other.excludedApplications.map(\.processID))
            && Set(excludedWindows.map(\.windowID)) == Set(other.excludedWindows.map(\.windowID))
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
