//
//  ScrollingCaptureAutoScrollPacer.swift
//  Screendrop
//

import Foundation

/// Decides when auto-scroll posts its next step and when the page has run
/// out, from the stitched height and the newest stream frame's display time.
/// Free of events and timers, so the pacing is checked on its own.
///
/// One step is in flight at a time, and nothing happens until a frame shown
/// after the step has reached the engine. The scroll amount never places
/// rows: progress is only what the engine stitched.
///
/// - A full step stitched: post the next one.
/// - The view went still (no new frame for `settleTime`), or the step ran
///   out of time: anything stitched is progress (an app scrolling less than
///   asked, or the last of the page), so carry on. The end of the page ends
///   the capture, so a step that moved, however little, never counts as it.
/// - Nothing on screen changed since the step (the page didn't move), or the
///   frames since it were placed without moving (a playing video at the end
///   of the page): they share one budget. At most
///   `maximumStepsWithoutProgress` steps are ever posted since the last
///   stitched progress, then the page has ended. Frames that don't fit never
///   count: the caller stops pacing on one, so the end of the page only
///   follows steps whose frames were placed.
nonisolated struct AutoScrollPacer: Equatable {
    enum Action: Equatable {
        /// The step is still under way.
        case wait
        /// Post the next step now.
        case step
        /// The page has run out.
        case endOfPage
    }

    /// No new frame for this long means the view has stopped moving. Longer
    /// than the engine's 100 ms rest look, so its last placement is in.
    static let settleTime: TimeInterval = 0.4
    /// A step whose view keeps changing (a playing video) is judged by what
    /// it stitched after this long.
    static let stepTimeout: TimeInterval = 1.5
    /// A step after which nothing on screen changed counts as unanswered.
    static let responseTime: TimeInterval = 1
    /// Steps posted since the last stitched progress, the one in flight
    /// included: two quarter-region steps keep the view within half a region
    /// of what was stitched. Five carried the page a region and a quarter
    /// past it on a playing video that blocks registration (VM, 2026-10-10).
    /// ponytail: re-covering rows captured before auto-scroll started would
    /// end the capture after this too; the stitcher trims the output when the
    /// view moves back up, so re-covered rows are appended again instead.
    static let maximumStepsWithoutProgress = 2

    /// One step's distance, in captured pixels.
    let stepPixels: Int
    private var postedAt: TimeInterval
    private var startHeight: Int
    private var stepsWithoutProgress = 1

    /// Starts pacing with the first step posted at `now`, at this height.
    /// Times are the stream's clock (`ScrollingCaptureSampleTiming.now()`).
    init(stepPixels: Int, height: Int, now: TimeInterval) {
        self.stepPixels = max(1, stepPixels)
        postedAt = now
        startHeight = height
    }

    /// Takes the stitched height and the display time of the newest frame
    /// the engine has seen. On `.step` the caller posts the next step now.
    mutating func update(height: Int, lastFrameTime: TimeInterval, now: TimeInterval) -> Action {
        let stitched = height - startHeight
        guard lastFrameTime > postedAt else {
            guard now - postedAt >= Self.responseTime else { return .wait }
            return noProgress(height: height, now: now)
        }
        if stitched >= stepPixels { return progress(height: height, now: now) }
        guard now - lastFrameTime >= Self.settleTime || now - postedAt >= Self.stepTimeout else { return .wait }
        return stitched > 0 ? progress(height: height, now: now) : noProgress(height: height, now: now)
    }

    private mutating func progress(height: Int, now: TimeInterval) -> Action {
        stepsWithoutProgress = 1
        return post(height: height, now: now)
    }

    private mutating func noProgress(height: Int, now: TimeInterval) -> Action {
        guard stepsWithoutProgress < Self.maximumStepsWithoutProgress else { return .endOfPage }
        stepsWithoutProgress += 1
        return post(height: height, now: now)
    }

    private mutating func post(height: Int, now: TimeInterval) -> Action {
        postedAt = now
        startHeight = height
        return .step
    }
}
