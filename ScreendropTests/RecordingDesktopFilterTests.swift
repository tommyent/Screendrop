import CoreGraphics
import Testing

struct RecordingDesktopFilterTests {
    @Test(arguments: ["com.apple.dock", "com.apple.notificationcenterui"])
    func cleanDesktopExcludesSystemHostsEvenWhenAppWindowsAreIncluded(_ bundleIdentifier: String) {
        #expect(RecordingDesktopFilter.excludesApplication(
            bundleIdentifier: bundleIdentifier, ownBundleIdentifier: "test.app",
            includesAppWindows: true, cleanDesktop: true
        ))
        #expect(!RecordingDesktopFilter.excludesApplication(
            bundleIdentifier: bundleIdentifier, ownBundleIdentifier: "test.app",
            includesAppWindows: false, cleanDesktop: false
        ))
    }

    @Test(arguments: [false, true])
    func appWindowPreferenceStaysIndependent(_ cleanDesktop: Bool) {
        #expect(RecordingDesktopFilter.excludesApplication(
            bundleIdentifier: "test.app", ownBundleIdentifier: "test.app",
            includesAppWindows: false, cleanDesktop: cleanDesktop
        ))
        #expect(!RecordingDesktopFilter.excludesApplication(
            bundleIdentifier: "test.app", ownBundleIdentifier: "test.app",
            includesAppWindows: true, cleanDesktop: cleanDesktop
        ))
    }

    @Test(arguments: ["com.apple.finder", "com.apple.wallpaper.agent", "test.new-app"])
    func keepsFinderWallpaperAndNewApps(_ bundleIdentifier: String) {
        #expect(!RecordingDesktopFilter.excludesApplication(
            bundleIdentifier: bundleIdentifier, ownBundleIdentifier: "test.app",
            includesAppWindows: false, cleanDesktop: true
        ))
    }

    @Test func excludesOnlyFinderDesktopIconWindows() {
        let iconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
        #expect(RecordingDesktopFilter.excludesWindow(
            bundleIdentifier: "com.apple.finder", layer: iconLayer, cleanDesktop: true
        ))
        for layer in [0, Int(CGWindowLevelForKey(.desktopWindow)), iconLayer + 1] {
            #expect(!RecordingDesktopFilter.excludesWindow(
                bundleIdentifier: "com.apple.finder", layer: layer, cleanDesktop: true
            ))
        }
        #expect(!RecordingDesktopFilter.excludesWindow(
            bundleIdentifier: "com.apple.finder", layer: iconLayer, cleanDesktop: false
        ))
        #expect(!RecordingDesktopFilter.excludesWindow(
            bundleIdentifier: "test.app", layer: iconLayer, cleanDesktop: true
        ))
        #expect(!RecordingDesktopFilter.excludesWindow(
            bundleIdentifier: nil, layer: iconLayer, cleanDesktop: true
        ))
    }

    @Test(arguments: [false, true], [false, true])
    func cameraBubbleStaysExcludedWithoutChangingOtherAppWindows(_ cleanDesktop: Bool, _ includesAppWindows: Bool) {
        let appExcluded = RecordingDesktopFilter.excludesApplication(
            bundleIdentifier: "test.app", ownBundleIdentifier: "test.app",
            includesAppWindows: includesAppWindows, cleanDesktop: cleanDesktop
        )
        let cameraException = RecordingDesktopFilter.excludesWindow(
            bundleIdentifier: "test.app", layer: Int(CGWindowLevelForKey(.floatingWindow)),
            cleanDesktop: cleanDesktop, windowID: 42, cameraPreviewWindowID: 42,
            includesAppWindows: includesAppWindows
        )
        // ScreenCaptureKit exceptions invert the application's inclusion rule.
        #expect(appExcluded != cameraException)
        for windowID in [CGWindowID(43), CGWindowID(44)] { // Recording bar and ordinary app window.
            #expect(!RecordingDesktopFilter.excludesWindow(
                bundleIdentifier: "test.app", layer: Int(CGWindowLevelForKey(.floatingWindow)),
                cleanDesktop: cleanDesktop, windowID: windowID, cameraPreviewWindowID: 42,
                includesAppWindows: includesAppWindows
            ))
        }
        #expect(appExcluded == !includesAppWindows)
        #expect(!RecordingDesktopFilter.excludesWindow(
            bundleIdentifier: "test.app", layer: 0, cleanDesktop: cleanDesktop,
            windowID: 42, cameraPreviewWindowID: nil, includesAppWindows: includesAppWindows
        ))
    }
}
