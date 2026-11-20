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

    /// Whether a player waits before it shows its next image: while the
    /// series is `loading`, that image is not loaded yet, and less than the
    /// patience has passed since the last frame. The load decodes the images
    /// in order, so a player that follows it finds each image there; one that
    /// reaches an image the load has not decoded gives it a moment, then
    /// shows it all the same, and the image is loaded as it is shown, as a
    /// step with the arrow keys loads it. A load that has stopped slows the
    /// player down and never stops it.
    public static func waitsForLoad(loading: Bool, nextImageLoaded: Bool, now: TimeInterval, lastFrame: TimeInterval) -> Bool {
        loading && !nextImageLoaded && now - lastFrame < loadPatience
    }

    /// Wakes `timer` when the frame after `lastFrame` is due.
    public static func wake(_ timer: Timer?, lastFrame: TimeInterval, rate: Float) {
        guard let timer, timer.isValid else { return }
        timer.fireDate = Date(timeIntervalSinceNow: delay(now: ProcessInfo.processInfo.systemUptime, lastFrame: lastFrame, rate: rate))
    }
}
