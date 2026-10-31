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

import Foundation

// The viewer's volume data: the float buffer of each 4D frame that the 3D
// viewers read, the release of the 8-bit images before one of them opens, and
// the refresh of the window level and the ROIs after a volume changed in
// place. The selectors are those of the former Objective-C methods; the work
// is ViewerVolumeData's, below.

public extension ViewerController {

    /// Frees the 8-bit image of every slice but the one shown, then computes
    /// the one shown again.
    @objc(clear8bitRepresentations)
    func clear8bitRepresentations() {
        ViewerVolumeData.clear8bitRepresentations(of: self)
    }

    /// The float buffer of the frame shown.
    @objc(volumePtr)
    func volumePtr() -> UnsafeMutablePointer<Float>? {
        ViewerVolumeData.floatBuffer(of: horos_volumeData(at: Int(horos_curMovieIndex)))
    }

    /// The float buffer of frame `i`, wrapped into the frames there are.
    @objc(volumePtr:)
    func volumePtr(_ i: Int) -> UnsafeMutablePointer<Float>? {
        ViewerVolumeData.floatBuffer(of: horos_volumeData(at: FourDSeriesGuard.wrappedIndex(i, count: Int(horos_maxMovieIndex))))
    }

    /// The volume data of the frame shown.
    @objc(volumeData)
    func volumeData() -> NSData! {
        horos_volumeData(at: Int(horos_curMovieIndex)) as? NSData
    }

    /// The volume data of frame `i`, wrapped into the frames there are.
    @objc(volumeData:)
    func volumeData(_ i: Int) -> NSData! {
        horos_volumeData(at: FourDSeriesGuard.wrappedIndex(i, count: Int(horos_maxMovieIndex))) as? NSData
    }

    /// OsirixUpdateVolumeDataNotification for the slices shown.
    @objc(updateVolumeData:)
    func updateVolumeData(_ note: Notification!) {
        ViewerVolumeData.volumeChanged(note, viewer: self)
    }
}
/// The volume data of a 2D viewer: the float buffer of each 4D frame that
/// the 3D viewers read, a copy of a frame's volume, the release of the 8-bit
/// images before a 3D viewer opens, and the refresh of the window level and
/// the ROIs after a volume changed in place. The viewer's selectors stay as
/// façades in ViewerController+VolumeData.swift and +RetrieveAndView.swift.
@MainActor
enum ViewerVolumeData {

    /// The bytes of `data` as floats; nil without data.
    nonisolated static func floatBuffer(of data: NSObject?) -> UnsafeMutablePointer<Float>? {
        guard let data = data as? NSData, data.length > 0 else { return nil }
        return UnsafeMutableRawPointer(mutating: data.bytes).assumingMemoryBound(to: Float.self)
    }

    /// Frees the 8-bit image of every slice but the one shown (about a quarter
    /// of the memory of a series), then computes the one shown again.
    static func clear8bitRepresentations(of viewer: ViewerController) {
        for movieIndex in 0..<Int(viewer.horos_maxMovieIndex) {
            for case let pix as DCMPix in viewer.horos_pixList(at: movieIndex) ?? [] where pix !== viewer.horos_imageView?.curDCM {
                pix.kill8bitsImage()
            }
        }
        viewer.updateImage(viewer)
    }

    /// OsirixUpdateVolumeDataNotification for the slices `viewer` shows: every
    /// slice of every frame takes the window level again and every ROI is
    /// measured again.
    static func volumeChanged(_ note: Notification?, viewer: ViewerController) {
        let changed = note?.object as AnyObject?
        guard changed === viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex)) else { return }

        var wl: Float = 0, ww: Float = 0
        viewer.horos_imageView?.getWLWW(&wl, &ww)

        for movieIndex in 0..<Int(viewer.horos_maxMovieIndex) {
            for case let pix as DCMPix in viewer.horos_pixList(at: movieIndex) ?? [] {
                pix.changeWLWW(wl, ww)
            }
            for case let rois as [Any] in viewer.horos_roiList(at: movieIndex) ?? [] {
                for case let roi as ROI in rois {
                    roi.recompute()
                }
            }
        }

        viewer.horos_imageView?.setWLWW(wl, ww)
    }

    /// A copy of movie frame `movieIndex` of `viewer`: its volume, in a
    /// buffer of its own the data frees, and a copy of each slice pointing
    /// into it. Nil when the buffer cannot be allocated.
    static func copy(movieIndex: Int, of viewer: ViewerController) -> (volume: NSData, pixels: NSMutableArray)? {
        let slices = viewer.pixList(movieIndex)?.compactMap { $0 as? DCMPix } ?? []

        // First calculate the amount of memory needed for the new serie
        // (each pixel contains either a 32-bit float or a 32-bit ARGB value).
        let length = slices.reduce(0) { $0 &+ $1.pheight &* $1.pwidth &* 4 }

        guard let buffer = malloc(length)?.assumingMemoryBound(to: UInt8.self) else { return nil }	// ALWAYS use malloc for allocating memory !
        // Copy the source series in the new one !
        if let source = viewer.volumePtr(movieIndex) {
            memcpy(buffer, source, length)
        } else {
            // memcpy from NULL: the former code crashed here unless the length was 0.
            precondition(length == 0, "copyVolumeData: the volume has no pixels to copy")
        }

        // An NSData object controls the new buffer.
        let volume = NSData(bytesNoCopy: buffer, length: length, freeWhenDone: true)

        // Now copy the DCMPix with the new buffer.
        let pixels = NSMutableArray()
        for (index, pix) in slices.enumerated() {
            guard let copy = pix.copy() as? DCMPix else {
                NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil",
                            userInfo: nil).raise()
                continue
            }
            copy.fImage = UnsafeMutableRawPointer(buffer + copy.pheight &* copy.pwidth &* 4 &* index).assumingMemoryBound(to: Float.self)
            pixels.add(copy)
        }
        return (volume, pixels)
    }
}
