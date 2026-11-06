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
import IsiXSegmentation

/// A series' volume handed to ITK, as the region growing and the resampling
/// read it: the size, origin and spacing of IsiXSegmentation's
/// VolumeImportGeometry, from the first slice, over the viewer's voxels (or
/// over a halved copy the volume keeps). ITK is reached through the adapter's
/// IsiXITKVolume.
@objc(ITKVolumeImport)
public final class ITKVolumeImport: NSObject {

    /// The volume of the slices `pix` over `voxels`, the series' volume, for
    /// `slice`: -1 the whole volume, -2 the whole volume with the slices
    /// 1000 mm apart, else that slice alone; halved along every axis when
    /// `resampleData` and the whole volume is imported. nil without slices or
    /// voxels, or when ITK refuses the volume.
    @objc(volumeWithPix:voxels:slice:resampleData:)
    public class func volume(pix: NSArray?, voxels: UnsafeMutablePointer<Float>?, slice: Int,
                             resampleData: Bool) -> IsiXITKVolume? {
        guard let pix, let first = pix.firstObject as? DCMPix, let voxels else { return nil }

        let geometry = VolumeImportGeometry.of(width: first.pwidth, height: first.pheight, sliceCount: pix.count,
                                               originX: first.originX, originY: first.originY, originZ: first.originZ,
                                               pixelSpacingX: first.pixelSpacingX, pixelSpacingY: first.pixelSpacingY,
                                               sliceInterval: first.sliceInterval, slice: slice, halve: resampleData)

        var data = voxels + geometry.voxelOffset
        var owner: NSMutableData? = nil
        if geometry.halved {
            NSLog("start data resample")
            let halved = VolumeImportGeometry.halvedVoxels(voxels, width: first.pwidth, height: first.pheight, depth: pix.count)
            guard let storage = NSMutableData(length: max(halved.count, 1) * MemoryLayout<Float>.size) else { return nil }
            halved.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { storage.replaceBytes(in: NSRange(location: 0, length: bytes.count), withBytes: base) }
            }
            data = storage.mutableBytes.assumingMemoryBound(to: Float.self)
            owner = storage
            NSLog("end resample data")
        }

        do {
            return try IsiXITKVolume(voxels: data, width: geometry.width, height: geometry.height, depth: geometry.depth,
                                     origin: geometry.origin, spacing: geometry.spacing, owner: owner)
        } catch {
            NSLog("ITK volume refused: %@", error.localizedDescription)
            return nil
        }
    }
}
