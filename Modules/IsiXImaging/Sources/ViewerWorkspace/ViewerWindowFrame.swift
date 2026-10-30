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

/// The arithmetic of a 2D viewer's window frame: the frame a tiling gives it,
/// the zoom button's frame, and the rows and columns of the tiling menu.
public enum ViewerWindowFrame {

    /// How a window moves to a frame of the tiling.
    public struct Change: Equatable, Sendable {
        /// The frame asked for, each value rounded to a whole point (as a float).
        public let frame: CGRect
        /// No value of the frame moves by a point or more.
        public let identical: Bool
        /// The move is animated: asked for, and some value moves by 5 points or more.
        public let animate: Bool
    }

    /// The move of a window from `current` to `frame`, animated if `animate`
    /// asks for it and the move is not too small to show.
    public static func change(from current: CGRect, to frame: CGRect, animate: Bool) -> Change {
        func whole(_ value: CGFloat) -> CGFloat { CGFloat(roundf(Float(value))) }
        let target = CGRect(x: whole(frame.origin.x), y: whole(frame.origin.y), width: whole(frame.size.width), height: whole(frame.size.height))

        let differences = [current.origin.y - target.origin.y, current.origin.x - target.origin.x,
                           current.size.height - target.size.height, current.size.width - target.size.width].map { abs($0) }
        // The largest difference, kept as a float.
        var largest: Float = 0
        for difference in differences where Float(difference) > largest { largest = Float(difference) }

        return Change(frame: target, identical: !differences.contains { $0 >= 1.0 }, animate: animate && largest >= 5)
    }

    /// The zoom button's frame: the usable rect of the screen, or back to the
    /// standard frame when the window already fills the screen (within 20
    /// points). A window without a standard frame takes its current one.
    public static func standardFrame(current: CGRect, screen: CGRect, standard: CGRect) -> (frame: CGRect, standard: CGRect) {
        let standard = (standard.size.width <= 0 || standard.size.height <= 0) ? current : standard
        if current.size.height >= screen.size.height - 20 && current.size.width >= screen.size.width - 20 {
            return (standard, standard)
        }
        return (screen, standard)
    }

    /// The rows and columns of a tiling menu item: its tag is rows × 10 +
    /// columns, and the columns repeat on each viewer screen.
    public static func tiling(tag: Int, screens: Int) -> (rows: Int32, columns: Int32) {
        let tag = Int32(truncatingIfNeeded: tag)
        return (tag / 10, (tag % 10) &* Int32(truncatingIfNeeded: screens))
    }
}
