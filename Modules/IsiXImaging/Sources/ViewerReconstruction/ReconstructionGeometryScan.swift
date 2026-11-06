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

/// What the 2D viewer checks of its slices before it opens a reconstruction
/// (orthogonal or oblique MPR, CPR): how many slices differ in size from the
/// first, how many differ in orientation from the reference slice, and the
/// shortest and longest distance between consecutive slices.
public struct ReconstructionGeometryScan: Equatable, Sendable {
    /// One slice: its matrix, its orientation (the row, column and normal
    /// vectors) and its origin in patient millimetres.
    public struct Slice: Sendable {
        public let width: Int
        public let height: Int
        public let orientation: [Float]
        public let originX: Double
        public let originY: Double
        public let originZ: Double

        public init(width: Int, height: Int, orientation: [Float], originX: Double, originY: Double, originZ: Double) {
            self.width = width
            self.height = height
            self.orientation = orientation
            self.originX = originX
            self.originY = originY
            self.originZ = originZ
        }
    }

    /// The tolerance of one orientation component, `ORIENTATION_SENSIBILITY`.
    public static let orientationTolerance = 0.001

    public let mismatchedSlices: Int
    public let mismatchedOrientations: Int
    public let minInterval: Double
    public let maxInterval: Double

    /// The scan of `slices`, whose interval the viewer computed as
    /// `interval`. The reference orientation is the second slice's (the
    /// first's for a single slice); with one slice both intervals are
    /// |interval|.
    public static func scan(_ slices: [Slice], interval: Float) -> ReconstructionGeometryScan {
        var minInterval = Double(abs(interval)), maxInterval = Double(abs(interval))
        var mismatchedSlices = 0, mismatchedOrientations = 0
        guard let first = slices.first else {
            return ReconstructionGeometryScan(mismatchedSlices: 0, mismatchedOrientations: 0,
                                              minInterval: minInterval, maxInterval: maxInterval)
        }
        let reference = slices[slices.count > 1 ? 1 : 0].orientation

        for (j, slice) in slices.enumerated() {
            if slice.width != first.width || slice.height != first.height {
                mismatchedSlices += 1
            }
            for k in 0..<9 where Double(abs(slice.orientation[k] - reference[k])) > orientationTolerance {
                mismatchedOrientations += 1
                break
            }
            if j + 1 < slices.count {
                let next = slices[j + 1]
                let xd = next.originX - slice.originX
                let yd = next.originY - slice.originY
                let zd = next.originZ - slice.originZ
                // xd*xd + yd*yd + zd*zd with the fused multiply-adds clang
                // makes of it in the Objective-C this replaces.
                let step = (yd * yd).addingProduct(xd, xd).addingProduct(zd, zd).squareRoot()
                if j == 0 {
                    minInterval = step
                    maxInterval = step
                } else {
                    if step > maxInterval { maxInterval = step }
                    if step < minInterval { minInterval = step }
                }
            }
        }
        return ReconstructionGeometryScan(mismatchedSlices: mismatchedSlices, mismatchedOrientations: mismatchedOrientations,
                                          minInterval: minInterval, maxInterval: maxInterval)
    }
}
