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

// The movie frames of a 2D viewer (4D: the "4D navigation" block, 4.4.2, and
// the 4D player of 4.4.1): the frames added to the series, the frame shown, its
// slider, and the player that steps through the frames at the 4D speed. The
// frame indexes wrap as HorosFourDSeriesGuard says. The selectors are those of
// the former Objective-C methods.

public extension ViewerController {

    /// Adds a movie frame: its slices `f`, files `d` and volume `v` (kept as
    /// they are, the slices point into its bytes), with empty ROI lists, the
    /// ROIs saved for it, and the transfer function of the first frame. At most
    /// MAX4D frames.
    @objc(addMovieSerie:::)
    func addMovieSerie(_ f: NSMutableArray!, _ d: NSMutableArray!, _ v: NSData!) {
        let index = Int(horos_maxMovieIndex)
        guard FourDSeriesGuard.canStoreTime(at: index, capacity: Int(MAX4D)) else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("4D Player", comment: ""),
                                        message: String(format: NSLocalizedString("4D Player is limited to a maximum number of %d series.", comment: ""), Int32(MAX4D)),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        // The slots of a new frame are empty: they take the objects retained,
        // as before, without releasing what they held.
        horos_assignVolumeData(v.map { Unmanaged.passRetained($0).takeUnretainedValue() }, at: index)
        horos_sendDidAllocateVolumeDataNotification(forMovieIndex: index)

        horos_assignPixList(f.map { Unmanaged.passRetained($0).takeUnretainedValue() }, at: index)
        horos_assignFileList(d.map { Unmanaged.passRetained($0).takeUnretainedValue() }, at: index)

        // Prepare pixList for image thick slab
        if let slices = f {
            for i in 0..<slices.count {
                if let pix = slices.object(at: i) as? DCMPix { viewerSetArrayPix(pix, slices, i) }
            }
        }

        // Empty ROI lists for the new frame.
        let copies = NSMutableArray(), rois = NSMutableArray()
        for _ in 0..<(f?.count ?? 0) {
            rois.add(NSMutableArray())
            copies.add(NSData())
        }
        horos_assignCopyRoiList(Unmanaged.passRetained(copies).takeUnretainedValue(), at: index)
        horos_assignRoiList(Unmanaged.passRetained(rois).takeUnretainedValue(), at: index)
        loadROI(index)

        horos_maxMovieIndex += 1
        let count = Int(horos_maxMovieIndex)

        horos_moviePosSlider?.maxValue = Double(count - 1)
        horos_moviePosSlider?.numberOfTickMarks = count

        horos_movieRateSlider?.isEnabled = true
        horos_moviePosSlider?.isEnabled = true
        horos_moviePlayStop?.isEnabled = true

        if let first = horos_pixList(at: 0), first.count > 0 {
            // Every slice of the new frame shares the first frame's table, the
            // same NSData object: read and set through KVC, since the `Data`
            // the property imports as would hand each slice its own copy.
            let key = #keyPath(DCMPix.transferFunction)
            let transferFunction = (first.lastObject as? DCMPix)?.value(forKey: key) as? NSData
            for case let pix as DCMPix in horos_pixList(at: count - 1) ?? NSMutableArray() {
                pix.setValue(transferFunction, forKey: key)
            }
        }
    }

    /// The 4D player's speed, in frames per second.
    @objc(movieRate)
    func movieRate() -> Float {
        return horos_movieRateSlider?.floatValue ?? 0
    }

    @objc(frame4DRate)
    func frame4DRate() -> Float {
        return horos_movieRateSlider?.floatValue ?? 0
    }

    /// The 4D speed slider: shows the speed, and when this is the key window
    /// hands it to the other viewers still at the default speed, which it
    /// becomes.
    @objc(movieRateSliderAction:)
    func movieRateSliderAction(_ sender: Any!) {
        let rate = movieRate()
        horos_movieTextSlide?.stringValue = String(format: NSLocalizedString("%0.0f im/s", comment: "im/s = images per second"), Double(rate))

        guard window?.isKeyWindow ?? false else { return }
        let defaults = UserDefaults.standard
        for case let viewer as ViewerController in ViewerController.getDisplayed2DViewers() where viewer != self {
            if viewer.movieRate() == defaults.float(forKey: "defaultMovieRate") && viewer.movieRateSlider.floatValue != rate {
                viewer.movieRateSlider.floatValue = rate
                viewer.movieTextSlide.stringValue = String(format: NSLocalizedString("%0.0f im/s", comment: "im/s = images per second"), Double(rate))
            }
        }
        defaults.set(rate, forKey: "defaultMovieRate")
    }

    @objc(moviePosSlider)
    func moviePosSlider() -> NSSlider! {
        return horos_moviePosSlider
    }

    /// Shows movie frame `i` (wrapped into the frames there are), at the same
    /// image, flipped if the frame shown was.
    @objc(setMovieIndex:)
    func setMovieIndex(_ i: Int16) {
        let navigatorView = NavigatorWindowController.navigatorWindowController()?.navigatorView
        navigatorView?.removeNotificationObserver()

        let index = horos_imageView?.curImage ?? 0
        let wasDataFlipped = horos_imageView?.flippedData ?? false

        horos_curMovieIndex = Int16(truncatingIfNeeded: FourDSeriesGuard.wrappedIndex(Int(i), count: Int(horos_maxMovieIndex)))
        let current = Int(horos_curMovieIndex)

        horos_moviePosSlider?.intValue = Int32(horos_curMovieIndex)

        guard let slices = horos_pixList(at: current) else {
            NavigatorWindowController.navigatorWindowController()?.navigatorView?.addNotificationObserver()
            return
        }

        horos_seriesView?.setPixels(slices, files: horos_fileList(at: current), rois: horos_roiList(at: current),
                                    firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: false)

        setWindowTitle(self)

        if wasDataFlipped { flipDataSeries(self) }

        NavigatorWindowController.navigatorWindowController()?.navigatorView?.addNotificationObserver()

        if let imageView = horos_imageView {
            if imageView.columns > 1 || imageView.rows > 1 {
                if index == 0 {
                    imageView.setIndex(slices.count - 1)
                } else {
                    imageView.setIndex(0)
                }
            }

            imageView.setIndex(index)
            imageView.sendSyncMessage(0)
        }

        adjustSlider()
        showCurrentThumbnail(self)
    }

    /// The 4D frame slider: shows the frame and hands it on.
    @objc(moviePosSliderAction:)
    func moviePosSliderAction(_ sender: Any!) {
        setMovieIndex(Int16(truncatingIfNeeded: horos_moviePosSlider?.intValue ?? 0))
        propagateSettings()
    }

    @objc(curMovieIndex)
    nonisolated func curMovieIndex() -> Int16 {
        return horos_curMovieIndex
    }

    /// One tick of the 4D player's timer: the next frame at the 4D speed,
    /// handed on to the other viewers. It waits while less than half the
    /// series is loaded.
    @objc(performMovieAnimation:)
    func performMovieAnimation(_ sender: Any!) {
        if isLoadingFirstHalf() { return }

        // Playback intervals must not change when the civil clock is corrected.
        let thisTime = ProcessInfo.processInfo.systemUptime

        if thisTime - horos_lastMovieTime > 1.0 / Double(horos_movieRateSlider?.floatValue ?? 0) {
            let next = Int16(truncatingIfNeeded: FourDSeriesGuard.nextIndex(Int(horos_curMovieIndex), count: Int(horos_maxMovieIndex)))

            horos_curMovieIndex = next

            setMovieIndex(next)
            propagateSettings()

            horos_lastMovieTime = thisTime
        }
    }

    /// Stops the 4D player and shows the button and speed of a stopped one.
    @objc(MovieStop:)
    func movieStop(_ sender: Any!) {
        if let timer = horos_movieTimer {
            timer.invalidate()
            horos_movieTimer = nil
        }

        // The title used to be reset only by -MoviePlayStop:, so every other way of
        // stopping - opening a 3D viewer, or another viewer starting to play - left
        // this one reading "Stop" with nothing playing.
        horos_moviePlayStop?.title = NSLocalizedString("Play", comment: "")
        horos_movieTextSlide?.stringValue = String(format: NSLocalizedString("%0.0f im/s", comment: "im/s = images per second"), Double(horos_movieRateSlider?.floatValue ?? 0))
    }

    /// The 4D player's button: stops it, or starts it (stopping every other
    /// viewer's) once the series is loaded.
    @objc(MoviePlayStop:)
    func moviePlayStop(_ sender: Any!) {
        if horos_movieTimer != nil {
            movieStop(self)
            return
        }

        for window in NSApp.windows {
            if let viewer = window.windowController as? ViewerController {
                viewer.movieStop(self)
            }
        }

        checkEverythingLoaded()

        let timer = Timer.scheduledTimer(timeInterval: 0, target: self, selector: #selector(performMovieAnimation(_:)), userInfo: nil, repeats: true)
        horos_movieTimer = timer
        RunLoop.current.add(timer, forMode: .modalPanel)
        RunLoop.current.add(timer, forMode: .eventTracking)

        horos_lastMovieTime = ProcessInfo.processInfo.systemUptime

        horos_moviePlayStop?.title = NSLocalizedString("Stop", comment: "")
    }

    @objc(isPlaying4D)
    func isPlaying4D() -> Bool {
        return horos_movieTimer != nil
    }
}
