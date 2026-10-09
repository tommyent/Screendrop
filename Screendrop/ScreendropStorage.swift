import Foundation

/// Keep development files and credentials separate from the personal app.
nonisolated enum ScreendropStorage {
    static var isPersonalBuild: Bool {
        Bundle.main.bundleIdentifier == "com.fayazahmed.Screendrop"
    }

    static var directoryName: String {
        isPersonalBuild ? "Screendrop" : "Screendrop Dev"
    }

    static var keychainService: String {
        isPersonalBuild ? "com.fayazahmed.Screendrop" : "com.fayazahmed.Screendrop.dev"
    }

    static var applicationSupportDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseURL.appendingPathComponent(directoryName, isDirectory: true)
    }
}
