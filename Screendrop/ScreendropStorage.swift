import Foundation

/// Keep development files and credentials separate from the personal app.
nonisolated enum ScreendropStorage {
    static let personalBundleIdentifier = "com.tommyent.Sukusho"
    static let devBundleIdentifier = "com.tommyent.Sukusho.dev"

    static var isPersonalBuild: Bool {
        Bundle.main.bundleIdentifier == personalBundleIdentifier
    }

    static var directoryName: String {
        isPersonalBuild ? "Sukusho" : "Sukusho Dev"
    }

    static var keychainService: String {
        isPersonalBuild ? personalBundleIdentifier : devBundleIdentifier
    }

    static var applicationSupportDirectory: URL {
        supportBaseDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The identity this app shipped under as Screendrop, whose data it
    /// imports once. Dev imports only Screendrop Dev's; any other identity
    /// (a harness, a test) has none and never reads Screendrop's data.
    struct LegacyIdentity: Equatable {
        let bundleIdentifier: String
        let directoryName: String
        let keychainService: String
    }

    static var legacy: LegacyIdentity? {
        switch Bundle.main.bundleIdentifier {
        case personalBundleIdentifier?:
            LegacyIdentity(bundleIdentifier: "com.fayazahmed.Screendrop", directoryName: "Screendrop",
                           keychainService: "com.fayazahmed.Screendrop")
        case devBundleIdentifier?:
            LegacyIdentity(bundleIdentifier: "com.fayazahmed.Screendrop.dev", directoryName: "Screendrop Dev",
                           keychainService: "com.fayazahmed.Screendrop.dev")
        default:
            nil
        }
    }

    static var legacyApplicationSupportDirectory: URL? {
        legacy.map { supportBaseDirectory.appendingPathComponent($0.directoryName, isDirectory: true) }
    }

    /// A path saved by Screendrop inside its own folder, pointed at the same
    /// file in this app's copy. Always remapped, even while Screendrop's file
    /// still exists, so this app never edits Screendrop's data.
    static func remapLegacyPath(_ path: String) -> String {
        guard let legacy = legacyApplicationSupportDirectory else { return path }
        return remap(path, from: legacy, to: applicationSupportDirectory)
    }

    static func remap(_ path: String, from old: URL, to new: URL) -> String {
        // The slash keeps "…/Screendrop Dev/…" from matching "…/Screendrop".
        let prefix = old.path + "/"
        guard path.hasPrefix(prefix) else { return path }
        return new.path + "/" + path.dropFirst(prefix.count)
    }

    private static var supportBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
