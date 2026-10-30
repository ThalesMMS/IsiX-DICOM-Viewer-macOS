/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import CoreGraphics
import Foundation

/// The geometry of the ROIs an RT structure set describes: which contours are
/// read, on which image plane a contour lies and where its points fall in that
/// image (-[DCMPix createROIsFromRTSTRUCT:inDatabase:]).
///
/// The arithmetic is in Float, as the Objective-C did it; where clang fused a
/// multiplication into the addition that followed it (`-ffp-contract=on`),
/// so does this, with `addingProduct`.
public enum RTStructContours {
    /// The contour types made into ROIs: closed and interpolated planar outlines and points.
    public static func isSupported(_ type: String?) -> Bool {
        type == "CLOSED_PLANAR" || type == "INTERPOLATED_PLANAR" || type == "POINT"
    }

    /// Whether `declared` (Number of Contour Points) agrees with the `coordinates`
    /// Contour Data holds: three a point, and at least one point.
    public static func pointCountMatches(declared: Int32, coordinates: Int) -> Bool {
        declared > 0 && coordinates / 3 == Int(declared) && coordinates % 3 == 0
    }

    /// ROI Display Color (0...255 each) as the 16-bit components of an RGBColor.
    public static func colour(_ component: Float) -> UInt16 {
        // value * 65535 in Float, then / 256 in double, made an int and kept to 16 bits.
        let scaled = Double(component * 65535) / 256.0
        return UInt16(truncatingIfNeeded: NonFinite.int32(scaled))
    }

    /// The progress after `structure` of `count` ROI contours: 10% to 100%.
    public static func progress(after structure: UInt32, of count: Int32) -> Double {
        let percent = (10 as Float).addingProduct(Float(structure) / Float(count), 90)
        return Double(percent) / 100.0
    }

    /// An image's plane, from its Image Position, Image Orientation, Pixel
    /// Spacing and Slice Thickness.
    public struct Plane {
        public let x: Float, y: Float, z: Float
        /// The two direction cosines and the normal they make.
        public let orientation: [Float]
        /// The pixel spacing: across a row (Pixel Spacing's second value), then down a column.
        public let spacingX: Float, spacingY: Float
        /// How far from the plane a contour's first point may be and lie on it.
        public let criterion: Float

        /// Nil for a plane whose pixels have no size.
        public init?(position: [Float], orientation cosines: [Float], rowSpacing: Float, columnSpacing: Float, thickness: Float) {
            guard position.count >= 3, cosines.count >= 6 else { return nil }
            x = position[0]
            y = position[1]
            z = position[2]
            spacingX = columnSpacing
            spacingY = rowSpacing
            if spacingX == 0 || spacingY == 0 { return nil }
            var o = Array(cosines.prefix(6))
            o.append((-(o[2] * o[4])).addingProduct(o[1], o[5]))
            o.append((-(o[0] * o[5])).addingProduct(o[2], o[3]))
            o.append((-(o[1] * o[3])).addingProduct(o[0], o[4]))
            orientation = o
            var limit = Float(Double(thickness) * 0.4)
            if limit <= 0 { limit = 0.1 }
            criterion = limit
        }

        /// The image's origin, as the ROI takes it.
        public var origin: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }

        /// Whether a point (patient coordinates, mm) is on this plane: nearer to it than the criterion.
        public func contains(_ px: Float, _ py: Float, _ pz: Float) -> Bool {
            let t0 = px - x, t1 = py - y, t2 = pz - z
            let distance = abs((t1 * orientation[7]).addingProduct(t0, orientation[6]).addingProduct(t2, orientation[8]))
            return distance < criterion
        }

        /// `count` points (x, y, z each in `coordinates`) in the image's pixels, where
        /// the image position is the centre of the first pixel, at (0.5, 0.5).
        public func points(_ coordinates: [Float], count: Int) -> [CGPoint] {
            let rx = 1 / spacingX, ry = 1 / spacingY
            var result: [CGPoint] = []
            result.reserveCapacity(count)
            for index in 0..<count {
                let t0 = coordinates[3 * index] - x
                let t1 = coordinates[3 * index + 1] - y
                let t2 = coordinates[3 * index + 2] - z
                let u = (t1 * orientation[1]).addingProduct(t0, orientation[0]).addingProduct(t2, orientation[2])
                let v = (t1 * orientation[4]).addingProduct(t0, orientation[3]).addingProduct(t2, orientation[5])
                result.append(CGPoint(x: CGFloat((0.5 as Float).addingProduct(u, rx)), y: CGFloat((0.5 as Float).addingProduct(v, ry))))
            }
            return result
        }
    }
}

/// The conversion of a double to an int as arm64 does it (`fcvtzs`): toward
/// zero, saturated at the ends, NaN zero.
enum NonFinite {
    static func int32(_ d: Double) -> Int32 {
        if d.isNaN { return 0 }
        if d >= 2_147_483_647.0 { return Int32.max }
        if d <= -2_147_483_648.0 { return Int32.min }
        return Int32(d)
    }
}
