//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// The cine of the slices and of the 4D frames: their timers, the speed measure and its direction, the times of the last slice and frame shown.
final class ViewerPlaybackState: @unchecked Sendable {
    /// Retained when replaced, never released by the holder (as the instance variable was).
    @ManuallyRetained var timer: Timer?
    /// Retained when replaced, never released by the holder (as the instance variable was).
    @ManuallyRetained var movieTimer: Timer?
    var speedometer: Int = 0
    var direction: Float = 0
    var lastTime: TimeInterval = 0
    var lastTimeFrame: TimeInterval = 0
    var lastMovieTime: TimeInterval = 0
}

extension ViewerController {
    var horos_timer: Timer? {
        get { playbackState.timer }
        set { playbackState.timer = newValue }
    }
    var horos_movieTimer: Timer? {
        get { playbackState.movieTimer }
        set { playbackState.movieTimer = newValue }
    }
    var horos_speedometer: Int {
        get { playbackState.speedometer }
        set { playbackState.speedometer = newValue }
    }
    var horos_direction: Float {
        get { playbackState.direction }
        set { playbackState.direction = newValue }
    }
    var horos_lastTime: TimeInterval {
        get { playbackState.lastTime }
        set { playbackState.lastTime = newValue }
    }
    var horos_lastTimeFrame: TimeInterval {
        get { playbackState.lastTimeFrame }
        set { playbackState.lastTimeFrame = newValue }
    }
    var horos_lastMovieTime: TimeInterval {
        get { playbackState.lastMovieTime }
        set { playbackState.lastMovieTime = newValue }
    }
}
