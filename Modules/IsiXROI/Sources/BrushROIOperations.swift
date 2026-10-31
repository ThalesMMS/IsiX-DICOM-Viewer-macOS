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

/// What the 2D viewer does to its brush ROIs, in values: the morphology
/// filter a menu item or a plugin names, the merge of several brushes into
/// one and the polygon a brush becomes. The masks themselves are
/// ROIBrushMask values, which the ROIs hold and merge.
public struct BrushROIOperations: Sendable {

    /// A morphology filter of a brush mask, by a disc of a given radius.
    public enum Morphology: String, Sendable, CaseIterable {
        case erode
        case dilate
        case close
        case open

        /// The filter of the brush filter menu item tagged `tag` (0 erode,
        /// 1 dilate, 2 close, 3 open), nil for another tag.
        public init?(tag: Int) {
            guard let name = ROIBrushMorphology.action(forTag: tag) else { return nil }
            self.init(rawValue: name)
        }
    }

    /// The merge of brushes: of ROIs whose `isBrush` says which are
    /// brushes, the last brush receives the masks of the others, which are
    /// then removed; nil when there is no brush.
    public static func mergePlan(isBrush: [Bool]) -> (target: Int, merged: [Int])? {
        let brushes = isBrush.indices.filter { isBrush[$0] }
        guard let target = brushes.last else { return nil }
        return (target, Array(brushes.dropLast()))
    }

    /// The `numPoints` points of the closed polygon along `contour`, the
    /// contour of a brush mask in mask coordinates, moved by the corner of
    /// the mask in the image: evenly spread along the contour as
    /// ROIContourResampling places them, each `between` two contour points
    /// (ROIPlanarGeometry's interpolation, or the one the ROI class answers).
    /// None when the contour is empty.
    public static func polygonPoints(contour: [CGPoint], maskCorner: (x: Int32, y: Int32), numPoints: Int,
                                     between: (CGPoint, CGPoint, Float) -> CGPoint = ROIPlanarGeometry.point(between:and:ratio:)) -> [CGPoint] {
        guard !contour.isEmpty else { return [] }
        let dx = CGFloat(Float(maskCorner.x)), dy = CGFloat(Float(maskCorner.y))
        let moved = contour.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return ROIContourResampling.samples(contourCount: moved.count, numPoints: numPoints).map {
            between(moved[$0.from], moved[$0.to], $0.ratio)
        }
    }
}
