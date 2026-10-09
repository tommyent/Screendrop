import Foundation

// swiftc -parse-as-library -default-isolation MainActor scripts/check-dev-keychain-service.swift \
//   Screendrop/ScreendropStorage.swift -o /private/tmp/check-dev-keychain-service

// Substitute only Bundle's identifier; run the real storage policy without app or Keychain services.
enum Bundle {
    struct Identity { var bundleIdentifier: String? }
    nonisolated(unsafe) static var main = Identity(bundleIdentifier: nil)
}

@main
struct DevKeychainServiceChecks {
    static func main() {
        let personalLegacy = ScreendropStorage.LegacyIdentity(bundleIdentifier: "com.fayazahmed.Screendrop",
            directoryName: "Screendrop", keychainService: "com.fayazahmed.Screendrop")
        let devLegacy = ScreendropStorage.LegacyIdentity(bundleIdentifier: "com.fayazahmed.Screendrop.dev",
            directoryName: "Screendrop Dev", keychainService: "com.fayazahmed.Screendrop.dev")
        let cases: [(String?, Bool, String, String, ScreendropStorage.LegacyIdentity?)] = [
            ("com.tommyent.Sukusho", true, "Sukusho", "com.tommyent.Sukusho", personalLegacy),
            ("com.tommyent.Sukusho.dev", false, "Sukusho Dev", "com.tommyent.Sukusho.dev", devLegacy),
            ("example.preview-harness", false, "Sukusho Dev", "com.tommyent.Sukusho.dev", nil),
            (nil, false, "Sukusho Dev", "com.tommyent.Sukusho.dev", nil),
            ("", false, "Sukusho Dev", "com.tommyent.Sukusho.dev", nil),
            ("com.tommyent.sukusho", false, "Sukusho Dev", "com.tommyent.Sukusho.dev", nil),
            // Screendrop's own identities are neither: they never import, and get Dev storage.
            ("com.fayazahmed.Screendrop", false, "Sukusho Dev", "com.tommyent.Sukusho.dev", nil),
            ("com.fayazahmed.Screendrop.dev", false, "Sukusho Dev", "com.tommyent.Sukusho.dev", nil),
        ]
        for (id, personal, directory, service, legacy) in cases {
            Bundle.main.bundleIdentifier = id
            precondition(ScreendropStorage.isPersonalBuild == personal)
            precondition(ScreendropStorage.directoryName == directory)
            precondition(ScreendropStorage.applicationSupportDirectory.lastPathComponent == directory)
            precondition(ScreendropStorage.keychainService == service)
            precondition(ScreendropStorage.legacy == legacy)
            precondition(ScreendropStorage.legacyApplicationSupportDirectory?.lastPathComponent == legacy?.directoryName)
        }

        let old = URL(fileURLWithPath: "/Users/x/Library/Application Support/Screendrop", isDirectory: true)
        let new = URL(fileURLWithPath: "/Users/x/Library/Application Support/Sukusho", isDirectory: true)
        let remaps: [(String, String)] = [
            ("/Users/x/Library/Application Support/Screendrop/Recordings/a",
             "/Users/x/Library/Application Support/Sukusho/Recordings/a"),
            ("/Users/x/Library/Application Support/Screendrop Dev/Recordings/a",
             "/Users/x/Library/Application Support/Screendrop Dev/Recordings/a"),
            ("/Users/x/Library/Application Support/Screendrop", "/Users/x/Library/Application Support/Screendrop"),
            ("/Users/x/Pictures/Screendrop/shot.png", "/Users/x/Pictures/Screendrop/shot.png"),
        ]
        for (path, expected) in remaps {
            precondition(ScreendropStorage.remap(path, from: old, to: new) == expected)
        }
        Bundle.main.bundleIdentifier = "example.preview-harness"
        precondition(ScreendropStorage.remapLegacyPath(remaps[0].0) == remaps[0].0)
        print("PASS: 53 namespace checks; Sukusho and Sukusho Dev import only their own Screendrop identity; harness identities import nothing; remap stops at the folder boundary; no Keychain access")
    }
}
