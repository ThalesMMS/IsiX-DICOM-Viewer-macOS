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

import AppKit

// NSColor (N2) is implemented in Swift since #709; the selectors and
// <Horos/NSColor+N2.h> are those of the former category.

public extension NSColor {

    @objc(isEqualToColor:)
    func isEqualToColor(_ color: NSColor?) -> Bool {
        isEqualToColor(color, alphaThreshold: 0)
    }

    @objc(isEqualToColor:alphaThreshold:)
    func isEqualToColor(_ color: NSColor?, alphaThreshold: CGFloat) -> Bool {
        guard let color else { return false }
        if color === self { return true }

        let c1: NSColor?, c2: NSColor?

        if colorSpace.isEqual(color.colorSpace) {
            c1 = self; c2 = color
        } else {
            c1 = usingColorSpaceName(.calibratedRGB)
            c2 = color.usingColorSpaceName(.calibratedRGB)
        }

        // The Objective-C read past empty arrays when a colour did not convert.
        guard let c1, let c2, c1.numberOfComponents > 0 else { return false }

        let numberOfComponents = c1.numberOfComponents
        var c1components = [CGFloat](repeating: 0, count: numberOfComponents)
        var c2components = [CGFloat](repeating: 0, count: max(numberOfComponents, c2.numberOfComponents))
        c1.getComponents(&c1components); c2.getComponents(&c2components)

        if c1components[numberOfComponents - 1] <= alphaThreshold || c2components[numberOfComponents - 1] <= alphaThreshold {
            return true
        }

        for i in 0..<(numberOfComponents - 1) where c1components[i] != c2components[i] {
//          NSLog(@"component %d not equal in [%@] and [%@]", i, [c1 description], [c2 description]);
            return false
        }

        return true
    }
}
