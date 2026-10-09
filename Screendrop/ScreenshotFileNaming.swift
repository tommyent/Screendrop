//
//  ScreenshotFileNaming.swift
//  Screendrop
//

import Foundation

/// Names for captures where the user sees them, in the user's pattern:
/// `screenshot_2026-10-09_055530.png` and `recording_2026-10-09_055530.mov`.
/// A same-second clash becomes `_2`, `_3` and so on; an existing file is
/// never overwritten. Files already saved keep their names, and internal
/// packages and fallbacks (`Screendrop_<uuid>` and so on) keep theirs.
enum ScreenshotFileNaming {
    static func fileName(date: Date = Date(), extension pathExtension: String = "png") -> String {
        "screenshot_\(timestamp(date)).\(pathExtension)"
    }

    static func recordingFileName(date: Date, extension pathExtension: String) -> String {
        "recording_\(timestamp(date)).\(pathExtension)"
    }

    /// `fileName` in `directory`, or the first free of `name_2`, `name_3`…
    static func uniqueURL(for fileName: String, in directory: URL, fileManager: FileManager = .default) -> URL {
        let first = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: first.path) else { return first }

        let baseName = first.deletingPathExtension().lastPathComponent
        let pathExtension = first.pathExtension
        func named(_ suffix: String) -> URL {
            let name = baseName + "_" + suffix
            return directory.appendingPathComponent(pathExtension.isEmpty ? name : "\(name).\(pathExtension)")
        }
        for index in 2...10_000 {
            let candidate = named(String(index))
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return named(UUID().uuidString)
    }

    static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    /// Fixed, whatever the user's locale and calendar: a Buddhist or 12-hour
    /// setting must not change a file name. Local wall-clock time.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()
}
