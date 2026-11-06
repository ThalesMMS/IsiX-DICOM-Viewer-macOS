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

// The movie frames of a 2D viewer (4D: the "4D navigation" block, 4.4.2, and
// the 4D player of 4.4.1): the frames added to the series, the frame shown, its
// slider, and the player that steps through the frames at the 4D speed. The
// frame indexes wrap as IsiXImaging's SliceNavigation says; ViewerFrames
// applies it to the viewer, and the player is CinePlayback. The selectors are
// those of the former Objective-C methods, kept as a façade.

public extension ViewerController {

    @objc(addMovieSerie:::)
    func addMovieSerie(_ f: NSMutableArray!, _ d: NSMutableArray!, _ v: NSData!) {
        ViewerFrames(viewer: self).add(slices: f, files: d, volume: v)
    }

    /// The 4D player's speed, in frames per second.
    @objc(movieRate)
    func movieRate() -> Float {
        cine.movieRate
    }

    @objc(frame4DRate)
    func frame4DRate() -> Float {
        cine.movieRate
    }

    @objc(movieRateSliderAction:)
    func movieRateSliderAction(_ sender: Any!) {
        cine.movieRateChanged()
    }

    @objc(moviePosSlider)
    func moviePosSlider() -> NSSlider! {
        return horos_moviePosSlider
    }

    @objc(setMovieIndex:)
    func setMovieIndex(_ i: Int16) {
        ViewerFrames(viewer: self).show(Int(i))
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

    @objc(performMovieAnimation:)
    func performMovieAnimation(_ sender: Any!) {
        cine.advanceMovie()
    }

    @objc(MovieStop:)
    func movieStop(_ sender: Any!) {
        cine.stopMovie()
    }

    @objc(MoviePlayStop:)
    func moviePlayStop(_ sender: Any!) {
        cine.toggleMovie()
    }

    @objc(isPlaying4D)
    func isPlaying4D() -> Bool {
        cine.isPlaying4D
    }
}

/// The movie frames of a 2D viewer, made for one call: adding one and showing
/// one. Held strongly: forming an unowned or weak reference to an object being
/// deallocated traps.
@MainActor struct ViewerFrames {
    let viewer: ViewerController

    /// Adds a movie frame: its slices, files and volume (kept as they are, the
    /// slices point into its bytes), with empty ROI lists, the ROIs saved for
    /// it, and the transfer function of the first frame. At most MAX4D frames.
    func add(slices f: NSMutableArray?, files d: NSMutableArray?, volume v: NSData?) {
        let index = Int(viewer.horos_maxMovieIndex)
        guard SliceNavigation.canAddMovie(at: index, capacity: Int(MAX4D)) else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("4D Player", comment: ""),
                                        message: String(format: NSLocalizedString("4D Player is limited to a maximum number of %d series.", comment: ""), Int32(MAX4D)),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        // The slots of a new frame are empty: they take the objects retained,
        // as before, without releasing what they held.
        viewer.horos_assignVolumeData(v.map { Unmanaged.passRetained($0).takeUnretainedValue() }, at: index)
        viewer.horos_sendDidAllocateVolumeDataNotification(forMovieIndex: index)

        viewer.horos_assignPixList(f.map { Unmanaged.passRetained($0).takeUnretainedValue() }, at: index)
        viewer.horos_assignFileList(d.map { Unmanaged.passRetained($0).takeUnretainedValue() }, at: index)

        // Prepare pixList for image thick slab
        if let slices = f {
            for i in 0..<slices.count {
                if let pix = slices.object(at: i) as? DCMPix { viewerSetArrayPix(pix, slices, i) }
            }
        }

        // Empty ROI lists for the new frame, one per slice: the lists plugins
        // change in place.
        let slots = f?.count ?? 0
        let copies = NSMutableArray(array: Array(repeating: NSData(), count: slots)), rois = NSMutableArray(array: (0..<slots).map { _ in NSMutableArray() })
        viewer.horos_assignCopyRoiList(Unmanaged.passRetained(copies).takeUnretainedValue(), at: index)
        viewer.horos_assignRoiList(Unmanaged.passRetained(rois).takeUnretainedValue(), at: index)
        viewer.loadROI(index)

        viewer.horos_maxMovieIndex += 1
        let count = Int(viewer.horos_maxMovieIndex)

        viewer.horos_moviePosSlider?.maxValue = Double(count - 1)
        viewer.horos_moviePosSlider?.numberOfTickMarks = count

        viewer.horos_movieRateSlider?.isEnabled = true
        viewer.horos_moviePosSlider?.isEnabled = true
        viewer.horos_moviePlayStop?.isEnabled = true

        if let first = viewer.horos_pixList(at: 0), first.count > 0, let added = viewer.horos_pixList(at: count - 1) {
            // Every slice of the new frame shares the first frame's table, the
            // same NSData object.
            let transferFunction = (first.lastObject as? DCMPix)?.transferTable
            for case let pix as DCMPix in added {
                pix.transferTable = transferFunction
            }
        }
    }

    /// Shows movie frame `index` (wrapped into the frames there are), at the
    /// same image, flipped if the frame shown was.
    func show(_ index: Int) {
        let navigatorView = NavigatorWindowController.navigatorWindowController()?.navigatorView
        navigatorView?.removeNotificationObserver()

        let image = viewer.horos_imageView?.curImage ?? 0
        let wasDataFlipped = viewer.horos_imageView?.flippedData ?? false

        var frames = SliceNavigation(movieIndex: Int(viewer.horos_curMovieIndex), movieCount: Int(viewer.horos_maxMovieIndex))
        frames.showMovie(index)
        viewer.horos_curMovieIndex = Int16(truncatingIfNeeded: frames.movieIndex)
        let current = Int(viewer.horos_curMovieIndex)

        viewer.horos_moviePosSlider?.intValue = Int32(viewer.horos_curMovieIndex)

        guard let slices = viewer.horos_pixList(at: current) else {
            NavigatorWindowController.navigatorWindowController()?.navigatorView?.addNotificationObserver()
            return
        }

        viewer.horos_seriesView?.setPixels(slices, files: viewer.horos_fileList(at: current), rois: viewer.horos_roiList(at: current),
                                           firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: false)

        viewer.setWindowTitle(viewer)

        if wasDataFlipped { viewer.flipDataSeries(viewer) }

        NavigatorWindowController.navigatorWindowController()?.navigatorView?.addNotificationObserver()

        if let imageView = viewer.horos_imageView {
            for shown in SliceNavigation.movieChangeImages(image: image, count: slices.count, tiled: imageView.columns > 1 || imageView.rows > 1) {
                imageView.setIndex(shown)
            }
            imageView.sendSyncMessage(0)
        }

        viewer.adjustSlider()
        viewer.showCurrentThumbnail(viewer)
    }
}
