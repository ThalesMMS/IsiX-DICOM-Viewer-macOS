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

extension CGSize {
    /// The size scaled, in both dimensions, by the smaller of the ratios of
    /// `target` to it, so that it fits in `target`; `target` itself when the
    /// two are equal. A zero dimension gives an infinite or NaN ratio, as the
    /// division gives it.
    public func scaledProportionally(toFit target: CGSize) -> CGSize {
        if width == target.width && height == target.height {
            return target
        }
        let widthRatio = target.width / width
        let heightRatio = target.height / height
        let factor = widthRatio < heightRatio ? widthRatio : heightRatio
        return CGSize(width: factor * width, height: factor * height)
    }
}

extension CGRect {
    /// The rectangle with its origin measured from the other edge of `bounds`
    /// (from the top instead of the bottom, or back): a rectangle drawn in a
    /// flipped view.
    public func flipped(in bounds: CGRect) -> CGRect {
        var rect = self
        rect.origin.y = bounds.size.height - origin.y - size.height
        return rect
    }
}
