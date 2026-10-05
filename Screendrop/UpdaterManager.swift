//
//  UpdaterManager.swift
//  Screendrop
//

import AppKit
import Combine
import Foundation
import Sparkle

/// Manages Sparkle auto-update lifecycle.
///
/// Sparkle's `SPUStandardUpdaterController` must be created early, before
/// `applicationDidFinishLaunching` returns, so the automatic update check
/// schedule starts correctly.
@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()

    private let controller: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    private override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// This fork's personal builds never start Sparkle: the feed is upstream's,
    /// and an upstream release would replace the build and drop the fork's
    /// features. The fork is updated by rebuilding it instead.
    func start() {}

    func checkForUpdates() {}
}
