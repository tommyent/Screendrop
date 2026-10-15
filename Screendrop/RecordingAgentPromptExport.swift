import AppKit
import AVFoundation

@MainActor
enum RecordingAgentPromptExport {
    static func chooseDirectory(_ completion: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Export Agent Prompt"
        panel.message = "Choose where to save the prompt folder and recording stills."
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let directory = panel.url else { return }
            completion(directory)
        }
    }

    /// Uses the same on-device narration service as Studio's Transcribe Narration action.
    static func transcript(cues: [RecordingSubtitleCue], words: [RecordingTranscriptWord],
                           screenURL: URL, canTranscribe: Bool) async throws -> RecordingTranscript {
        guard cues.isEmpty, words.isEmpty, canTranscribe else { return RecordingTranscript(words: words, cues: cues) }
        do {
            return try await RecordingTranscriptionService.transcribe(screenMovieURL: screenURL)
        } catch RecordingTranscriptionService.TranscriptionError.noSpeechDetected {
            return RecordingTranscript(words: [], cues: [])
        }
    }

    static func write(session: RecordingSession, document: RecordingEditDocument?, to directory: URL,
                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let duration = try await AVURLAsset(url: session.screenURL).load(.duration).seconds
        let timeline: RecordingClipTimeline
        if let clips = document?.clips, !clips.isEmpty {
            timeline = RecordingClipTimeline(segments: clips).normalized(to: duration)
        } else {
            timeline = .legacyTrim(start: document?.trimStart, end: document?.trimEnd, sourceDuration: duration)
        }
        let title = session.displayName
        let capture = session.loadPointerCapture()
        let transcript = try await transcript(cues: document?.subtitleCues ?? [], words: document?.subtitleWords ?? [],
                                              screenURL: session.screenURL, canTranscribe: session.loadCaptureManifest()?.includesMicrophone == true)
        try Task.checkCancellation()
        let plan = RecordingAgentPromptPlan(title: title, timeline: timeline, cues: transcript.cues, words: transcript.words, capture: capture)
        let movie = try await RecordingSessionRenderer.ensureDeliverable(for: session, editDocument: document) { progress($0 * 0.8) }
        try Task.checkCancellation()
        // Studio can invalidate its cached movie while still extraction is suspended.
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(movie.pathExtension)
        try FileManager.default.copyItem(at: movie, to: snapshot)
        defer { try? FileManager.default.removeItem(at: snapshot) }
        return try await RecordingAgentPromptWriter.write(movie: snapshot, plan: plan, to: directory) { progress(0.8 + $0 * 0.2) }
    }

    static func reveal(_ directory: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(directory.path, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}
