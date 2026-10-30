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

// The grid onto which a series is resampled through an affine transform
// (Fusion > Resample, point registration, gantry tilt correction): ITK works
// in each series' own frame, the DICOM positions turned by the series'
// orientation, and the output takes the reference series' slices, at the
// reference's pixel spacing or, without rescaling, at the moving series'. The
// resampling itself is the app's ITK adapter.

public struct AffineResampleGrid: Equatable, Sendable {
    /// Where the first output voxel is, in the reference's frame.
    public var origin: [Double]
    /// The distance between output voxels (x, y, z).
    public var spacing: [Double]
    /// The output's voxels along x, y and z.
    public var size: [Int]
    /// The output's bytes (32-bit floats).
    public var byteCount: Int

    /// `position` (x, y, z) in the frame of `orientation` (the nine direction
    /// cosines of a slice: row, column, normal): its dot product with each.
    public static func rotated(_ position: [Double], by orientation: [Double]) -> [Double] {
        (0 ..< 3).map { axis in
            position[0] * orientation[3 * axis] + position[1] * orientation[3 * axis + 1] + position[2] * orientation[3 * axis + 2]
        }
    }

    /// The grid of `imageCount` slices that shows the moving series on the
    /// reference's slices. The DICOM origin of the reference's first slice is
    /// the centre of the first output voxel, as an ITK image's origin is.
    /// Rescaled, the slices have the reference's size and pixel spacing; not
    /// rescaled, the moving series' (`originalWidth`, `originalSpacingX`...).
    /// The slices are the reference's interval apart, 1 mm when it has none or
    /// there is one slice.
    public static func grid(rescale: Bool, imageCount: Int,
                            referenceOrigin: [Double], referenceOrientation: [Double],
                            referenceWidth: Int, referenceHeight: Int,
                            referenceSpacingX: Double, referenceSpacingY: Double, referenceInterval: Double,
                            originalWidth: Int, originalHeight: Int,
                            originalSpacingX: Double, originalSpacingY: Double) -> AffineResampleGrid {
        var spacing = rescale ? [referenceSpacingX, referenceSpacingY, referenceInterval]
                              : [originalSpacingX, originalSpacingY, referenceInterval]
        if spacing[2] == 0 || imageCount == 1 {
            spacing[2] = 1
        }
        let width = rescale ? referenceWidth : originalWidth
        let height = rescale ? referenceHeight : originalHeight
        return AffineResampleGrid(origin: rotated(referenceOrigin, by: referenceOrientation), spacing: spacing,
                                  size: [width, height, imageCount],
                                  byteCount: imageCount &* height &* width &* MemoryLayout<Float>.size)
    }
}
