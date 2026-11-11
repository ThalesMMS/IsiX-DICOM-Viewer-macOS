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

    /// Wakes `timer` when the frame after `lastFrame` is due.
    public static func wake(_ timer: Timer?, lastFrame: TimeInterval, rate: Float) {
        guard let timer, timer.isValid else { return }
        timer.fireDate = Date(timeIntervalSinceNow: delay(now: ProcessInfo.processInfo.systemUptime, lastFrame: lastFrame, rate: rate))
    }
}
