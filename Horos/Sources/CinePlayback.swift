/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXImaging
import IsiXPreferences

// The cine of a 2D viewer: the "Browse" player that steps through the images
// of the series at the speed slider's rate, its toolbar item and its speed
// text, and the 4D player that steps through the time points at the 4D speed
// with its button; the speed sliders, which the key viewer hands to the other
// viewers still at the default speed; and the wait of both players while less
// than half of the series is loaded. The timers fire the viewer's selectors
// -performAnimation: and -performMovieAnimation:, the former Objective-C ones,
// and the state of the players is the viewer's ViewerPlaybackState. Which image
// or time point comes next is IsiXImaging's SliceNavigation.

/// The cine of one 2D viewer, made for one call.
@MainActor final class CinePlayback {
    /// Held strongly for the length of a call: forming an unowned or weak
    /// reference to an object being deallocated traps.
    let viewer: ViewerController
    /// The preferences of the default speeds.
    private let preferences: any PreferenceStore

    private static let playItemImage = "Play.pdf"
    private static let pauseItemImage = "Pause.pdf"

    init(viewer: ViewerController, preferences: any PreferenceStore) {
        self.viewer = viewer
        self.preferences = preferences
    }

    /// The "Browse" player's timer, which plugins read as the viewer's `timer`.
    var timer: Timer? {
        viewer.horos_timer
    }

    /// Whether the 4D player plays.
    var isPlaying4D: Bool {
        viewer.horos_movieTimer != nil
    }

    // MARK: - The speeds

    /// The "Browse" player's speed, in images per second.
    var frameRate: Float {
        viewer.horos_speedSlider?.floatValue ?? 0
    }

    /// The 4D player's speed, in frames per second.
    var movieRate: Float {
        viewer.horos_movieRateSlider?.floatValue ?? 0
    }

    /// The speed slider moved: shows the speed, and when this is the key
    /// window hands it to the other viewers still at the default speed, which
    /// it becomes.
    func speedChanged() {
        viewer.horos_speedText?.stringValue = Self.imagesPerSecond(Double(frameRate * viewer.horos_direction))
        CineCadence.wake(viewer.horos_timer, lastFrame: viewer.horos_lastTime, rate: frameRate)

        guard viewer.window?.isKeyWindow ?? false else { return }
        let rate = frameRate
        let defaultRate = preferences[ViewerPreferences.defaultFrameRate]
        for case let other as ViewerController in ViewerController.getDisplayed2DViewers() where other != viewer {
            if other.frameRate() == defaultRate && other.speedSlider.floatValue != rate {
                other.speedSlider.floatValue = rate
                other.speedText.stringValue = Self.imagesPerSecond(Double(rate * other.horos_direction))
            }
        }
        preferences.set(rate, for: ViewerPreferences.defaultFrameRate)
    }

    /// The 4D speed slider moved: shows the speed, and when this is the key
    /// window hands it to the other viewers still at the default speed, which
    /// it becomes.
    func movieRateChanged() {
        let rate = movieRate
        viewer.horos_movieTextSlide?.stringValue = Self.framesPerSecond(rate)
        CineCadence.wake(viewer.horos_movieTimer, lastFrame: viewer.horos_lastMovieTime, rate: rate)

        guard viewer.window?.isKeyWindow ?? false else { return }
        let defaultRate = preferences[ViewerPreferences.defaultMovieRate]
        for case let other as ViewerController in ViewerController.getDisplayed2DViewers() where other != viewer {
            if other.movieRate() == defaultRate && other.movieRateSlider.floatValue != rate {
                other.movieRateSlider.floatValue = rate
                other.movieTextSlide.stringValue = Self.framesPerSecond(rate)
            }
        }
        preferences.set(rate, for: ViewerPreferences.defaultMovieRate)
    }

    private static func imagesPerSecond(_ rate: Double) -> String {
        String(format: NSLocalizedString("%0.1f im/s", comment: "im/s = images per second"), rate)
    }

    private static func framesPerSecond(_ rate: Float) -> String {
        String(format: NSLocalizedString("%0.0f im/s", comment: "im/s = images per second"), Double(rate))
    }

    // MARK: - The timers

    /// A player's timer, which sleeps between frames. It stays a repeating
    /// Timer for as long as the player plays: plugins read that it is not nil.
    private func playerTimer(rate: Float, selector: Selector) -> Timer {
        let interval = CineCadence.frameInterval(rate: rate)
        let timer = Timer.scheduledTimer(timeInterval: interval, target: viewer, selector: selector, userInfo: nil, repeats: true)
        timer.tolerance = CineCadence.tolerance(interval: interval)
        RunLoop.current.add(timer, forMode: .modalPanel)
        RunLoop.current.add(timer, forMode: .eventTracking)
        return timer
    }

    // MARK: - The "Browse" player

    /// One tick of the "Browse" player's timer: shows the speed once a second
    /// and, at the slider's speed, the next image (looping, or bouncing off
    /// the ends). It waits while less than half the series is loaded.
    func advanceSlice() {
        // Playback intervals must not change when the civil clock is corrected.
        let thisTime = ProcessInfo.processInfo.systemUptime
        defer { CineCadence.wake(viewer.horos_timer, lastFrame: viewer.horos_lastTime, rate: viewer.horos_speedSlider?.floatValue ?? 0) }

        if viewer.horos_windowWillClose { return }
        if isLoadingFirstHalf() { return }

        let count = viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0
        if count <= 1 { return }

        if thisTime - viewer.horos_lastTimeFrame > 1.0 {
            viewer.horos_speedText?.stringValue = Self.imagesPerSecond(Double(Float(viewer.horos_speedometer) * viewer.horos_direction) / (thisTime - viewer.horos_lastTimeFrame))
            viewer.horos_speedometer = 0
            viewer.horos_lastTimeFrame = thisTime
        }

        if thisTime - viewer.horos_lastTime > 1.0 / Double(viewer.horos_speedSlider?.floatValue ?? 0) {
            guard let imageView = viewer.horos_imageView else { return }
            let step = SliceNavigation.browseStep(from: imageView.stackNavigation, direction: viewer.horos_direction, flipped: imageView.flippedData,
                                                  count: count, loops: viewer.horos_loopButton?.state == .on)
            viewer.horos_direction = step.direction

            imageView.setIndex(step.image)
            viewer.adjustSlider()
            imageView.sendSyncMessage(0)

            viewer.horos_lastTime = CineCadence.frameTime(now: thisTime, lastFrame: viewer.horos_lastTime, rate: viewer.horos_speedSlider?.floatValue ?? 0)

            imageView.displayIfNeeded()
            viewer.horos_speedometer += 1
        }
    }

    /// The "Browse" toolbar item `sender`: starts the player (stopping the
    /// other viewers'), or stops it.
    func toggleSlices(_ sender: Any?) {
        let item = sender as? NSToolbarItem
        if let timer = viewer.horos_timer {
            timer.invalidate()
            viewer.horos_timer = nil

            item?.image = NSImage.toolbarImageNamed(Self.playItemImage)
            item?.label = NSLocalizedString("Browse", comment: "")
            item?.paletteLabel = NSLocalizedString("Browse", comment: "")
            item?.toolTip = NSLocalizedString("Browse this series", comment: "")

            viewer.horos_speedText?.stringValue = Self.imagesPerSecond(Double(frameRate * viewer.horos_direction))
        } else {
            postViewerNotification(.OsirixStopPlaying, viewer)

            viewer.horos_timer = playerTimer(rate: frameRate, selector: #selector(ViewerController.performAnimation(_:)))

            viewer.horos_lastTime = ProcessInfo.processInfo.systemUptime
            viewer.horos_lastTimeFrame = ProcessInfo.processInfo.systemUptime

            item?.image = NSImage.toolbarImageNamed(Self.pauseItemImage)
            item?.label = NSLocalizedString("Stop", comment: "")
            item?.paletteLabel = NSLocalizedString("Stop", comment: "")
        }
    }

    /// Another viewer started its "Browse" player: this one stops.
    func stopForOtherPlayer() {
        if viewer.horos_timer != nil { toggleSlices(viewer.findPlayStopButton()) }
    }

    // MARK: - The 4D player

    /// One tick of the 4D player's timer: the next time point at the 4D
    /// speed, handed on to the other viewers. It waits while less than half
    /// the series is loaded.
    func advanceMovie() {
        // Playback intervals must not change when the civil clock is corrected.
        let thisTime = ProcessInfo.processInfo.systemUptime
        defer { CineCadence.wake(viewer.horos_movieTimer, lastFrame: viewer.horos_lastMovieTime, rate: viewer.horos_movieRateSlider?.floatValue ?? 0) }

        if isLoadingFirstHalf() { return }

        if thisTime - viewer.horos_lastMovieTime > 1.0 / Double(viewer.horos_movieRateSlider?.floatValue ?? 0) {
            let frames = SliceNavigation(movieIndex: Int(viewer.horos_curMovieIndex), movieCount: Int(viewer.horos_maxMovieIndex))
            let next = Int16(truncatingIfNeeded: frames.nextMovieIndex)

            viewer.horos_curMovieIndex = next

            viewer.setMovieIndex(next)
            viewer.propagateSettings()

            viewer.horos_lastMovieTime = CineCadence.frameTime(now: thisTime, lastFrame: viewer.horos_lastMovieTime, rate: viewer.horos_movieRateSlider?.floatValue ?? 0)
        }
    }

    /// Stops the 4D player and shows the button and speed of a stopped one.
    func stopMovie() {
        if let timer = viewer.horos_movieTimer {
            timer.invalidate()
            viewer.horos_movieTimer = nil
        }

        // Every way of stopping - the button, opening a 3D viewer, another
        // viewer starting to play - puts the button back to "Play".
        viewer.horos_moviePlayStop?.title = NSLocalizedString("Play", comment: "")
        viewer.horos_movieTextSlide?.stringValue = Self.framesPerSecond(viewer.horos_movieRateSlider?.floatValue ?? 0)
    }

    /// The 4D player's button: stops it, or starts it (stopping every other
    /// viewer's) once the series is loaded.
    func toggleMovie() {
        if viewer.horos_movieTimer != nil {
            stopMovie()
            return
        }

        for window in NSApp.windows {
            if let other = window.windowController as? ViewerController {
                other.movieStop(viewer)
            }
        }

        viewer.checkEverythingLoaded()

        viewer.horos_movieTimer = playerTimer(rate: movieRate, selector: #selector(ViewerController.performMovieAnimation(_:)))

        viewer.horos_lastMovieTime = ProcessInfo.processInfo.systemUptime

        viewer.horos_moviePlayStop?.title = NSLocalizedString("Stop", comment: "")
    }

    // MARK: - The wait

    /// Whether the series is still loading and less than half of it is there:
    /// the players wait.
    func isLoadingFirstHalf() -> Bool {
        guard let thread = viewer.horos_loadingThread else { return false }
        objc_sync_enter(thread)
        defer { objc_sync_exit(thread) }
        let percentage = (thread.threadDictionary.object(forKey: "loadingPercentage") as? NSNumber)?.floatValue ?? 0
        return !thread.isFinished && percentage < 0.5
    }
}
