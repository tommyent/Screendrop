import AppKit
import SwiftUI

/// Imports Screendrop's data once, before anything reads settings or files,
/// then starts the app.
@main
enum AppEntry {
    static func main() {
        importFromScreendrop()
        ScreendropApp.main()
    }

    private static func importFromScreendrop() {
        guard let legacy = ScreendropStorage.legacy,
              let legacySupport = ScreendropStorage.legacyApplicationSupportDirectory else { return }
        let account = CloudCredentialStore.Keys.uploadToken
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        let legacyDefaults = UserDefaults.standard.persistentDomain(forName: legacy.bundleIdentifier)
        let job = LegacyIdentityImport(
            legacySupport: legacySupport,
            currentSupport: ScreendropStorage.applicationSupportDirectory,
            legacyDefaults: legacyDefaults,
            defaults: .standard,
            legacyKeychainService: legacy.keychainService,
            currentKeychainService: ScreendropStorage.keychainService,
            keychain: .init(
                read: { CloudCredentialStore.getKeychainItem(key: account, service: $0) },
                write: { CloudCredentialStore.setKeychainItem(key: account, value: $1, service: $0) }
            ),
            legacyExportDirectory: pictures.appendingPathComponent(legacy.directoryName, isDirectory: true)
        )
        guard !job.isDone else { return }
        // Screendrop mustn't write its history or a recording while it's copied.
        if job.hasLegacyData, !quitScreendrop(legacy.bundleIdentifier) { exit(0) }
        do {
            guard case .imported(let hasToken) = try job.run() else { return }
            let usedCloud = !(legacyDefaults?[CloudCredentialStore.Keys.workerURL] as? String ?? "").isEmpty
            showImported(needsToken: usedCloud && !hasToken)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Sukusho couldn’t bring over your Screendrop data"
            alert.informativeText = "\(error.localizedDescription)\n\nNothing in Screendrop was changed. Quit to try again the next time you open Sukusho, or start without your Screendrop captures and settings."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Start Without Them")
            guard runModal(alert) == .alertSecondButtonReturn else { exit(0) }
            job.skip()
        }
    }

    /// False when the user cancels, or Screendrop doesn't quit within 30 seconds.
    private static func quitScreendrop(_ bundleIdentifier: String) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard !running.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Quit Screendrop to finish setting up Sukusho"
        alert.informativeText = "Sukusho brings over your captures, recordings and settings from Screendrop once, and Screendrop needs to be closed while it does. Screendrop’s own copy stays as it is."
        alert.addButton(withTitle: "Quit Screendrop")
        alert.addButton(withTitle: "Cancel")
        guard runModal(alert) == .alertFirstButtonReturn else { return false }
        running.forEach { $0.terminate() }
        // Screendrop may finish a recording or ask about unsaved edits first.
        let deadline = Date().addingTimeInterval(30)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard running.contains(where: { !$0.isTerminated }) else { return true }
        let stillOpen = NSAlert()
        stillOpen.messageText = "Screendrop is still open"
        stillOpen.informativeText = "Quit Screendrop, then open Sukusho again."
        runModal(stillOpen)
        return false
    }

    private static func showImported(needsToken: Bool) {
        let alert = NSAlert()
        alert.messageText = "Your Screendrop captures and settings are in Sukusho"
        var details = [
            "Screendrop’s own copy is unchanged.",
            "macOS asks again for Screen Recording the first time Sukusho captures, and for the camera, microphone and input monitoring when they’re first used.",
            "If Screendrop opened at login, turn on Launch at login in Sukusho’s settings and remove Screendrop from Login Items in System Settings.",
        ]
        if needsToken {
            details.insert("Enter your Cloud upload token again in Settings › Cloud.", at: 1)
        }
        alert.informativeText = details.joined(separator: "\n\n")
        runModal(alert)
    }

    @discardableResult
    private static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApplication.shared.activate()
        return alert.runModal()
    }
}
