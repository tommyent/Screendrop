import Foundation

/// The one-time import of Screendrop's data into Sukusho. It copies and never
/// moves: Screendrop's folder, preferences and keychain item stay as they
/// were, so reinstalling Screendrop is a full rollback. Nothing here touches
/// the system directly beyond the folders, defaults and keychain it's given.
struct LegacyIdentityImport {
    /// The Cloud upload token, by keychain service.
    struct Keychain {
        var read: (_ service: String) -> String?
        var write: (_ service: String, _ value: String) -> Void
    }

    enum Outcome: Equatable {
        case alreadyDone
        /// Screendrop left nothing behind; recorded so it isn't looked for again.
        case nothingToImport
        case imported(hasToken: Bool)
    }

    static let markerKey = "migration.screendrop"
    /// `ScreendropPreferences.exportDirectoryPathKey`.
    static let exportDirectoryPathKey = "exportDirectoryPath"

    var legacySupport: URL
    var currentSupport: URL
    var legacyDefaults: [String: Any]?
    var defaults: UserDefaults
    var legacyKeychainService: String
    var currentKeychainService: String
    var keychain: Keychain
    /// Screendrop's default save folder, `~/Pictures/Screendrop`.
    var legacyExportDirectory: URL

    var isDone: Bool { defaults.object(forKey: Self.markerKey) != nil }

    var hasLegacyData: Bool {
        FileManager.default.fileExists(atPath: legacySupport.path) || !(legacyDefaults ?? [:]).isEmpty
    }

    /// Copies everything, then marks the import done. A failed folder copy
    /// throws with nothing marked, so the next launch tries again.
    func run() throws -> Outcome {
        guard !isDone else { return .alreadyDone }
        guard hasLegacyData else {
            markDone()
            return .nothingToImport
        }
        try copySupportFolder()
        copyDefaults()
        let hasToken = copyToken()
        pinExportFolder()
        markDone()
        return .imported(hasToken: hasToken)
    }

    /// The user chose to start without Screendrop's data.
    func skip() { defaults.set("skipped", forKey: Self.markerKey) }

    private func markDone() { defaults.set(Date(), forKey: Self.markerKey) }

    private func copySupportFolder() throws {
        let files = FileManager.default
        guard files.fileExists(atPath: legacySupport.path) else { return }
        // Never merge into a folder this app already uses; an empty one is replaced.
        if let contents = try? files.contentsOfDirectory(atPath: currentSupport.path) {
            guard contents.isEmpty else { return }
            try files.removeItem(at: currentSupport)
        }
        let staging = currentSupport.deletingLastPathComponent()
            .appendingPathComponent(currentSupport.lastPathComponent + ".importing", isDirectory: true)
        try? files.removeItem(at: staging)
        do {
            // On APFS this clones, so recordings take no extra space until a copy changes.
            try files.copyItem(at: legacySupport, to: staging)
            try files.moveItem(at: staging, to: currentSupport)
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
    }

    /// Keys this app already has win. Paths into Screendrop's folder are
    /// pointed at the copy.
    private func copyDefaults() {
        for (key, value) in legacyDefaults ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(remapped(value), forKey: key)
        }
    }

    private func remapped(_ value: Any) -> Any {
        switch value {
        case let path as String: return ScreendropStorage.remap(path, from: legacySupport, to: currentSupport)
        case let paths as [String]: return paths.map { ScreendropStorage.remap($0, from: legacySupport, to: currentSupport) }
        default: return value
        }
    }

    /// Whether this app has a token afterwards. Reading Screendrop's item is
    /// expected to make macOS ask once, since that item trusts Screendrop.
    private func copyToken() -> Bool {
        if let token = keychain.read(currentKeychainService), !token.isEmpty { return true }
        guard let token = keychain.read(legacyKeychainService), !token.isEmpty else { return false }
        keychain.write(currentKeychainService, token)
        return true
    }

    /// Screendrop saved to `~/Pictures/Screendrop` by default. If it did here,
    /// keep saving there, set explicitly so Settings shows it; files never move.
    private func pinExportFolder() {
        guard (defaults.string(forKey: Self.exportDirectoryPathKey) ?? "").isEmpty,
              FileManager.default.fileExists(atPath: legacyExportDirectory.path) else { return }
        defaults.set(legacyExportDirectory.path, forKey: Self.exportDirectoryPathKey)
    }
}
