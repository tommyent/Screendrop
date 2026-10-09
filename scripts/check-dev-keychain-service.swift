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
        let cases: [(String?, Bool, String, String)] = [
            ("com.fayazahmed.Screendrop", true, "Screendrop", "com.fayazahmed.Screendrop"),
            ("com.fayazahmed.Screendrop.dev", false, "Screendrop Dev", "com.fayazahmed.Screendrop.dev"),
            ("example.preview-harness", false, "Screendrop Dev", "com.fayazahmed.Screendrop.dev"),
            (nil, false, "Screendrop Dev", "com.fayazahmed.Screendrop.dev"),
            ("", false, "Screendrop Dev", "com.fayazahmed.Screendrop.dev"),
            ("com.fayazahmed.screendrop", false, "Screendrop Dev", "com.fayazahmed.Screendrop.dev"),
        ]
        for (id, personal, directory, service) in cases {
            Bundle.main.bundleIdentifier = id
            precondition(ScreendropStorage.isPersonalBuild == personal)
            precondition(ScreendropStorage.directoryName == directory)
            precondition(ScreendropStorage.applicationSupportDirectory.lastPathComponent == directory)
            precondition(ScreendropStorage.keychainService == service)
        }
        print("PASS: 24 namespace checks; personal identity unchanged; Dev and harness identities isolated; no Keychain access")
    }
}
