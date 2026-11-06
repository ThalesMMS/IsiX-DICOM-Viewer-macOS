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

// The rules of the 2D viewer's brush tools: the morphology filter a menu
// item asks for, and how the contour of a brush ROI is resampled into the
// points of a polygon.

public enum ROIBrushMorphology {

    /// The filter of the brush filter menu item tagged `tag` (0 erode,
    /// 1 dilate, 2 close, 3 open), nil for another tag.
    public static func action(forTag tag: Int) -> String? {
        switch tag {
        case 0: return "erode"
        case 1: return "dilate"
        case 2: return "close"
        case 3: return "open"
        default: return nil
        }
    }
}

/// One point of a resampled contour: the point at `ratio` from the contour
/// point `from` to the contour point `to`.
public struct ROIContourSample: Equatable, Sendable {
    public var from: Int
    public var to: Int
    public var ratio: Float

    public init(from: Int, to: Int, ratio: Float) {
        self.from = from
        self.to = to
        self.ratio = ratio
    }
}

public enum ROIContourResampling {

    /// The `numPoints` points, evenly spread along a closed contour of
    /// `contourCount` points, of the polygon a brush ROI becomes: point `i`
    /// is at `i × contourCount / numPoints` along the contour, in float as
    /// the Objective-C computed it, between that contour point and the next
    /// (the first after the last).
    public static func samples(contourCount: Int, numPoints: Int) -> [ROIContourSample] {
        var samples: [ROIContourSample] = []
        guard numPoints > 0 else { return samples }
        samples.reserveCapacity(numPoints)
        for i in 0 ..< numPoints {
            let x = Float(UInt(bitPattern: i &* contourCount)) / Float(numPoints)
            let xint = Int(Int32(x))
            let next = xint + 1 == contourCount ? 0 : xint + 1
            samples.append(ROIContourSample(from: xint, to: next, ratio: x - Float(Int32(xint))))
        }
        return samples
    }
}
