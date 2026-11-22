//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// When the cine players of a viewer wake: their timers sleep between frames
/// and follow the speed the slider has at each tick. Times are system uptime,
/// so a correction of the civil clock does not change a playback interval.
public enum CineCadence {
    /// Seconds between two frames at `rate`; a rate with no value yet plays at 30.
    public static func frameInterval(rate: Float) -> TimeInterval {
        rate > 0 ? 1.0 / Double(rate) : 1.0 / 30
    }

    /// How late the system may fire the timer to save power: small next to a frame.
    public static func tolerance(interval: TimeInterval) -> TimeInterval {
        min(0.002, interval / 10)
    }

    /// When the frame shown at `now` was due: a timer that fired late does not
    /// slow the player, and one that lost a whole frame does not rush it.
    public static func frameTime(now: TimeInterval, lastFrame: TimeInterval, rate: Float) -> TimeInterval {
        let interval = frameInterval(rate: rate)
        return now - min(max(now - lastFrame - interval, 0), interval)
    }

    /// Seconds from `now` until the frame after `lastFrame` is due; never negative.
    public static func delay(now: TimeInterval, lastFrame: TimeInterval, rate: Float) -> TimeInterval {
        max(lastFrame + frameInterval(rate: rate) - now, 0)
    }

    /// How long a player waits for an image the load of the series has not
    /// reached yet, in seconds.
    public static let loadPatience: TimeInterval = 1

    /// How often a player that waits for the load looks again, in seconds.
    public static let loadPoll: TimeInterval = 0.02

    /// Whether a player waits before it shows its next image: while the
    /// series is `loading`, that image is not loaded yet, the player is not
    /// `aheadOfLoad` already, and less than the patience has passed since the
    /// last frame. The load decodes the images in order, so a player that
    /// follows it finds each image there; one that reaches an image the load
    /// has not decoded gives it a moment, then shows it all the same, and the
    /// image is loaded as it is shown, as a step with the arrow keys loads
    /// it. From then on the player is ahead of the load (isAheadOfLoad) and
    /// waits for none of the images that follow: a player moved to a time
    /// point the load had not reached gave every image its own moment, one
    /// image a second for as long as the load took to get there. A load that
    /// has stopped holds the player once and never stops it.
    public static func waitsForLoad(loading: Bool, nextImageLoaded: Bool, aheadOfLoad: Bool = false,
                                    now: TimeInterval, lastFrame: TimeInterval) -> Bool {
        loading && !nextImageLoaded && !aheadOfLoad && now - lastFrame < loadPatience
    }

    /// Whether a player that shows its next image now is ahead of the load:
    /// the series is `loading` and the load has not reached that image. It
    /// is behind it again at the first image it finds loaded.
    public static func isAheadOfLoad(loading: Bool, nextImageLoaded: Bool) -> Bool {
        loading && !nextImageLoaded
    }

    /// Seconds from `now` until a player's timer wakes after a tick: when the
    /// frame after `lastFrame` is due, or, when the tick `waited` for the
    /// load, at the next look. A tick that waited leaves the last frame
    /// where it was, and its frame is overdue: woken when the frame is due,
    /// the timer fired again at once, as fast as the run loop turned, for
    /// the whole wait.
    public static func delayAfterTick(now: TimeInterval, lastFrame: TimeInterval, rate: Float, waited: Bool) -> TimeInterval {
        waited ? loadPoll : delay(now: now, lastFrame: lastFrame, rate: rate)
    }

    /// Wakes `timer` when the frame after `lastFrame` is due. Not for the
    /// timer's own callback (wake(_:afterCallbackIn:delay:)).
    public static func wake(_ timer: Timer?, lastFrame: TimeInterval, rate: Float) {
        guard let timer, timer.isValid else { return }
        timer.fireDate = Date(timeIntervalSinceNow: delay(now: ProcessInfo.processInfo.systemUptime, lastFrame: lastFrame, rate: rate))
    }

    /// Wakes `timer` in `delay` seconds, asked from its own callback on the
    /// run loop it fires on, which runs it in `modes`. The fire date is set
    /// by a block of that run loop, which runs as soon as the callback has
    /// returned. A repeating timer with a tolerance whose fire date was set
    /// inside its callback was woken in the mode the run loop was in and not
    /// in its other modes: a player stood still while a control tracked the
    /// mouse or a panel was modal, and one that had fired there once could
    /// stand still in the default mode afterwards, until another timer was
    /// scheduled.
    public static func wake(_ timer: Timer?, afterCallbackIn modes: [RunLoop.Mode], delay: TimeInterval) {
        guard let timer, timer.isValid else { return }
        CFRunLoopPerformBlock(CFRunLoopGetCurrent(), modes.map(\.rawValue) as CFArray) {
            if timer.isValid { timer.fireDate = Date(timeIntervalSinceNow: max(delay, 0)) }
        }
    }
}
