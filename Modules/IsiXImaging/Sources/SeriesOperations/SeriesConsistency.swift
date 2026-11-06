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

// What a 2D viewer checks and corrects in the geometry of its stack: the
// slices of another matrix or orientation, the extrapolated position of a
// first or last slice, and the correction of a tilted gantry (the transform
// that brings a slice onto the plane of the stack's middle slice). The viewer
// reads its DCMPix and its files and applies the answers; nothing here knows
// DCMPix or the viewer.

public enum SeriesConsistency {

    /// The tolerance of one orientation component, ORIENTATION_SENSIBILITY.
    public static let orientationTolerance = 0.001

    /// The slices whose matrix (width × height) differs from the reference
    /// matrix: how many, and the first of them.
    public static func matrixMismatches(widths: [Int32], heights: [Int32], width: Int32, height: Int32) -> (count: Int, first: Int?) {
        var count = 0
        var first: Int?
        for j in 0..<widths.count where widths[j] != width || heights[j] != height {
            count += 1
            if first == nil { first = j }
        }
        return (count, first)
    }

    /// One slice of another matrix, the first or the last, can be dropped.
    public static func dropsOneSlice(mismatches: (count: Int, first: Int?), sliceCount: Int) -> Int? {
        guard mismatches.count == 1, let first = mismatches.first, first == 0 || first == sliceCount - 1 else { return nil }
        return first
    }

    /// Whether the orientation `o` (nine floats) differs from `reference` by
    /// more than the tolerance in any component.
    public static func orientationDiffers(_ o: [Float], from reference: [Float]) -> Bool {
        for k in 0..<9 where Double(abs(o[k] - reference[k])) > orientationTolerance { return true }
        return false
    }

    /// The origin of a first slice continued from the next two: `second`
    /// minus the step from `second` to `third`, in float.
    public static func extrapolatedFirstOrigin(second: [Float], third: [Float]) -> [Float] {
        return (0..<3).map { second[$0] - (third[$0] - second[$0]) }
    }

    /// The origin of a last slice continued from the two before it:
    /// `penultimate` plus the step from `antepenultimate`, in float.
    public static func extrapolatedLastOrigin(penultimate: [Float], antepenultimate: [Float]) -> [Float] {
        return (0..<3).map { penultimate[$0] + (penultimate[$0] - antepenultimate[$0]) }
    }
}

public enum GantryTiltCorrection {

    /// Whether a slice can be corrected with the model: the same rows and
    /// columns, exactly.
    public static func hasModelOrientation(_ o: [Double], model: [Double]) -> Bool {
        for i in 0..<6 where o[i] != model[i] { return false }
        return true
    }

    /// The twelve parameters the transform reorients a slice with: the rows
    /// and columns of the slice (`sensor`) projected on those of the model,
    /// each normalised, their cross product, then the offset of the slice's
    /// origin from the model's.
    public static func parameters(sensor s: [Double], model m: [Double], offset: [Double]) -> [Double] {
        var p = [Double](repeating: 0, count: 12)
        p[9] = offset[0]
        p[10] = offset[1]
        p[11] = offset[2]

        // a*b + c*d + e*f, which clang fused into fma(e, f, fma(a, b, c*d)).
        func dot(_ i: Int, _ j: Int) -> Double {
            return (s[i + 1] * m[j + 1]).addingProduct(s[i], m[j]).addingProduct(s[i + 2], m[j + 2])
        }
        func normalise(_ i: Int) {
            let length = (p[i + 1] * p[i + 1]).addingProduct(p[i], p[i]).addingProduct(p[i + 2], p[i + 2]).squareRoot()
            p[i] = p[i] / length
            p[i + 1] = p[i + 1] / length
            p[i + 2] = p[i + 2] / length
        }

        p[0] = dot(0, 0)
        p[1] = dot(0, 3)
        p[2] = dot(0, 6)
        normalise(0)

        p[3] = dot(3, 0)
        p[4] = dot(3, 3)
        p[5] = dot(3, 6)
        normalise(3)

        // a*b - c*d, which clang fused into fma(a, b, -(c*d)).
        p[6] = (-(p[2] * p[4])).addingProduct(p[1], p[5])
        p[7] = (-(p[0] * p[5])).addingProduct(p[2], p[3])
        p[8] = (-(p[1] * p[3])).addingProduct(p[0], p[4])
        normalise(6)
        return p
    }

    /// The origin of a slice projected on the model's plane: the model's
    /// origin moved along the model's normal (6…8) by the distance of the
    /// slice's offset along it.
    public static func projectedOrigin(modelOrigin origin: [Double], model m: [Double], offset: [Double]) -> [Double] {
        let distance = (offset[1] * m[7]).addingProduct(offset[0], m[6]).addingProduct(offset[2], m[8])
        return [origin[0].addingProduct(distance, m[6]), origin[1].addingProduct(distance, m[7]), origin[2].addingProduct(distance, m[8])]
    }
}
