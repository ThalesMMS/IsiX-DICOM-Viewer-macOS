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
// place. The selectors are those of the former Objective-C methods.

public extension ViewerController {

    /// Frees the 8-bit image of every slice but the one shown (about a quarter
    /// of the memory of a series), then computes the one shown again.
    @objc(clear8bitRepresentations)
    func clear8bitRepresentations() {
        for i in 0..<Int(horos_maxMovieIndex) {
            guard let slices = horos_pixList(at: i) else { continue }
            for x in 0..<slices.count {
                let pix = slices.object(at: x) as AnyObject
                if pix !== horos_imageView?.curDCM {
                    (pix as? DCMPix)?.kill8bitsImage()
                }
            }
        }
        updateImage(self)
    }

    /// The float buffer of the frame shown.
    @objc(volumePtr)
    func volumePtr() -> UnsafeMutablePointer<Float>? {
        floatBuffer(of: horos_volumeData(at: Int(horos_curMovieIndex)))
    }

    /// The float buffer of frame `i`, wrapped into the frames there are.
    @objc(volumePtr:)
    func volumePtr(_ i: Int) -> UnsafeMutablePointer<Float>? {
        floatBuffer(of: horos_volumeData(at: FourDSeriesGuard.wrappedIndex(i, count: Int(horos_maxMovieIndex))))
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

    /// OsirixUpdateVolumeDataNotification for the slices shown: every slice
    /// of every frame takes the window level again and every ROI is measured
    /// again.
    @objc(updateVolumeData:)
    func updateVolumeData(_ note: Notification!) {
        let changed = note?.object as AnyObject?
        guard changed === horos_pixList(at: Int(horos_curMovieIndex)) else { return }

        var wl: Float = 0, ww: Float = 0
        horos_imageView?.getWLWW(&wl, &ww)

        for y in 0..<Int(horos_maxMovieIndex) {
            for case let pix as DCMPix in horos_pixList(at: y) ?? NSMutableArray() {
                pix.changeWLWW(wl, ww)
            }
            for case let rois as NSArray in horos_roiList(at: y) ?? NSMutableArray() {
                for case let roi as ROI in rois {
                    roi.recompute()
                }
            }
        }

        horos_imageView?.setWLWW(wl, ww)
    }
}

extension ViewerController {

    /// The bytes of `data` as floats; nil without data.
    fileprivate func floatBuffer(of data: NSObject?) -> UnsafeMutablePointer<Float>? {
        guard let data = data as? NSData, data.length > 0 else { return nil }
        let bytes = data.bytes
        return UnsafeMutableRawPointer(mutating: bytes).assumingMemoryBound(to: Float.self)
    }
}
