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

// The volumetric lengths of the 2D viewer, with the selectors of the former
// Objective-C methods (-addVolumeLengthROI:, -addVolumeLengthROI:movieIndex:,
// -volumeLengthROIsForMovieIndex:, and the registration, attachment,
// snapshot and saving the other blocks call). The work and the state of each
// time point are ViewerVolumeLengths'.

public extension ViewerController {

    /// The ROIs of the archive at `path`: none when there is no path or no
    /// file; an unreadable archive raises NSInvalidUnarchiveOperationException.
    @objc(volumeLengthArchiveROIsAtPath:)
    class func volumeLengthArchiveROIs(atPath path: String?) -> [Any] {
        ViewerVolumeLengths.archiveROIs(atPath: path)
    }

    /// Forgets the volume length states of the viewer.
    @objc(clearVolumeLengthState)
    func clearVolumeLengthState() {
        ViewerVolumeLengths.clear(self)
    }

    /// The volume length state of the time point `movieIndex`, made when
    /// `create` asks for it.
    @objc(volumeLengthStateForMovieIndex:create:)
    func volumeLengthState(forMovieIndex movieIndex: Int, create: Bool) -> NSMutableDictionary? {
        ViewerVolumeLengths.state(of: self, movieIndex: movieIndex, create: create)
    }

    /// The volume lengths of the time point `movieIndex`, one per identifier.
    @objc(volumeLengthROIsForMovieIndex:)
    func volumeLengthROIs(forMovieIndex movieIndex: Int) -> [HorosVolumeLengthROI]! {
        ViewerVolumeLengths.lengths(of: self, movieIndex: movieIndex)
    }

    /// Ties `roi` to its anchor image (`anchor`, the one it had, or the
    /// first image of the time point), which its payload names.
    @objc(registerVolumeLengthROI:movieIndex:anchor:)
    func register(_ roi: HorosVolumeLengthROI!, movieIndex: Int, anchor: DicomImage!) {
        guard let roi else { return }
        ViewerVolumeLengths.register(roi, movieIndex: movieIndex, anchor: anchor, in: self)
    }

    /// Puts `roi` (aliased) on every slice of the time point `movieIndex`, in
    /// place of the volume lengths of the same identifier.
    @objc(attachVolumeLengthROI:movieIndex:)
    func attach(_ roi: HorosVolumeLengthROI!, movieIndex: Int) {
        guard let roi else { return }
        ViewerVolumeLengths.attach(roi, movieIndex: movieIndex, in: self)
    }

    /// Registers one volumetric Length and exposes the same object on all
    /// slices of the current time point. Does not add an undo entry.
    @objc(addVolumeLengthROI:)
    func add(_ roi: HorosVolumeLengthROI!) {
        add(roi, movieIndex: Int(horos_curMovieIndex))
    }

    @objc(addVolumeLengthROI:movieIndex:)
    func add(_ roi: HorosVolumeLengthROI!, movieIndex: Int) {
        guard let roi else { return }
        ViewerVolumeLengths.add(roi, movieIndex: movieIndex, in: self)
    }

    /// Puts back the volume lengths and the state a snapshot of the time
    /// point `movieIndex` holds ({state, rois}).
    @objc(restoreVolumeLengthSnapshot:movieIndex:)
    func restoreVolumeLengthSnapshot(_ snapshot: [AnyHashable: Any]!, movieIndex: Int) {
        ViewerVolumeLengths.restore(snapshot, movieIndex: movieIndex, in: self)
    }

    /// Writes the volume lengths of the time point `movieIndex` in the ROI
    /// archive of each of their anchor images (the path of `anchorPaths`, or
    /// the study's), merged with what the archive held of other images; adds
    /// the paths written to `paths`.
    @objc(saveVolumeLengthROIs:writtenPaths:anchorPaths:)
    func saveVolumeLengthROIs(_ movieIndex: Int, writtenPaths paths: NSMutableArray!, anchorPaths: [AnyHashable: Any]!) {
        for path in ViewerVolumeLengths.save(movieIndex: movieIndex, anchorPaths: anchorPaths, in: self) where paths?.contains(path) == false {
            paths?.add(path)
        }
    }
}
