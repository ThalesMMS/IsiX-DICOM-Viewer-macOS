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

// The "Series navigation" block of ViewerController (4.4.1): the slices and
// files of each movie frame, the image shown (as the user counts it: a flipped
// series is shown from its last image), the strip slider, and the "Browse"
// player that steps through the series. Which image a request or a step lands
// on is IsiXImaging's SeriesBrowsing. The 4D player is in
// ViewerController+FourDNavigation.swift. The selectors are those of the former
// Objective-C methods.

fileprivate let PlayToolbarItemIdentifier = "Play.pdf"
fileprivate let PauseToolbarItemIdentifier = "Pause.pdf"

public extension ViewerController {

    // The lists of the movie frames: read from any thread, as before.

    /// The slices of movie frame `i` (wrapped into the frames there are).
    @objc(pixList:)
    nonisolated func pixList(_ i: Int) -> NSMutableArray! {
        let index = FourDSeriesGuard.wrappedIndex(i, count: Int(horos_maxMovieIndex))
        return horos_pixList(at: index)
    }

    /// The slices of the current movie frame (OSIWindowController's, for a 2D viewer).
    @objc(pixList)
    override nonisolated func pixList() -> NSMutableArray! {
        return horos_pixList(at: Int(horos_curMovieIndex))
    }

    /// The files of the current movie frame.
    @objc(fileList)
    nonisolated func fileList() -> NSMutableArray! {
        return horos_fileList(at: Int(horos_curMovieIndex))
    }

    /// The files of movie frame `i` (wrapped into the frames there are).
    @objc(fileList:)
    nonisolated func fileList(_ i: Int) -> NSMutableArray! {
        let index = FourDSeriesGuard.wrappedIndex(i, count: Int(horos_maxMovieIndex))
        return horos_fileList(at: index)
    }

    /// The "Browse" player's speed, in images per second.
    @objc(frameRate)
    func frameRate() -> Float {
        return horos_speedSlider?.floatValue ?? 0
    }

    /// The speed slider: shows the speed, and when this is the key window hands
    /// it to the other viewers still at the default speed, which it becomes.
    @objc(speedSliderAction:)
    func speedSliderAction(_ sender: Any!) {
        horos_speedText?.stringValue = String(format: NSLocalizedString("%0.1f im/s", comment: "im/s = images per second"), Double(frameRate() * horos_direction))

        guard window?.isKeyWindow ?? false else { return }
        let defaults = UserDefaults.standard
        for case let viewer as ViewerController in ViewerController.getDisplayed2DViewers() where viewer != self {
            if viewer.frameRate() == defaults.float(forKey: "defaultFrameRate") && viewer.speedSlider.floatValue != frameRate() {
                viewer.speedSlider.floatValue = frameRate()
                viewer.speedText.stringValue = String(format: NSLocalizedString("%0.1f im/s", comment: "im/s = images per second"), Double(frameRate() * viewer.horos_direction))
            }
        }
        defaults.set(frameRate(), forKey: "defaultFrameRate")
    }

    /// The strip slider and the key image button, for the image shown.
    @objc(adjustSlider)
    func adjustSlider() {
        if let imageView = horos_imageView {
            let count = horos_pixList(at: Int(horos_curMovieIndex))?.count ?? 0
            horos_slider?.intValue = SeriesBrowsing.sliderValue(forViewImage: Int(imageView.curImage), count: count, flipped: imageView.flippedData)
        } else {
            horos_slider?.intValue = 0
        }
        // A thick slab runs from the current image towards the end of the strip,
        // flipped data or not: the strip is flipped with the data.
        if let slider = horos_slider as? ImageNavigationSlider {
            slider.slabImageCount = max(Int(horos_imageView?.curDCM?.stack ?? 0), 1)
        }

        adjustKeyImage()
    }

    /// The image shown, as the user counts it.
    @objc(imageIndex)
    func imageIndex() -> Int {
        guard let imageView = horos_imageView else { return 0 }
        return SeriesBrowsing.userIndex(ofViewImage: Int(imageView.curImage), count: Int(getNumberOfImages()), flipped: imageView.flippedData)
    }

    /// Shows image `i` as the user counts it (clamped to the series), and
    /// synchronizes the other viewers.
    @objc(setImageIndex:)
    func setImageIndex(_ i: Int) {
        guard let imageView = horos_imageView else {
            adjustSlider()
            return
        }
        let image = SeriesBrowsing.viewImage(forIndex: i, count: Int(getNumberOfImages()), flipped: imageView.flippedData)
        imageView.setIndex(Int(truncatingIfNeeded: image))
        imageView.sendSyncMessage(0)
        adjustSlider()
        imageView.displayIfNeeded()
    }

    /// Shows `image`, in whichever movie frame has it.
    @objc(setImage:)
    func setImage(_ image: NSManagedObject!) {
        for x in 0..<horos_movieCount {
            guard let files = horos_fileList(at: x) else { continue }
            for case let file as NSManagedObject in files where file === image {
                setMovieIndex(Int16(truncatingIfNeeded: x))
                horos_imageView?.setIndex(files.index(of: file))
                horos_imageView?.sendSyncMessage(0)
                adjustSlider()
                horos_imageView?.displayIfNeeded()
                return
            }
        }
    }

    /// One tick of the "Browse" player's timer: shows the speed once a second
    /// and, at the slider's speed, the next image (looping, or bouncing off
    /// the ends). It waits while less than half the series is loaded.
    @objc(performAnimation:)
    func performAnimation(_ sender: Any!) {
        // Playback intervals must not change when the civil clock is corrected.
        let thisTime = ProcessInfo.processInfo.systemUptime

        if horos_windowWillClose { return }
        if isLoadingFirstHalf() { return }

        let count = horos_pixList(at: Int(horos_curMovieIndex))?.count ?? 0
        if count <= 1 { return }

        if thisTime - horos_lastTimeFrame > 1.0 {
            horos_speedText?.stringValue = String(format: NSLocalizedString("%0.1f im/s", comment: "im/s = images per second"),
                                                  Double(Float(horos_speedometer) * horos_direction) / (thisTime - horos_lastTimeFrame))
            horos_speedometer = 0
            horos_lastTimeFrame = thisTime
        }

        if thisTime - horos_lastTime > 1.0 / Double(horos_speedSlider?.floatValue ?? 0) {
            guard let imageView = horos_imageView else { return }
            let step = SeriesBrowsing.step(from: imageView.curImage, direction: horos_direction, flipped: imageView.flippedData,
                                           count: count, loops: horos_loopButton?.state == .on)
            horos_direction = step.direction

            imageView.setIndex(step.image)
            adjustSlider()
            imageView.sendSyncMessage(0)

            horos_lastTime = thisTime

            imageView.displayIfNeeded()
            horos_speedometer += 1
        }
    }

    /// Another viewer started its "Browse" player: this one stops.
    @objc(notificationStopPlaying:)
    func notificationStopPlaying(_ note: Notification!) {
        if horos_timer != nil { playStop(findPlayStopButton()) }
    }

    /// The "Browse" toolbar item: starts the player (stopping the others'), or
    /// stops it.
    @objc(PlayStop:)
    func playStop(_ sender: Any!) {
        let item = sender as? NSToolbarItem
        if let timer = horos_timer {
            timer.invalidate()
            horos_timer = nil

            item?.image = NSImage.toolbarImageNamed(PlayToolbarItemIdentifier)
            item?.label = NSLocalizedString("Browse", comment: "")
            item?.paletteLabel = NSLocalizedString("Browse", comment: "")
            item?.toolTip = NSLocalizedString("Browse this series", comment: "")

            horos_speedText?.stringValue = String(format: NSLocalizedString("%0.1f im/s", comment: "im/s = images per second"), Double(frameRate() * horos_direction))
        } else {
            NotificationCenter.default.post(name: .OsirixStopPlaying, object: self, userInfo: nil)

            let timer = Timer.scheduledTimer(timeInterval: 0, target: self, selector: #selector(performAnimation(_:)), userInfo: nil, repeats: true)
            horos_timer = timer
            RunLoop.current.add(timer, forMode: .modalPanel)
            RunLoop.current.add(timer, forMode: .eventTracking)

            horos_lastTime = ProcessInfo.processInfo.systemUptime
            horos_lastTimeFrame = ProcessInfo.processInfo.systemUptime

            item?.image = NSImage.toolbarImageNamed(PauseToolbarItemIdentifier)
            item?.label = NSLocalizedString("Stop", comment: "")
            item?.paletteLabel = NSLocalizedString("Stop", comment: "")
        }
    }
}

extension ViewerController {

    /// Whether the series is still loading and less than half of it is there:
    /// the players wait.
    func isLoadingFirstHalf() -> Bool {
        guard let thread = horos_loadingThread else { return false }
        objc_sync_enter(thread)
        defer { objc_sync_exit(thread) }
        let percentage = (thread.threadDictionary.object(forKey: "loadingPercentage") as? NSNumber)?.floatValue ?? 0
        return !thread.isFinished && percentage < 0.5
    }
}
