//
//  CaptureHotkeySettingsSection.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// Every capture shortcut in one place (design pass choice 12): click the
/// keys to record a new shortcut, Reset brings back one default, Clear
/// removes a shortcut, and Restore Defaults resets them all.
struct CaptureHotkeySettingsSection: View {
    let actions: [CaptureHotkeyAction]

    @State private var shortcuts = CaptureHotkeyPreferences.shortcuts()
    @State private var recorder = HotkeyShortcutRecorder()
    @State private var recordingAction: CaptureHotkeyAction?
    @State private var errorMessage: String?

    var body: some View {
        Section {
            ForEach(actions) { action in
                LabeledContent(action.title) {
                    HStack(spacing: DS.Space.m) {
                        shortcutField(for: action)

                        // Hidden rather than removed while it has nothing to
                        // undo, so the rows' buttons stay lined up.
                        Button("Reset") { apply(action.defaultShortcut, to: action) }
                            .controlSize(.small)
                            .opacity(isDefault(action) ? 0 : 1)
                            .disabled(isDefault(action))
                            .accessibilityHidden(isDefault(action))
                            .help("Use the default shortcut, \(action.defaultShortcut.displayString)")

                        Button("Clear") { apply(nil, to: action) }
                            .controlSize(.small)
                            .disabled(shortcuts[action] == nil)
                            .help("Remove this shortcut")
                    }
                }
            }

            messages
        } header: {
            HStack {
                Text("Keyboard Shortcuts")
                Spacer()
                Button("Restore Defaults", action: restoreDefaults)
                    .controlSize(.small)
                    .disabled(actions.allSatisfy(isDefault))
            }
        }
        .onAppear {
            reloadShortcuts()
            configureRecorder()
        }
        .onDisappear {
            recorder.stop()
            recordingAction = nil
        }
    }

    /// The keys themselves are the control: a click records new ones.
    private func shortcutField(for action: CaptureHotkeyAction) -> some View {
        Button {
            toggleRecording(for: action)
        } label: {
            Group {
                if isRecording(action) {
                    Text("Type Shortcut…")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, DS.Space.s)
                        .frame(minHeight: 21)
                        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else if let shortcut = shortcuts[action] {
                    HotkeyShortcutDisplay(shortcut: shortcut)
                } else {
                    Text("None")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DS.Space.s)
                        .frame(minHeight: 21)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isRecording(action) ? "Type the new shortcut, or press Esc to cancel" : "Click to record a new shortcut")
        .accessibilityLabel("\(action.title) shortcut")
        .accessibilityValue(isRecording(action) ? "Recording" : shortcuts[action]?.displayString ?? "None")
        .accessibilityHint("Records a new shortcut")
    }

    @ViewBuilder
    private var messages: some View {
        if let rejection = recorder.rejection {
            Text(rejection)
                .font(.caption)
                .foregroundStyle(.red)
        } else if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
        }

        ForEach(actions) { action in
            if let failure = HotkeyManager.shared.registrationErrors[action] {
                Text("\(action.title): \(failure)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }

        if recordingAction != nil, recorder.rejection == nil {
            Text("Type the new shortcut, with ⌘ or ⌃. Press Esc to cancel.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func isDefault(_ action: CaptureHotkeyAction) -> Bool {
        _ = shortcuts  // re-read after every change
        return CaptureHotkeyPreferences.isDefault(action)
    }

    private func isRecording(_ action: CaptureHotkeyAction) -> Bool {
        recorder.isRecording && recordingAction == action
    }

    private func toggleRecording(for action: CaptureHotkeyAction) {
        errorMessage = nil

        if isRecording(action) {
            recorder.stop()
            recordingAction = nil
            return
        }

        recordingAction = action
        recorder.start()
    }

    private func configureRecorder() {
        recorder.onShortcutRecorded = { shortcut in
            guard let recordingAction else { return }
            apply(shortcut, to: recordingAction)
        }

        recorder.onCancel = {
            recordingAction = nil
        }
    }

    /// Nil clears the action.
    private func apply(_ shortcut: HotkeyShortcut?, to action: CaptureHotkeyAction) {
        if let shortcut, let conflict = CaptureHotkeyPreferences.conflictingAction(for: shortcut, excluding: action) {
            errorMessage = "\(shortcut.displayString) is already assigned to \(conflict.title)."
            NSSound.beep()
            recorder.stop()
            recordingAction = nil
            return
        }

        do {
            try HotkeyManager.shared.setShortcut(shortcut, for: action)
            shortcuts[action] = shortcut
            errorMessage = nil
        } catch {
            errorMessage = "\(error.localizedDescription) Your previous shortcut has been kept."
            NSSound.beep()
        }
        recordingAction = nil
    }

    private func restoreDefaults() {
        recorder.stop()
        recordingAction = nil
        errorMessage = nil
        HotkeyManager.shared.restoreDefaults(for: actions)
        reloadShortcuts()
    }

    private func reloadShortcuts() {
        shortcuts = CaptureHotkeyPreferences.shortcuts(for: actions)
    }
}

private struct HotkeyShortcutDisplay: View {
    let shortcut: HotkeyShortcut

    var body: some View {
        HStack(spacing: 3) {
            ForEach(shortcut.displayTokens, id: \.self) { token in
                HotkeyKeyCap(token: token)
            }
        }
        // One element that reads the whole shortcut. A label on the bare
        // stack made SwiftUI resolve it through its own keycaps and recurse
        // until the stack overflowed whenever an accessibility client
        // (VoiceOver, an automation tool) read Settings › Screenshots.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.displayString)
    }
}

private struct HotkeyKeyCap: View {
    let token: String

    var body: some View {
        Text(token)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .monospacedDigit()
            .frame(minWidth: 22, minHeight: 21)
            .padding(.horizontal, token.count > 1 ? 6 : 0)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.separator.opacity(0.35))
            }
    }
}
