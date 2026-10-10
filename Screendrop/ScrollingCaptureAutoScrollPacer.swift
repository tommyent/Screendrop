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
///   out of time: most of a step stitched is an app scrolling a little less
///   than asked, so carry on; a smaller remainder is the end of the page.
/// - Nothing on screen changed since the step: the page didn't move. One
///   retry, then the end of the page.
/// - The view changed but nothing new was stitched: rows already captured
///   (auto-scroll started after scrolling back) or a playing video at the
///   end of the page; these can't be told apart, so allow a few.
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
    /// ponytail: re-covering rows captured before auto-scroll started stops
    /// after this many steps; the user presses again to go further.
    static let maximumUnstitchedSteps = 5

    /// One step's distance, in captured pixels.
    let stepPixels: Int
    private var postedAt: TimeInterval
    private var startHeight: Int
    private var unansweredSteps = 0
    private var unstitchedSteps = 0

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
        let hasFreshFrame = lastFrameTime > postedAt
        guard hasFreshFrame else {
            guard now - postedAt >= Self.responseTime else { return .wait }
            unansweredSteps += 1
            return unansweredSteps >= 2 ? .endOfPage : next(height: height, now: now)
        }
        unansweredSteps = 0
        if stitched >= stepPixels {
            unstitchedSteps = 0
            return next(height: height, now: now)
        }
        guard now - lastFrameTime >= Self.settleTime || now - postedAt >= Self.stepTimeout else { return .wait }
        if stitched * 2 >= stepPixels {
            unstitchedSteps = 0
            return next(height: height, now: now)
        }
        if stitched > 0 { return .endOfPage }
        unstitchedSteps += 1
        return unstitchedSteps >= Self.maximumUnstitchedSteps ? .endOfPage : next(height: height, now: now)
    }

    private mutating func next(height: Int, now: TimeInterval) -> Action {
        postedAt = now
        startHeight = height
        return .step
    }
}
