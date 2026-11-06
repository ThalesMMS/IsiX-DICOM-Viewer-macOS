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
import Accelerate

// The geometry of a 2D viewer's stack of slices: which axis the slices are
// stacked on, the interval between them, the orientation the viewer shows, and
// the reversal of a stack whose slices come in descending order. The viewer
// reads its DCMPix and applies the answers; nothing here knows DCMPix or the
// viewer.

/// Same threshold as ORIENTATION_SENSIBILITY in DCMPix.h: two orientations
/// whose cosines differ by no more than this are the same.
public let sliceOrientationTolerance = 0.001

/// The orientation a 2D viewer names its slices by. The raw values are the
/// viewer's orientationVector (eSagittalPos … eAxialNeg in ViewerController.h).
public enum SliceStackOrientation: Int16, Sendable {
    case sagittalPositive = 0, sagittalNegative, coronalPositive, coronalNegative, axialPositive, axialNegative

    /// The orientation of a stack whose slice normal points along `axis`
    /// (0 x, 1 y, 2 z) with the sign of `component`.
    public init(axis: Int, component: Double) {
        switch axis {
        case 0: self = component > 0 ? .sagittalPositive : .sagittalNegative
        case 1: self = component > 0 ? .coronalPositive : .coronalNegative
        default: self = component > 0 ? .axialPositive : .axialNegative
        }
    }

    /// The viewer's orthogonal orientation: 0 axial, 1 coronal, 2 sagittal (the
    /// tags of its orientation matrix and of its MPR menu).
    public var orthogonalTag: Int16 {
        switch self {
        case .axialPositive, .axialNegative: return 0
        case .coronalPositive, .coronalNegative: return 1
        case .sagittalPositive, .sagittalNegative: return 2
        }
    }
}

public enum SliceStack {

    /// The axis (0 x, 1 y, 2 z) of the largest of the three normal components
    /// in absolute value, or nil when none is strictly larger than the other two.
    public static func dominantAxis<T: BinaryFloatingPoint>(_ x: T, _ y: T, _ z: T) -> Int? {
        if abs(x) > abs(y) && abs(x) > abs(z) { return 0 }
        if abs(y) > abs(x) && abs(y) > abs(z) { return 1 }
        if abs(z) > abs(x) && abs(z) > abs(y) { return 2 }
        return nil
    }

    /// The normal of the plane whose row and column cosines are the first six
    /// values of `v`, as the viewer computes it from the fields of its slice
    /// interval sheet: v[6…8] = row × column, in float.
    public static func normal(_ v: [Float]) -> [Float] {
        // a*b - c*d, which clang fused into fma(a, b, -(c*d)).
        func cross(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
            return (-(c * d)).addingProduct(a, b)
        }
        return [cross(v[1], v[5], v[2], v[4]), cross(v[2], v[3], v[0], v[5]), cross(v[0], v[4], v[1], v[3])]
    }

    /// Whether two orientations (nine cosines each) are the same within
    /// sliceOrientationTolerance and not both zero (no orientation).
    public static func isSameNonZeroOrientation(_ a: [Double], _ b: [Double]) -> Bool {
        for i in 0..<9 where abs(a[i] - b[i]) > sliceOrientationTolerance { return false }
        for i in 0..<9 where a[i] != 0 || b[i] != 0 { return true }
        return false
    }

    /// The signed interval from slice A to slice B along the slice normal's
    /// dominant axis, positive when B is further along the normal; 0 when the
    /// orientations differ, are zero, or no axis dominates. The viewer's
    /// +computeIntervalForDCMPix:And:.
    public static func interval(fromOrigin originA: [Double], orientation orientationA: [Double],
                                toOrigin originB: [Double], orientation orientationB: [Double]) -> Float {
        guard isSameNonZeroOrientation(orientationA, orientationB),
              let axis = dominantAxis(orientationA[6], orientationA[7], orientationA[8]) else { return 0 }
        let interval = Float(originA[axis] - originB[axis])
        return orientationA[6 + axis] > 0 ? -interval : interval
    }

    /// Reverses the order of `sliceCount` slices of `sliceFloatCount` floats
    /// each, stored one after the other from `base`: slice i and slice
    /// sliceCount-1-i trade places. A large stack is swapped on all processors.
    public static func reverseSlices(_ base: UnsafeMutablePointer<Float>, sliceCount: Int, sliceFloatCount: Int) {
        if sliceCount > 50 {
            let workers = ProcessInfo.processInfo.processorCount
            let pairs = sliceCount / 2
            let bytes = sliceFloatCount * 4
            nonisolated(unsafe) let base = base
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                let from = (worker * pairs) / workers, to = ((worker + 1) * pairs) / workers
                guard from < to, let temporary = malloc(bytes) else { return }
                for i in from..<to {
                    let a = base + sliceFloatCount * i, b = base + sliceFloatCount * (sliceCount - 1 - i)
                    memmove(temporary, a, bytes)
                    memmove(a, b, bytes)
                    memmove(b, temporary, bytes)
                }
                free(temporary)
            }
        } else {
            var buffer = vImage_Buffer(data: base, height: vImagePixelCount(sliceCount),
                                       width: vImagePixelCount(sliceFloatCount), rowBytes: sliceFloatCount * 4)
            var destination = buffer
            vImageVerticalReflect_PlanarF(&buffer, &destination, vImage_Flags(kvImageNoFlags))
        }
    }
}

/// What the viewer learns of its stack from the first three slices when the
/// series has no slice interval yet (-computeIntervalFlipNow:).
public struct SliceStackSpacing: Sendable, Equatable {
    /// The orientation the slices are stacked in; nil when no axis dominates,
    /// in which case the viewer keeps the one it had.
    public let orientation: SliceStackOrientation?
    /// Signed interval between slices 1 and 2 along the dominant axis,
    /// negative when the slices come in descending order; 0 when none.
    public let interval: Double
    /// The distance between the origins of slices 1 and 2.
    public let interval3D: Double

    /// nil when slices 1 and 2 do not have the same orientation, or have none:
    /// the viewer then leaves the stack as it is.
    public init?(orientation1: [Double], orientation2: [Double], origin1: [Double], origin2: [Double]) {
        guard SliceStack.isSameNonZeroOrientation(orientation1, orientation2) else { return nil }

        var interval: Double = 0
        var orientation: SliceStackOrientation? = nil
        if let axis = SliceStack.dominantAxis(orientation1[6], orientation1[7], orientation1[8]) {
            interval = origin1[axis] - origin2[axis]
            if orientation1[6 + axis] > 0 { interval = -interval }
            orientation = SliceStackOrientation(axis: axis, component: orientation1[6 + axis])
        }

        let xd = origin2[0] - origin1[0], yd = origin2[1] - origin1[1], zd = origin2[2] - origin1[2]
        // sqrt(xd*xd + yd*yd + zd*zd), which clang fused into fma(zd, zd, fma(xd, xd, yd*yd)).
        let sum = (yd * yd).addingProduct(xd, xd).addingProduct(zd, zd)

        self.orientation = orientation
        self.interval = interval
        self.interval3D = sum.squareRoot()
    }

    /// The interval the stack's slices get: the 3D distance between slices
    /// when there is one, else the axis interval, positive.
    public static func sliceInterval(interval: Double, interval3D: Double) -> Double {
        if interval3D != 0 { return interval < 0 ? -interval3D : interval3D }
        return interval < 0 ? -interval : interval
    }

    /// The interval of a stack that was reversed because it was descending.
    public static func reversedSliceInterval(interval: Double, interval3D: Double) -> Double {
        return interval3D != 0 ? abs(interval3D) : abs(interval)
    }
}
