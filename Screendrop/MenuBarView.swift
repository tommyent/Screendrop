//
//  MenuBarView.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var updaterManager = UpdaterManager.shared
    @State private var historyStore = ScreenshotHistoryStore.shared
    @State private var projectStore = RecordingProjectStore.shared

    var body: some View {
        // Shortcuts change in Settings; this re-reads them.
        let _ = HotkeyManager.shared.revision
        Group {
            Button {
                CaptureCoordinator.shared.captureFullscreen()
            } label: {
                Label("Capture Fullscreen", systemImage: "macwindow")
            }
            .keyboardShortcut(Self.shortcut(for: .fullscreen))
            
            Button {
                CaptureCoordinator.shared.captureWindow()
            } label: {
                Label("Capture Window", systemImage: "macwindow.on.rectangle")
            }
            .keyboardShortcut(Self.shortcut(for: .window))
            
            Button {
                CaptureCoordinator.shared.captureArea()
            } label: {
                Label("Capture Area", systemImage: "rectangle.dashed")
            }
            .keyboardShortcut(Self.shortcut(for: .area))

            Button {
                CaptureCoordinator.shared.captureText()
            } label: {
                Label("Capture Text", systemImage: "text.viewfinder")
            }
            .keyboardShortcut(Self.shortcut(for: .textCapture))

            Button {
                CaptureCoordinator.shared.captureScrolling()
            } label: {
                Label(
                    ScrollingCapturePresenter.shared.isRunning ? "Finish Scrolling Capture" : "Scrolling Capture",
                    systemImage: "rectangle.expand.vertical"
                )
            }
            .keyboardShortcut(Self.shortcut(for: .scrollingCapture))
            // A recording and a scrolling capture both use the region
            // highlight, so neither starts while the other runs.
            .disabled(ScreenRecordingManager.shared.isActive)

            // While recording, the item stops it, as Scrolling Capture's
            // finishes it (design pass choice 13).
            if ScreenRecordingManager.shared.isActive {
                Button {
                    ScreenRecordingManager.shared.stopRecording()
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle")
                }
                .disabled(ScreenRecordingManager.shared.state == .finishing)
            } else {
                Button {
                    RecordingBarPresenter.shared.showPicker()
                } label: {
                    Label("Record Screen", systemImage: "record.circle")
                }
                .keyboardShortcut(Self.shortcut(for: .screenRecording))
                .disabled(ScrollingCapturePresenter.shared.isRunning)
            }

            Divider()

            Button {
                CaptureLibraryModel.shared.show()
            } label: {
                Label("Show Library", systemImage: "square.grid.2x2")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Menu {
                projectsMenuContent
            } label: {
                Label("Recordings", systemImage: "film.stack")
            }

            Menu {
                historyMenuContent
            } label: {
                Label("Recent Captures", systemImage: "clock.arrow.circlepath")
            }

            Button {
                openScreenshotsFolder()
            } label: {
                Label("Open Save Folder", systemImage: "folder")
            }

            Divider()

            Button {
                openSettings(tab: .general)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: [.command])

            Button {
                updaterManager.checkForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
            }
            .disabled(!updaterManager.canCheckForUpdates)
            
            Divider()
            
            Button("Quit Screendrop") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .task {
            historyStore.reload()
            projectStore.reload()
        }
    }

    /// Reopening a recording is the common case after the first edit, so the
    /// recents land here rather than behind Settings.
    @ViewBuilder
    private var projectsMenuContent: some View {
        if projectStore.projects.isEmpty {
            Text("No recordings")
        } else {
            ForEach(projectStore.recentProjects) { project in
                Button(projectMenuTitle(for: project)) {
                    RecordingProjectOpener.shared.open(project.session)
                }
            }

            Divider()
        }

        Button {
            CaptureLibraryModel.shared.show(filter: .recordings)
        } label: {
            Label("Show All Recordings…", systemImage: "square.grid.2x2")
        }
    }

    private func projectMenuTitle(for project: RecordingProjectSummary) -> String {
        let name = truncatedMenuTitle(project.displayName)
        return project.hasUnsavedDraft ? "\(name) - Unsaved" : name
    }

    @ViewBuilder
    private var historyMenuContent: some View {
        if historyStore.recentItems.isEmpty {
            Text("No captures")
        } else {
            ForEach(historyStore.recentItems) { item in
                Button(historyMenuTitle(for: item)) {
                    showHistoryPreview(item)
                }
            }

            Divider()
        }

        Button {
            CaptureLibraryModel.shared.show(filter: .all)
        } label: {
            Label("Show All Captures…", systemImage: "rectangle.stack")
        }
    }

    private func showHistoryPreview(_ item: ScreenshotHistoryItem) {
        if item.isVideo {
            ScreenshotPreviewStack.shared.previewExistingVideo(url: item.url)
        } else {
            ScreenshotPreviewStack.shared.previewExistingImage(url: item.url)
        }
        PreviewPanelPresenter.shared.show(displayID: ActiveDisplayResolver.activeDisplayID(preferPointer: false))
    }

    private func openSettings(tab: SettingsTab) {
        SettingsWindowController.show(tab: tab)
    }

    private func openScreenshotsFolder() {
        let directory = ScreendropPreferences.exportDirectory

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            showOpenScreenshotsFolderError(directory: directory, errorDescription: error.localizedDescription)
            return
        }

        if !NSWorkspace.shared.open(directory) {
            showOpenScreenshotsFolderError(directory: directory, errorDescription: nil)
        }
    }

    private func showOpenScreenshotsFolderError(directory: URL, errorDescription: String?) {
        let alert = NSAlert()
        alert.messageText = "Could not open screenshots folder."
        alert.informativeText = errorDescription ?? directory.path
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func historyMenuTitle(for item: ScreenshotHistoryItem) -> String {
        let name = item.displayName ?? item.fileName
        let limit = 30

        guard name.count > limit else {
            return name
        }

        let url = URL(fileURLWithPath: name)
        let pathExtension = url.pathExtension
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let baseName = url.deletingPathExtension().lastPathComponent
        let allowedBaseLength = max(8, limit - suffix.count - 1)

        return "\(baseName.prefix(allowedBaseLength))…\(suffix)"
    }

    /// Menus get unusably wide with full session names, which carry a
    /// timestamp and a uniquing suffix.
    private func truncatedMenuTitle(_ name: String) -> String {
        let limit = 34
        guard name.count > limit else { return name }
        return "\(name.prefix(limit - 1))…"
    }
}

extension MenuBarView {
    /// The action's global shortcut, shown beside its menu item so it can
    /// be learnt there (design pass choice 13). Nil when cleared, or for keys
    /// a menu can't show, such as function keys.
    static func shortcut(for action: CaptureHotkeyAction) -> KeyboardShortcut? {
        guard let hotkey = CaptureHotkeyPreferences.shortcut(for: action),
              let label = hotkey.displayTokens.last else { return nil }
        let key: KeyEquivalent
        switch label {
        case "↩": key = .return
        case "⇥": key = .tab
        case "Space": key = .space
        case "⌫": key = .delete
        case "⌦": key = .deleteForward
        case "⎋": key = .escape
        case "←": key = .leftArrow
        case "→": key = .rightArrow
        case "↑": key = .upArrow
        case "↓": key = .downArrow
        default:
            guard label.count == 1, let character = label.lowercased().first else { return nil }
            key = KeyEquivalent(character)
        }
        var modifiers: EventModifiers = []
        if hotkey.modifiers.contains(.command) { modifiers.insert(.command) }
        if hotkey.modifiers.contains(.option) { modifiers.insert(.option) }
        if hotkey.modifiers.contains(.control) { modifiers.insert(.control) }
        if hotkey.modifiers.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }
}
