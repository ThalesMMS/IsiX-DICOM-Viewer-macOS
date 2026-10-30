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

// The decisions of a region growing around ITK's filters: which filter an
// algorithm runs and with which parameters, which voxel is the seed, which
// slices a result covers and how a grown region becomes ROIs. The filters run
// in the app's ITK adapter; the ROIs, the viewers and the notifications are
// the app's.

/// A C conversion of a double to a 64-bit integer as arm64 makes it: toward
/// zero, NaN as 0, saturated at the ends.
func cInteger(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    if value >= 9_223_372_036_854_775_807.0 { return Int.max }
    if value <= -9_223_372_036_854_775_808.0 { return Int.min }
    return Int(value)
}

/// The ITK filter of a region growing, with its parameters.
public enum RegionGrowingFilter: Equatable, Sendable {
    /// Connected threshold: the voxels between `lower` and `upper` connected to the seed.
    case connectedThreshold(lower: Float, upper: Float)
    /// Neighborhood connected: the voxels whose neighbourhood of `radius` lies between the bounds.
    case neighborhoodConnected(lower: Float, upper: Float, radius: Int32)
    /// Confidence connected: the voxels within `multiplier` standard deviations of the region's mean,
    /// re-estimated `iterations` times from a neighbourhood of `radius`.
    case confidenceConnected(multiplier: Float, iterations: Int32, radius: Int32)

    /// The filter of algorithm `algorithm` (RegionGrowingAlgorithm's raw
    /// values), its parameters read by index as floats or as integers, and
    /// `seedValue` (read only by the interval algorithm) the value under the
    /// seed. nil for any other number: nothing grows.
    ///
    /// The interval algorithm takes half the interval below and above the
    /// seed's value, in double precision, rounded to floats.
    public static func of(algorithm: Int, float: (Int) -> Float, integer: (Int) -> Int32,
                          seedValue: () -> Float) -> RegionGrowingFilter? {
        switch RegionGrowingAlgorithm(rawValue: algorithm) {
        case .interval:
            let value = Double(seedValue())
            let interval = Double(float(0))
            return .connectedThreshold(lower: Float(value - interval / 2.0), upper: Float(value + interval / 2.0))
        case .threshold:
            return .connectedThreshold(lower: float(0), upper: float(1))
        case .neighborhood:
            return .neighborhoodConnected(lower: float(0), upper: float(1), radius: integer(2))
        case .confidence:
            return .confidenceConnected(multiplier: float(0), iterations: integer(1), radius: integer(2))
        case nil:
            return nil
        }
    }

    /// The seed voxel of a click at `point` (pixels of the image): x and y cut
    /// to integers as a C cast cuts them; z is the image shown (`currentImage`)
    /// when the whole volume grows (`slice` -1), else 0, the only plane.
    public static func seed(x: Double, y: Double, slice: Int, currentImage: Int) -> (x: Int, y: Int, z: Int) {
        (cInteger(x), cInteger(y), slice == -1 ? currentImage : 0)
    }
}

/// How a grown region becomes a result.
public enum RegionGrowingResult {
    /// The value of the mask inside the region.
    public static let inside: UInt8 = 255

    /// The slices a result covers: every slice of the series (`sliceCount`)
    /// when the whole volume grew (`slice` -1), else `slice` alone.
    public static func slices(slice: Int, sliceCount: Int) -> Range<Int> {
        slice == -1 ? 0 ..< max(sliceCount, 0) : slice ..< slice &+ 1
    }

    /// The plane of the mask that holds slice `resultSlice` of the series:
    /// its own when the whole volume grew, else the only one.
    public static func maskPlane(slice: Int, resultSlice: Int) -> Int {
        slice == -1 ? resultSlice : 0
    }

    /// Whether the ROI named `name` is the region growing window's preview
    /// (named `previewName`, compared as Objective-C strings compare).
    public static func isPreview(name: String, previewName: String) -> Bool {
        (name as NSString).isEqual(to: previewName)
    }

    /// The colour of a preview ROI, as 16-bit RGB channels: 0.67, 0.90 and 0.58
    /// of full scale, cut to integers.
    public static let previewColour: (red: UInt16, green: UInt16, blue: UInt16) =
        (UInt16(0.67 * 65535.0), UInt16(0.90 * 65535.0), UInt16(0.58 * 65535.0))

    /// Whether the brush ROIs grown in every slice merge with those already
    /// there: when asked, except for a preview, which would absorb the user's
    /// ROIs into one the next click or computation deletes.
    public static func mergesVolume(name: String, previewName: String, merge: Bool) -> Bool {
        merge && !isPreview(name: name, previewName: previewName)
    }

    /// Whether the brush ROI grown in one slice merges with those already
    /// there: when asked, unless it is the preview.
    public static func mergesSlice(name: String, previewName: String, merge: Bool) -> Bool {
        !isPreview(name: name, previewName: previewName) && merge
    }

    /// The most points a polygon grown from a region keeps.
    public static let polygonMaximumPoints = 200
}
