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

// The interval between the slices of a 2D viewer's series and its correction:
// what the viewer learns from the first slices when the series has no interval
// yet, the stacking of slices that have no position, the reversal of a
// descending stack so that 3D texture mapping gets ascending data, the gantry
// tilt of the stack, and the geometry the slice interval sheet gives every
// slice. The viewer reads its DCMPix and applies the answers; nothing here
// knows DCMPix or the viewer.

/// What -computeIntervalFlipNow: does to a stack of more than two slices whose
/// interval is unknown (or always, when it flips now): read from slices 1 and 2.
public struct SliceIntervalCorrection: Sendable, Equatable {

    /// The orientation and the intervals slices 1 and 2 give.
    public let spacing: SliceStackSpacing
    /// The slices have no position (the first is at 0, 0, 0 and the axis
    /// interval is 0): they are stacked along z by their spacing between slices,
    /// in the axial negative orientation.
    public let stacksWithoutPosition: Bool
    /// The axis interval, the spacing between slices when they are stacked.
    public let interval: Double
    /// The 3D interval, minus the spacing between slices when they are stacked.
    public let interval3D: Double
    /// Everything is loaded and the viewer asked to flip now.
    public let flipsNow: Bool

    /// nil when slices 1 and 2 do not have the same orientation, or have none:
    /// the viewer then leaves the stack as it is. `spacingBetweenSlices` is the
    /// first slice's, used only when the slices have no position.
    public init?(orientation1: [Double], orientation2: [Double], origin1: [Double], origin2: [Double],
                 firstOrigin: [Double], spacingBetweenSlices: Double, flipNow: Bool) {
        guard let spacing = SliceStackSpacing(orientation1: orientation1, orientation2: orientation2,
                                              origin1: origin1, origin2: origin2) else { return nil }
        var interval = spacing.interval, interval3D = spacing.interval3D
        var stacks = false
        if interval == 0 && firstOrigin[0] == 0 && firstOrigin[1] == 0 && firstOrigin[2] == 0 {
            interval = spacingBetweenSlices
            if interval != 0 {
                interval3D = -interval
                stacks = true
            }
        }
        self.spacing = spacing
        stacksWithoutPosition = stacks
        self.interval = interval
        self.interval3D = interval3D
        flipsNow = flipNow
    }

    /// A descending stack is reversed for 3D texture mapping, when the viewer
    /// flips now (and its slices all have the same size).
    public var reversesStack: Bool { interval < 0 && flipsNow }

    /// The interval every slice gets when the stack is not reversed.
    public var sliceInterval: Double {
        SliceStackSpacing.sliceInterval(interval: interval, interval3D: interval3D)
    }

    /// The interval every slice gets once the stack is reversed.
    public var reversedSliceInterval: Double {
        SliceStackSpacing.reversedSliceInterval(interval: interval, interval3D: interval3D)
    }

    // MARK: Slices without a position

    /// The orientation slices without a position get, as the viewer has always
    /// written it (a normal of 1, 0, 1, which the slice recomputes).
    public static let orientationWithoutPosition: [Float] = [1, 0, 0, 0, 1, 0, 1, 0, 1]

    /// The origins of `count` slices without a position, stacked along z
    /// `interval` apart from 0, 0, 0, accumulated in float.
    public static func originsWithoutPosition(count: Int, interval: Double) -> [[Float]] {
        var position: [Float] = [0, 0, 0]
        var origins: [[Float]] = []
        origins.reserveCapacity(count)
        for _ in 0..<count {
            origins.append(position)
            position[2] = Float(Double(position[2]) + interval)
        }
        return origins
    }

    // MARK: Gantry tilt

    /// What the angle between a stack's slices and its stacking direction says.
    public enum GantryTilt: Sendable, Equatable {
        /// 90 degrees or more: nothing is recorded.
        case none
        /// Below the tolerance: recorded, the series stays a volume; logged
        /// when above 0.001 degrees.
        case tolerated(degrees: Double)
        /// Above the tolerance: not a real 3D data set.
        case tilted(degrees: Double)

        public var degrees: Double? {
            switch self {
            case .none: return nil
            case .tolerated(let degrees), .tilted(let degrees): return degrees
            }
        }

        public var isTilted: Bool {
            if case .tilted = self { return true }
            return false
        }
    }

    /// `static float deg2rad = M_PI/180.0` of the former viewer: computed in
    /// double, kept as a float.
    static let degreesToRadians = Float(Double.pi / 180.0)

    /// The tilt of a stack from the angle, in radians, between the step from
    /// a slice to the next and the slices' normal, against the tolerance of the
    /// "MinimumTitledGantryTolerance" preference, in degrees.
    public static func gantryTilt(angle radians: Double, tolerance: Float) -> GantryTilt {
        let degrees = abs(radians) / Double(degreesToRadians)
        guard degrees < 90 else { return .none }
        return degrees > Double(tolerance) ? .tilted(degrees: degrees) : .tolerated(degrees: degrees)
    }

    // MARK: The slice interval sheet

    /// The geometry the slice interval sheet gives every slice of every time
    /// point: the spacing, the orientation typed (its normal recomputed), and
    /// origins `interval` apart along the normal's dominant axis (z when none
    /// dominates), from the origin typed, accumulated in float across the time
    /// points as the viewer always did.
    public struct Sheet: Sendable, Equatable {
        public let interval: Float
        public let spacingX: Float
        public let spacingY: Float
        /// The nine cosines given to every slice.
        public let orientation: [Float]
        /// The axis the origins move along.
        public let axis: Int
        /// The origin of the first slice of the first time point.
        public let origin: [Float]

        /// nil when a value is missing or not a finite number, a spacing is not
        /// positive, or the interval is 0 for a series of more than one slice.
        /// `vectors` are the six cosines typed, `origin` the three coordinates.
        public init?(interval: Float?, spacingX: Float?, spacingY: Float?, vectors: [Float?], origin: [Float?], sliceCount: Int) {
            guard let interval, let spacingX, let spacingY, spacingX > 0, spacingY > 0,
                  interval != 0 || sliceCount <= 1, vectors.count == 6, origin.count == 3 else { return nil }
            let typed = vectors.compactMap { $0 }, position = origin.compactMap { $0 }
            guard typed.count == 6, position.count == 3 else { return nil }
            var v = typed + [0, 0, 0]
            let normal = SliceStack.normal(v)
            v[6] = normal[0]; v[7] = normal[1]; v[8] = normal[2]
            self.interval = interval
            self.spacingX = spacingX
            self.spacingY = spacingY
            orientation = v
            axis = SliceStack.dominantAxis(v[6], v[7], v[8]) ?? 2
            self.origin = position
        }

        /// The pixel ratio of the spacings.
        public var pixelRatio: Double { Double(spacingY / spacingX) }

        /// The origins of `counts[t]` slices of each time point t, in order.
        public func origins(sliceCounts counts: [Int]) -> [[[Float]]] {
            var o = origin
            return counts.map { count in
                (0..<count).map { _ in
                    defer { o[axis] += interval }
                    return o
                }
            }
        }
    }
}
