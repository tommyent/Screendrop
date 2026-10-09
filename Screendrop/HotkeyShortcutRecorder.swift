//
//  HotkeyShortcutRecorder.swift
//  Screendrop
//

import AppKit
import Carbon.HIToolbox
import Observation

@MainActor
@Observable
final class HotkeyShortcutRecorder {
    private(set) var isRecording = false
    /// Why the last keys were turned down; cleared when recording starts,
    /// stops or succeeds.
    private(set) var rejection: String?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored var onShortcutRecorded: ((HotkeyShortcut) -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func start() {
        stop()
        isRecording = true
        rejection = nil

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        isRecording = false
        rejection = nil

        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }

        if event.keyCode == UInt16(kVK_Escape) {
            cancel()
            return nil
        }

        let shortcut = HotkeyShortcut(
            modifiers: HotkeyShortcut.Modifiers(from: event.modifierFlags),
            keyCode: Int(event.keyCode)
        )
        guard shortcut.hasCommandOrControl else {
            NSSound.beep()
            rejection = "Include ⌘ or ⌃. With ⌥ or ⇧ alone, the keys type a character in other apps."
            return nil
        }

        finish(with: shortcut)
        return nil
    }

    private func finish(with shortcut: HotkeyShortcut) {
        onShortcutRecorded?(shortcut)
        stop()
    }

    private func cancel() {
        onCancel?()
        stop()
    }
}
