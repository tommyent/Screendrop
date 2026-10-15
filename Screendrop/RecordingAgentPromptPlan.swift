import Foundation

nonisolated struct RecordingAgentPromptPlan: Sendable {
    struct Text: Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    struct Moment: Sendable {
        var time: TimeInterval
        var evidence: [String]
    }

    let title: String
    let duration: TimeInterval
    let transcript: [Text]
    let words: [Text]
    let moments: [Moment]
    let hasInput: Bool

    init(title: String, timeline: RecordingClipTimeline, cues: [RecordingSubtitleCue],
         words: [RecordingTranscriptWord], capture: PointerCaptureFile?) {
        self.title = title
        duration = timeline.duration
        hasInput = capture != nil

        func mapped(_ start: Double, _ end: Double, text: String) -> Text? {
            guard start.isFinite, end.isFinite, end > start else { return nil }
            let slices = timeline.slices(overlapping: start, sourceEnd: end)
            let kept = slices.reduce(0) { $0 + $1.sourceEnd - $1.sourceStart }
            // Never quote words removed by a cut, including a word cut in half.
            guard abs(kept - (end - start)) < 0.000_001,
                  let first = slices.first, let last = slices.last else { return nil }
            return Text(start: first.editorStart, end: last.editorEnd, text: text)
        }

        self.words = words.compactMap { mapped($0.start, $0.end, text: $0.displayText) }
            .sorted { $0.start < $1.start }
        var narration: [Text] = []
        for cue in cues where cue.start.isFinite && cue.end.isFinite && cue.end > cue.start {
            if let full = mapped(cue.start, cue.end, text: cue.text) {
                narration.append(full)
                continue
            }
            let slices = timeline.slices(overlapping: cue.start, sourceEnd: cue.end)
            guard let first = slices.first, let last = slices.last else { continue }
            let timed = words.filter { $0.start >= cue.start && $0.start < cue.end }
                .sorted { $0.start < $1.start }
            let corrected = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
            if !timed.isEmpty, timed.count == corrected.count {
                narration += zip(timed, corrected).compactMap { word, text in
                    mapped(word.start, word.end, text: text)
                }
            } else {
                // shortcut: changed word counts have no reliable corrected timing; retain only surviving recognizer words until word-level corrections exist.
                let surviving = timed.compactMap { mapped($0.start, $0.end, text: $0.displayText) }
                let text = surviving.isEmpty
                    ? "[Partially cut caption: surviving wording unavailable without word timings.]"
                    : "[Partially cut caption: surviving recognizer wording; corrected word timing unavailable.] "
                        + surviving.map(\.text).joined(separator: " ")
                narration.append(Text(start: first.editorStart, end: last.editorEnd, text: text))
            }
        }
        transcript = narration.sorted { $0.start < $1.start }

        var evidence = transcript.map {
            (time: $0.start, text: "Narration \(Self.timestamp($0.start))–\(Self.timestamp($0.end)): \(Self.escape($0.text))")
        }
        func actionTime(_ source: Double) -> Double? {
            guard source.isFinite,
                  timeline.segments.contains(where: { source >= $0.sourceStart && source < $0.sourceEnd }) else { return nil }
            return timeline.editorTime(forSourceTime: source)
        }
        for click in capture?.presses ?? [] where click.phase == .down {
            guard click.x.isFinite, click.y.isFinite,
                  (0...1).contains(click.x), (0...1).contains(click.y),
                  let time = actionTime(click.time) else { continue }
            let button = click.button == 0 ? "left" : click.button == 1 ? "right" : "button \(click.button)"
            let position = String(format: "x=%.3f, y=%.3f", locale: Locale(identifier: "en_US_POSIX"), click.x, click.y)
            evidence.append((time, "Click \(Self.timestamp(time)): \(button); source position \(position)."))
        }
        for key in capture?.keystrokes ?? [] {
            guard let time = actionTime(key.time) else { continue }
            evidence.append((time, "Shortcut \(Self.timestamp(time)): \(Self.escape(key.modifiers.joined() + key.key))."))
        }
        let sorted = evidence.enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
        var grouped: [Moment] = []
        for event in sorted {
            if let last = grouped.last, event.time - last.time <= 0.5 {
                grouped[grouped.count - 1].evidence.append(event.text)
            } else {
                grouped.append(Moment(time: event.time, evidence: [event.text]))
            }
        }
        moments = grouped.isEmpty ? [Moment(time: 0, evidence: ["No timed narration or actions available."])] : grouped
    }

    func markdown(frameTimes: [TimeInterval]) -> String {
        var text = "# \(Self.escape(title.split(whereSeparator: \.isWhitespace).joined(separator: " ")))\n\n"
        text += "Use this recorded walkthrough and its evidence as task context.\n\n"
        text += "Times refer to the edited recording (\(Self.timestamp(duration))). Click coordinates are normalized to the captured source, with a top-left origin; crop and zoom can move them in the stills. Plain typing and control names were not recorded.\n\n"
        if !hasInput { text += "No input log is available for this recording.\n\n" }
        for (index, moment) in moments.enumerated() {
            text += "## Moment \(index + 1) — \(Self.timestamp(moment.time))\n\n"
            text += moment.evidence.joined(separator: "\n\n") + "\n\n"
            if frameTimes.indices.contains(index) {
                text += "![Frame at \(Self.timestamp(frameTimes[index]))](stills/\(Self.stillName(index)))\n\n"
            } else {
                text += "Frame unavailable.\n\n"
            }
        }
        text += "## Transcript\n\n"
        text += transcript.isEmpty ? "No narration available.\n" : transcript.map {
            "- \(Self.timestamp($0.start))–\(Self.timestamp($0.end)): \(Self.escape($0.text))"
        }.joined(separator: "\n") + "\n"
        if !words.isEmpty {
            text += "\n## Word Timings\n\nOriginal recognizer wording and timing, mapped to the edited recording. Caption corrections may differ. Words intersected by cuts are omitted.\n\n| Start | End | Word |\n| --- | --- | --- |\n"
            text += words.map {
                "| \(Self.timestamp($0.start)) | \(Self.timestamp($0.end)) | \(Self.escape($0.text)) |"
            }.joined(separator: "\n") + "\n"
        }
        return text
    }

    static func stillName(_ index: Int) -> String { String(format: "%04d.jpg", index + 1) }

    static func timestamp(_ time: TimeInterval) -> String {
        let ms = Int((max(0, time.isFinite ? time : 0) * 1000).rounded())
        return String(format: "%02d:%02d.%03d", ms / 60_000, ms / 1000 % 60, ms % 1000)
    }

    private static func escape(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        for character in ["\\", "`", "*", "_", "[", "]", "|", "#", "!"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result.components(separatedBy: .newlines).joined(separator: " ")
    }
}
