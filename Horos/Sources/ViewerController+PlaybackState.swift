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

extension ViewerController {
    /// The cine of this viewer, for one call: the players, their speeds and
    /// their timers.
    var cine: CinePlayback {
        CinePlayback(viewer: self, preferences: sessionGraph.preferences)
    }

    var horos_timer: Timer? {
        get { _timer.wrappedValue }
        set { _timer.wrappedValue = newValue }
    }
    var horos_movieTimer: Timer? {
        get { _movieTimer.wrappedValue }
        set { _movieTimer.wrappedValue = newValue }
    }
    var horos_speedometer: Int {
        get { _speedometer }
        set { _speedometer = newValue }
    }
    var horos_direction: Float {
        get { _direction }
        set { _direction = newValue }
    }
    var horos_lastTime: TimeInterval {
        get { _lastTime }
        set { _lastTime = newValue }
    }
    var horos_lastTimeFrame: TimeInterval {
        get { _lastTimeFrame }
        set { _lastTimeFrame = newValue }
    }
    var horos_lastMovieTime: TimeInterval {
        get { _lastMovieTime }
        set { _lastMovieTime = newValue }
    }
}
