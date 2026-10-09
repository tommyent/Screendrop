// The one-time Screendrop import, against temporary folders, a throwaway
// defaults suite and an in-memory keychain. Nothing here touches real data.
import Foundation
import Testing

@MainActor
@Suite
struct LegacyIdentityImportTests {
    final class FakeKeychain {
        var items: [String: String] = [:]
        var reads: [String] = []
        var keychain: LegacyIdentityImport.Keychain {
            .init(read: { self.reads.append($0); return self.items[$0] },
                  write: { self.items[$0] = $1 })
        }
    }

    struct Sandbox {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let keychain = FakeKeychain()
        var legacy: URL { root.appendingPathComponent("Screendrop", isDirectory: true) }
        var current: URL { root.appendingPathComponent("Sukusho", isDirectory: true) }
        var staging: URL { root.appendingPathComponent("Sukusho.importing", isDirectory: true) }
        var exports: URL { root.appendingPathComponent("Pictures/Screendrop", isDirectory: true) }

        func job(legacyDefaults: [String: Any]? = nil) -> LegacyIdentityImport {
            LegacyIdentityImport(legacySupport: legacy, currentSupport: current, legacyDefaults: legacyDefaults,
                                 defaults: defaults, legacyKeychainService: "legacy.service",
                                 currentKeychainService: "current.service", keychain: keychain.keychain,
                                 legacyExportDirectory: exports)
        }

        func write(_ text: String, to path: String, in folder: URL) throws {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func read(_ path: String, in folder: URL) -> String? {
            (try? Data(contentsOf: folder.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
        }

        /// A Screendrop folder with a history, a recording and a wallpaper.
        func seedLegacy() throws {
            try write(#"[{"fileName":"a.png"}]"#, to: "history.json", in: legacy)
            try write("screen bytes", to: "Recordings/Screendrop_2026/screen.mov", in: legacy)
            try write("wallpaper bytes", to: "Wallpapers/w.png", in: legacy)
        }
    }

    private func withSandbox(_ body: (Sandbox) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Sukusho-ImportTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "sukusho.import-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try body(Sandbox(root: root, defaults: defaults, suite: suite))
    }

    @Test func freshInstallFindsNothingAndDoesNotLookAgain() throws {
        try withSandbox { box throws in
            #expect(try box.job().run() == .nothingToImport)
            #expect(!FileManager.default.fileExists(atPath: box.current.path))
            #expect(box.keychain.reads.isEmpty)
            #expect(try box.job().run() == .alreadyDone)
        }
    }

    @Test func copiesTheFolderAndLeavesScreendropUntouched() throws {
        try withSandbox { box throws in
            try box.seedLegacy()
            #expect(try box.job().run() == .imported(hasToken: false))
            for (path, text) in [("history.json", #"[{"fileName":"a.png"}]"#),
                                 ("Recordings/Screendrop_2026/screen.mov", "screen bytes"),
                                 ("Wallpapers/w.png", "wallpaper bytes")] {
                #expect(box.read(path, in: box.current) == text)
                #expect(box.read(path, in: box.legacy) == text)
            }
            #expect(!FileManager.default.fileExists(atPath: box.staging.path))
            #expect(try box.job().run() == .alreadyDone)
        }
    }

    @Test func neverMergesIntoAFolderAlreadyInUse() throws {
        try withSandbox { box throws in
            try box.seedLegacy()
            try box.write("sukusho history", to: "history.json", in: box.current)
            #expect(try box.job().run() == .imported(hasToken: false))
            #expect(box.read("history.json", in: box.current) == "sukusho history")
            #expect(box.read("Wallpapers/w.png", in: box.current) == nil)
        }
    }

    @Test func replacesAnEmptyFolderAndRedoesALeftoverCopy() throws {
        try withSandbox { box throws in
            try box.seedLegacy()
            try FileManager.default.createDirectory(at: box.current, withIntermediateDirectories: true)
            try box.write("half a copy", to: "junk", in: box.staging)
            _ = try box.job().run()
            #expect(box.read("Wallpapers/w.png", in: box.current) == "wallpaper bytes")
            #expect(box.read("junk", in: box.current) == nil)
            #expect(!FileManager.default.fileExists(atPath: box.staging.path))
        }
    }

    @Test func aFailedCopyMarksNothingAndLeavesNoHalfCopy() throws {
        try withSandbox { box throws in
            try box.seedLegacy()
            // The copy can't be created next to Screendrop's folder.
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: box.root.path)
            #expect(throws: (any Error).self) { try box.job().run() }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.root.path)
            #expect(!box.job().isDone)
            #expect(!FileManager.default.fileExists(atPath: box.staging.path))
            #expect(box.read("history.json", in: box.legacy) == #"[{"fileName":"a.png"}]"#)
            // The next launch tries again and succeeds.
            #expect(try box.job().run() == .imported(hasToken: false))
        }
    }

    @Test func defaultsNeverOverwriteAndPathsPointAtTheCopy() throws {
        try withSandbox { box throws in
            box.defaults.set("sukusho value", forKey: "shared")
            let legacyWallpaper = box.legacy.appendingPathComponent("Wallpapers/w.png").path
            let elsewhere = box.root.appendingPathComponent("Downloads/x.png").path
            _ = try box.job(legacyDefaults: [
                "hotkey.region": "⌥2",
                "shared": "screendrop value",
                "cloudCommentsRead.https://w.example": 1_791_525_330.0,
                "annotationBackground.recentWallpaperPaths": [legacyWallpaper, elsewhere],
                "lastFolder": legacyWallpaper,
            ]).run()
            #expect(box.defaults.string(forKey: "hotkey.region") == "⌥2")
            #expect(box.defaults.string(forKey: "shared") == "sukusho value")
            #expect(box.defaults.double(forKey: "cloudCommentsRead.https://w.example") == 1_791_525_330)
            let copied = box.current.appendingPathComponent("Wallpapers/w.png").path
            #expect(box.defaults.stringArray(forKey: "annotationBackground.recentWallpaperPaths") == [copied, elsewhere])
            #expect(box.defaults.string(forKey: "lastFolder") == copied)
        }
    }

    @Test func tokenIsCopiedOnlyWhenSukushoHasNone() throws {
        try withSandbox { box throws in
            box.keychain.items["legacy.service"] = "dummy-legacy-token"
            #expect(try box.job(legacyDefaults: ["k": 1]).run() == .imported(hasToken: true))
            #expect(box.keychain.items["current.service"] == "dummy-legacy-token")
        }
        try withSandbox { box throws in
            // An existing token wins, and Screendrop's item isn't even read (no keychain prompt).
            box.keychain.items = ["legacy.service": "dummy-legacy-token", "current.service": "dummy-current-token"]
            #expect(try box.job(legacyDefaults: ["k": 1]).run() == .imported(hasToken: true))
            #expect(box.keychain.items["current.service"] == "dummy-current-token")
            #expect(box.keychain.reads == ["current.service"])
        }
        try withSandbox { box throws in
            box.keychain.items = ["legacy.service": "dummy-legacy-token", "current.service": ""]
            _ = try box.job(legacyDefaults: ["k": 1]).run()
            #expect(box.keychain.items["current.service"] == "dummy-legacy-token")
        }
        try withSandbox { box throws in
            // Denied or absent: Cloud asks for the token again.
            #expect(try box.job(legacyDefaults: ["k": 1]).run() == .imported(hasToken: false))
            #expect(box.keychain.items.isEmpty)
        }
    }

    @Test func exportFolderIsPinnedOnlyWhenItWasTheDefaultAndExists() throws {
        try withSandbox { box throws in
            try FileManager.default.createDirectory(at: box.exports, withIntermediateDirectories: true)
            _ = try box.job(legacyDefaults: ["k": 1]).run()
            #expect(box.defaults.string(forKey: LegacyIdentityImport.exportDirectoryPathKey) == box.exports.path)
        }
        try withSandbox { box throws in
            try FileManager.default.createDirectory(at: box.exports, withIntermediateDirectories: true)
            _ = try box.job(legacyDefaults: [LegacyIdentityImport.exportDirectoryPathKey: "/Users/x/Desktop"]).run()
            #expect(box.defaults.string(forKey: LegacyIdentityImport.exportDirectoryPathKey) == "/Users/x/Desktop")
        }
        try withSandbox { box throws in
            _ = try box.job(legacyDefaults: ["k": 1]).run()
            #expect(box.defaults.object(forKey: LegacyIdentityImport.exportDirectoryPathKey) == nil)
        }
    }

    @Test func startingWithoutTheImportIsRemembered() throws {
        try withSandbox { box throws in
            try box.seedLegacy()
            box.job().skip()
            #expect(try box.job().run() == .alreadyDone)
            #expect(!FileManager.default.fileExists(atPath: box.current.path))
        }
    }

    @Test func remapStopsAtTheFolderBoundary() {
        let old = URL(fileURLWithPath: "/S/Screendrop", isDirectory: true)
        let new = URL(fileURLWithPath: "/S/Sukusho", isDirectory: true)
        #expect(ScreendropStorage.remap("/S/Screendrop/Recordings/a", from: old, to: new) == "/S/Sukusho/Recordings/a")
        #expect(ScreendropStorage.remap("/S/Screendrop Dev/Recordings/a", from: old, to: new) == "/S/Screendrop Dev/Recordings/a")
        #expect(ScreendropStorage.remap("/S/Screendrop", from: old, to: new) == "/S/Screendrop")
        // The test runner has no Screendrop identity, so nothing is remapped.
        #expect(ScreendropStorage.remapLegacyPath("/S/Screendrop/x") == "/S/Screendrop/x")
    }
}
