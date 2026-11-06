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

// How a series is handed to ITK: how many voxels, where the first one is and
// how far apart they are, as the importer of the region growing and of the
// resampling has always placed them. A series imports whole (slice -1), whole
// with the slices 1000 mm apart (slice -2, two copies of one image that the
// gantry tilt correction reorients), or one slice alone; the whole series can
// also be halved along every axis. ITK itself is the app's adapter.

/// The size, origin and spacing ITK gives a series' volume.
public struct VolumeImportGeometry: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var depth: Int
    /// Where the first voxel is, in millimetres (x, y, z).
    public var origin: [Double]
    /// The distance between voxels, in millimetres (x, y, z).
    public var spacing: [Double]
    /// The voxels between the start of the series' volume and the first one
    /// imported: a single slice starts at its own plane.
    public var voxelOffset: Int
    /// Whether the voxels are the volume halved along every axis
    /// (halvedVoxels), rather than the series' own.
    public var halved: Bool

    /// The geometry of a series of `sliceCount` slices of `width` x `height`
    /// whose first slice has the origin, pixel spacing and slice interval
    /// given, imported for `slice` (-1 the whole volume, -2 the whole volume
    /// with the slices 1000 mm apart, else that slice alone), halved when
    /// `halve` and the whole volume is imported.
    ///
    /// The origin and the spacing go through single precision, as the
    /// importer always read them. A series of one slice, or without a slice
    /// interval, has its slices 0.1 mm apart.
    public static func of(width: Int, height: Int, sliceCount: Int,
                          originX: Double, originY: Double, originZ: Double,
                          pixelSpacingX: Double, pixelSpacingY: Double, sliceInterval: Double,
                          slice: Int, halve: Bool) -> VolumeImportGeometry {
        let wholeVolume = slice == -1 || slice == -2
        var width = width, height = height
        var depth = wholeVolume ? sliceCount : 1

        let origin = [Double(Float(originX)), Double(Float(originY)), Double(Float(originZ))]
        var spacingX = Float(pixelSpacingX), spacingY = Float(pixelSpacingY), spacingZ = Float(sliceInterval)
        if spacingZ == 0 || sliceCount == 1 {
            spacingZ = 0.1
        }
        if slice == -2 {
            spacingZ = 1000
        }

        var voxelOffset = 0
        var halved = false
        if wholeVolume {
            if halve {
                halved = true
                spacingX *= 2
                spacingY *= 2
                spacingZ *= 2
                height /= 2
                width /= 2
                depth /= 2
            }
        } else {
            voxelOffset = slice &* width &* height
        }

        return VolumeImportGeometry(width: width, height: height, depth: depth, origin: origin,
                                    spacing: [Double(spacingX), Double(spacingY), Double(spacingZ)],
                                    voxelOffset: voxelOffset, halved: halved)
    }

    /// The voxels of odd x, y and z of the `width` x `height` x `depth`
    /// volume at `data`, x fastest: the volume halved along every axis by
    /// taking one voxel of each 2 x 2 x 2 block, without interpolating.
    public static func halvedVoxels(_ data: UnsafePointer<Float>, width: Int, height: Int, depth: Int) -> [Float] {
        let count = (width / 2) * (height / 2) * (depth / 2)
        guard count > 0 else { return [] }
        let plane = width * height
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            var i = 0
            var z = 1
            while z < depth {
                var y = 1
                while y < height {
                    var x = 1
                    while x < width {
                        buffer[i] = data[z * plane + y * width + x]
                        i += 1
                        x += 2
                    }
                    y += 2
                }
                z += 2
            }
            initialized = i
        }
    }
}
