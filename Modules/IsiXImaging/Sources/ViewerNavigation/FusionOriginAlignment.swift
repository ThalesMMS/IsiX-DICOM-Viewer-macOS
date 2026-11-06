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

import CoreGraphics
import Foundation

// "Re-sync origin" of a fused 2D viewer: when the two series of a fusion do not
// line up, each slice of the viewer gets the pixel spacing and the origin that
// put it where the fused (blending) series is shown, at the same place on
// screen. The arithmetic is the viewer's, operation for operation: the
// products and sums of the orientation are contracted as clang contracts them
// (a*b + c*d + e*f as fma(e, f, fma(a, b, c*d))), the rest in double, stored
// in float where the viewer stored it in float.

public enum FusionOriginAlignment {

    /// One series' side of the alignment: its current slice (origin, size,
    /// spacing) and its view (pan, scale, and the spacing the view reports).
    public struct View: Sendable {
        public var origin: (x: Double, y: Double, z: Double)
        public var width: Int, height: Int
        public var pixelSpacingX: Double, pixelSpacingY: Double
        public var viewOrigin: CGPoint
        public var scale: Float
        public var viewPixelSpacingX: Double, viewPixelSpacingY: Double

        public init(origin: (x: Double, y: Double, z: Double), width: Int, height: Int, pixelSpacingX: Double, pixelSpacingY: Double,
                    viewOrigin: CGPoint, scale: Float, viewPixelSpacingX: Double, viewPixelSpacingY: Double) {
            self.origin = origin
            self.width = width
            self.height = height
            self.pixelSpacingX = pixelSpacingX
            self.pixelSpacingY = pixelSpacingY
            self.viewOrigin = viewOrigin
            self.scale = scale
            self.viewPixelSpacingX = viewPixelSpacingX
            self.viewPixelSpacingY = viewPixelSpacingY
        }
    }

    /// The new spacing of a slice of the viewer: its current image's spacing,
    /// times the fused view's millimetres per point over the viewer's.
    public static func pixelSpacing(current: Double, fusedView: Double, fusedScale: Float, scale: Float) -> Double {
        current * (fusedView / Double(fusedScale)) / (current / Double(scale))
    }

    /// The origin, rotated into the slice's orientation (`vectors`, the 9
    /// direction cosines), in float.
    public static func rotated(_ origin: (x: Double, y: Double, z: Double), _ vectors: [Float]) -> (Float, Float, Float) {
        func row(_ r: Int) -> Float {
            let a = Double(vectors[3 * r]), b = Double(vectors[3 * r + 1]), c = Double(vectors[3 * r + 2])
            return Float((origin.y * b).addingProduct(origin.x, a).addingProduct(origin.z, c))
        }
        return (row(0), row(1), row(2))
    }

    /// The new origin of a slice whose origin is `origin`, size `width` x
    /// `height`, new spacing `spacingX`, `spacingY` and orientation `vectors`;
    /// `fused` is the fused view, `view` the viewer's own (its pan and scale),
    /// `zShift` the distance between the two current slices' locations.
    public static func origin(_ origin: (x: Double, y: Double, z: Double), vectors: [Float], width: Int, height: Int,
                              spacingX: Double, spacingY: Double, fused: View, view: View, zShift: Float) -> (Float, Float, Float) {
        let slice = rotated(origin, vectors)
        let fusedSlice = rotated(fused.origin, vectors)

        let offsetX = Double(slice.0) + Double(width) * spacingX / 2.0
            - (Double(fusedSlice.0) + Double(fused.width) * fused.pixelSpacingX / 2.0)
        let offsetY = Double(slice.1) + Double(height) * spacingY / 2.0
            - (Double(fusedSlice.1) + Double(fused.height) * fused.pixelSpacingY / 2.0)

        var o = (Float(origin.x), Float(origin.y), Float(origin.z))
        o.0 = Float(Double(o.0) - ((Double(fused.viewOrigin.x) * fused.pixelSpacingX / Double(fused.scale)
                                    - Double(view.viewOrigin.x) * spacingX / Double(view.scale)) + offsetX))
        o.1 = Float(Double(o.1) + ((Double(fused.viewOrigin.y) * fused.pixelSpacingY / Double(fused.scale)
                                    - Double(view.viewOrigin.y) * spacingY / Double(view.scale)) - offsetY))
        o.2 = o.2 + zShift
        return o
    }
}
