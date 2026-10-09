import Foundation

/// Keep test captures and their supporting files out of the personal Library.
nonisolated enum ScreendropStorage {
    static var directoryName: String {
        Bundle.main.bundleIdentifier == "com.fayazahmed.Screendrop" ? "Screendrop" : "Screendrop Dev"
    }

    static var applicationSupportDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseURL.appendingPathComponent(directoryName, isDirectory: true)
    }
}
