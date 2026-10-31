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

import Accelerate

/// What the viewer does to its series to show it in another orientation: a
/// reslice of every time point along the rows (direction 0) or the columns
/// (direction 1) of its slices, then the steps, in order, that bring the new
/// slices upright.
public struct SeriesReorientation: Sendable, Equatable {

    /// A transform of every slice of the resliced series.
    public enum Step: Sendable, Equatable {
        /// Upside down (-vertFlipDataSet:).
        case flipVertically
        /// Left to right (-horzFlipDataSet:).
        case flipHorizontally
        /// A quarter turn clockwise (-rotateDataSet: kRotate90DegreesClockwise).
        case rotateClockwise

        /// The vImage rotation constant of the quarter turn.
        public static let quarterTurnConstant = Int32(kRotate90DegreesClockwise)
    }

    /// 0: the new slices are the rows of the stack; 1: its columns.
    public let resliceDirection: Int
    public let steps: [Step]

    /// From the orientation tool `current` to `target`, by their tags; nil when
    /// they are the same, or when either is not a tool, in which case the
    /// viewer reslices nothing.
    public init?(from current: Int, to target: Int) {
        guard let from = OrientationTool(rawValue: Int16(truncatingIfNeeded: current)), Int(from.rawValue) == current,
              let to = OrientationTool(rawValue: Int16(truncatingIfNeeded: target)), Int(to.rawValue) == target else { return nil }
        self.init(from: from, to: to)
    }

    /// From the orientation tool `current` to `target`; nil when they are the same.
    public init?(from current: OrientationTool, to target: OrientationTool) {
        switch (current, target) {
        case (.axial, .coronal): self.init(direction: 0, [])
        case (.axial, .sagittal): self.init(direction: 1, [])
        case (.coronal, .axial): self.init(direction: 0, [.flipVertically])
        case (.coronal, .sagittal): self.init(direction: 1, [.rotateClockwise])
        case (.sagittal, .axial): self.init(direction: 0, [.rotateClockwise, .flipHorizontally])
        case (.sagittal, .coronal): self.init(direction: 1, [.rotateClockwise, .flipHorizontally])
        case (.axial, .axial), (.coronal, .coronal), (.sagittal, .sagittal): return nil
        }
    }

    private init(direction: Int, _ steps: [Step]) {
        resliceDirection = direction
        self.steps = steps
    }

    /// The orientation a viewer gives a slice of the series once `step` is
    /// done to it, from the slice's nine cosines; nil for the quarter turn,
    /// whose orientation SeriesTransforms.rotated gives with its pixels.
    public static func orientation(_ o: [Double], after step: Step) -> [Double]? {
        switch step {
        case .flipVertically: return SeriesTransforms.verticallyFlipped(o)
        case .flipHorizontally: return SeriesTransforms.horizontallyFlipped(o)
        case .rotateClockwise: return nil
        }
    }

    /// The pixel of a flipped slice of `width`×`height` whose position becomes
    /// its new origin: the last row of a slice turned upside down, the last
    /// column of one turned left to right; nil for the quarter turn
    /// (SeriesRotation.originPixel).
    public static func originPixel(after step: Step, width: Int, height: Int) -> (x: Double, y: Double)? {
        switch step {
        case .flipVertically: return (0, Double(-height + 1))
        case .flipHorizontally: return (Double(-width + 1), 0)
        case .rotateClockwise: return nil
        }
    }
}
