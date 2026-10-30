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

// The fusion of a 2D viewer's slices with their neighbours (the "thick slab"
// of its toolbar): the mode the series allows and the number of slices fused
// as the user changes it step by step.

public enum StackFusion {

    /// The modes 4 and 5 make a volume rendering of the slab (ThickSlabController);
    /// 4 flips it.
    public static func isVolumeRendering(_ mode: Int) -> Bool { mode == 4 || mode == 5 }
    public static func flipsVolumeRendering(_ mode: Int) -> Bool { mode == 4 }

    /// The mode a series gets for `requested`: none (0) when its images do not
    /// all have the size of the last one.
    public static func mode(_ requested: Int, imageSizes: [(width: Int, height: Int)]) -> Int {
        guard requested != 0, let last = imageSizes.last else { return requested }
        for size in imageSizes where size.width != last.width || size.height != last.height { return 0 }
        return requested
    }

    /// The number of fused slices after `steps` steps of the scroll wheel or the
    /// keyboard, or nil when it does not change. `maximum` is the most the
    /// slider and every phase allow (nothing changes below 2). An inactive
    /// fusion counts as one slice and always starts at two; an active one moves
    /// by at most 128 slices at a time, within 1 … maximum.
    public static func thickness(afterSteps steps: Int, active: Bool, current: Int, maximum: Int) -> Int? {
        guard steps != 0, maximum >= 2 else { return nil }
        let current = active ? current : 1
        let next: Int
        if active {
            let (sum, overflow) = current.addingReportingOverflow(max(-128, min(128, steps)))
            next = max(1, min(maximum, overflow ? (steps > 0 ? Int.max : Int.min) : sum))
        } else {
            next = steps > 0 ? 2 : 1
        }
        return next == current ? nil : next
    }
}
