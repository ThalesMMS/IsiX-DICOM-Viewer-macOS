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
// on is IsiXImaging's SliceNavigation, over the view's stack; ViewerSlices
// applies it to the viewer, and the player is CinePlayback. The 4D frames are
// in ViewerController+FourDNavigation.swift. The selectors are those of the
// former Objective-C methods, kept as a façade.

public extension ViewerController {

    // The lists of the movie frames: read from any thread, as before.

    /// The slices of movie frame `i` (wrapped into the frames there are).
    @objc(pixList:)
    nonisolated func pixList(_ i: Int) -> NSMutableArray! {
        horos_pixList(at: SliceNavigation.wrappedMovieIndex(i, count: Int(horos_maxMovieIndex)))
    }

    /// The slices of the current movie frame (OSIWindowController's, for a 2D viewer).
    @objc(pixList)
    override nonisolated func pixList() -> NSMutableArray! {
        horos_pixList(at: Int(horos_curMovieIndex))
    }

    /// The files of the current movie frame.
    @objc(fileList)
    nonisolated func fileList() -> NSMutableArray! {
        horos_fileList(at: Int(horos_curMovieIndex))
    }

    /// The files of movie frame `i` (wrapped into the frames there are).
    @objc(fileList:)
    nonisolated func fileList(_ i: Int) -> NSMutableArray! {
        horos_fileList(at: SliceNavigation.wrappedMovieIndex(i, count: Int(horos_maxMovieIndex)))
    }

    /// The "Browse" player's speed, in images per second.
    @objc(frameRate)
    func frameRate() -> Float {
        cine.frameRate
    }

    @objc(speedSliderAction:)
    func speedSliderAction(_ sender: Any!) {
        cine.speedChanged()
    }

    @objc(adjustSlider)
    func adjustSlider() {
        ViewerSlices(viewer: self).adjustSlider()
    }

    @objc(imageIndex)
    func imageIndex() -> Int {
        ViewerSlices(viewer: self).imageIndex
    }

    @objc(setImageIndex:)
    func setImageIndex(_ i: Int) {
        ViewerSlices(viewer: self).show(index: i)
    }

    @objc(setImage:)
    func setImage(_ image: NSManagedObject!) {
        ViewerSlices(viewer: self).show(file: image)
    }

    @objc(performAnimation:)
    func performAnimation(_ sender: Any!) {
        cine.advanceSlice()
    }

    @objc(notificationStopPlaying:)
    func notificationStopPlaying(_ note: Notification!) {
        cine.stopForOtherPlayer()
    }

    @objc(PlayStop:)
    func playStop(_ sender: Any!) {
        cine.toggleSlices(sender)
    }
}

/// The images of a 2D viewer's frame, made for one call: the strip slider and
/// the key image button of the image shown, the index the user counts, and the
/// image or file asked for. Held strongly: forming an unowned or weak reference
/// to an object being deallocated traps.
@MainActor struct ViewerSlices {
    let viewer: ViewerController

    /// The strip slider and the key image button, for the image shown.
    func adjustSlider() {
        if let imageView = viewer.horos_imageView {
            let count = viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0
            viewer.horos_slider?.intValue = SliceNavigation.sliderValue(of: imageView.stackNavigation, count: count, flipped: imageView.flippedData)
        } else {
            viewer.horos_slider?.intValue = 0
        }
        // A thick slab runs from the current image towards the end of the strip,
        // flipped data or not: the strip is flipped with the data.
        if let slider = viewer.horos_slider as? ImageNavigationSlider {
            slider.slabImageCount = SliceNavigation.slabImageCount(stack: Int(viewer.horos_imageView?.curDCM?.stack ?? 0))
        }

        viewer.adjustKeyImage()
    }

    /// The image shown, as the user counts it.
    var imageIndex: Int {
        guard let imageView = viewer.horos_imageView else { return 0 }
        return SliceNavigation.userIndex(of: imageView.stackNavigation, count: Int(viewer.getNumberOfImages()), flipped: imageView.flippedData)
    }

    /// Shows image `index` as the user counts it (clamped to the series), and
    /// synchronizes the other viewers.
    func show(index: Int) {
        guard let imageView = viewer.horos_imageView else {
            viewer.adjustSlider()
            return
        }
        let image = SliceNavigation.stackImage(forUserIndex: index, count: Int(viewer.getNumberOfImages()), flipped: imageView.flippedData)
        imageView.setIndex(image)
        imageView.sendSyncMessage(0)
        viewer.adjustSlider()
        imageView.displayIfNeeded()
    }

    /// Shows `file`, in whichever movie frame has it.
    func show(file: NSManagedObject?) {
        guard let position = SliceNavigation.position(movieCount: viewer.horos_movieCount, files: { viewer.horos_fileList(at: $0)?.count },
                                                      matches: { viewer.horos_fileList(at: $0)?.object(at: $1) as AnyObject === file }) else { return }
        viewer.setMovieIndex(Int16(truncatingIfNeeded: position.movie))
        viewer.horos_imageView?.setIndex(position.image)
        viewer.horos_imageView?.sendSyncMessage(0)
        viewer.adjustSlider()
        viewer.horos_imageView?.displayIfNeeded()
    }
}
