/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// Where another viewer's slice cuts the receiver's, in the coordinates of
/// its slice: the cut, the two ends of the source's series when its images
/// share one orientation, the far end of a thick slab, the slab's thickness
/// and the direction of the cut. The view keeps them as float[2][3] arrays,
/// which its drawing and the subclasses' -drawCrossLines: read.
public struct ReferenceLines: Sendable, Equatable {

    /// A line from (x0, y0, z0) to (x1, y1, z1); not drawn when x0 is infinite.
    public struct Line: Sendable, Equatable {
        public var x0: Float, y0: Float, z0: Float, x1: Float, y1: Float, z1: Float

        public init(x0: Float, y0: Float, z0: Float, x1: Float, y1: Float, z1: Float) {
            self.x0 = x0; self.y0 = y0; self.z0 = z0; self.x1 = x1; self.y1 = y1; self.z1 = z1
        }

        /// The six floats of a float[2][3].
        public init(_ values: UnsafePointer<Float>) {
            self.init(x0: values[0], y0: values[1], z0: values[2], x1: values[3], y1: values[4], z1: values[5])
        }

        public func write(to values: UnsafeMutablePointer<Float>) {
            values[0] = x0; values[1] = y0; values[2] = z0; values[3] = x1; values[4] = y1; values[5] = z1
        }

        public var isDrawn: Bool { x0 != .infinity }
    }

    public var cut: Line
    public var seriesStart: Line
    public var seriesEnd: Line
    public var farEnd: Line
    public var thickness: Float
    public var direction: SIMD3<Float>

    public init(cut: Line, seriesStart: Line, seriesEnd: Line, farEnd: Line, thickness: Float, direction: SIMD3<Float>) {
        self.cut = cut
        self.seriesStart = seriesStart
        self.seriesEnd = seriesEnd
        self.farEnd = farEnd
        self.thickness = thickness
        self.direction = direction
    }

    /// Whether there is a cut to draw: a line, along a direction (parallel
    /// planes have none).
    public var hasLine: Bool { cut.isDrawn && direction != .zero }

    /// No line: each line marked not drawn and no direction; the other
    /// values are kept, as the view kept them.
    public mutating func invalidate() {
        cut.x0 = .infinity
        farEnd.x0 = .infinity
        seriesStart.x0 = .infinity
        seriesEnd.x0 = .infinity
        direction = .zero
    }
}
