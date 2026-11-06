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

import Cocoa

/// Where the magnets of the viewer windows put a window: the frames of the
/// other magnetic viewers on its screen, and the screen's usable area, pull
/// its edges. The reach is a float, as it was.
enum MagneticWindowSnapping {

    /// The frame of a window the user is resizing to `myFrame`: its right
    /// and bottom edges (y up: the origin) stick to a magnet within 30
    /// points, then to the last magnet's far edges (the screen's, last of
    /// `magnets`), as the former code compared with that rectangle.
    static func resized(_ myFrame: NSRect, magnets: [NSRect]) -> NSRect {
        var gravityX: Float = 30
        var gravityY: Float = 30
        var dstFrame = myFrame
        var frame = NSRect.zero

        for magnet in magnets {
            frame = magnet

            /* horizontal magnet */
            if abs(frame.minX - myFrame.maxX) <= CGFloat(gravityX) { // LEFT
                gravityX = Float(abs(frame.minX - myFrame.maxX))
                dstFrame.size.width = frame.origin.x - myFrame.origin.x
            }

            /* vertical magnet */
            if abs(frame.minY - myFrame.minY) <= CGFloat(gravityY) { //TOP
                gravityY = Float(abs(frame.minY - myFrame.minY))

                let previous = dstFrame
                dstFrame.origin.y = frame.origin.y
                dstFrame.size.height = dstFrame.size.height - (dstFrame.origin.y - previous.origin.y)
            }
        }

        for _ in magnets {
            if abs(frame.maxX - myFrame.maxX) <= CGFloat(gravityX) { //RIGHT
                gravityX = Float(abs(frame.maxX - myFrame.maxX))
                dstFrame.size.width = frame.origin.x + frame.size.width - myFrame.origin.x
            }

            if abs(frame.maxY - myFrame.minY) <= CGFloat(gravityY) { // BOTTOM
                gravityY = Float(abs(frame.maxY - myFrame.minY))

                let previous = dstFrame
                dstFrame.origin.y = frame.origin.y + frame.size.height
                dstFrame.size.height = dstFrame.size.height - (dstFrame.origin.y - previous.origin.y)
            }
        }

        return dstFrame
    }

    /// The frame of a window dropped at `myFrame`: each of its edges sticks
    /// to the nearest magnet edge within a quarter of its size.
    static func dropped(_ myFrame: NSRect, magnets: [NSRect]) -> NSRect {
        var gravityX = Float(myFrame.size.width / 4)
        var gravityY = Float(myFrame.size.height / 4)
        var dstFrame = myFrame

        for frame in magnets {
            /* horizontal magnet */
            if abs(frame.minX - myFrame.minX) <= CGFloat(gravityX) {
                gravityX = Float(abs(frame.minX - myFrame.minX))
                dstFrame.origin.x = frame.origin.x
            }
            if abs(frame.minX - myFrame.maxX) <= CGFloat(gravityX) {
                gravityX = Float(abs(frame.minX - myFrame.maxX))
                dstFrame.origin.x = myFrame.origin.x + frame.minX - myFrame.maxX
            }
            if abs(frame.maxX - myFrame.minX) <= CGFloat(gravityX) {
                gravityX = Float(abs(frame.maxX - myFrame.minX))
                dstFrame.origin.x = frame.maxX
            }
            if abs(frame.maxX - myFrame.maxX) <= CGFloat(gravityX) {
                gravityX = Float(abs(frame.maxX - myFrame.maxX))
                dstFrame.origin.x = myFrame.origin.x + frame.maxX - myFrame.maxX
            }

            /* vertical magnet */
            if abs(frame.minY - myFrame.minY) <= CGFloat(gravityY) {
                gravityY = Float(abs(frame.minY - myFrame.minY))
                dstFrame.origin.y = frame.origin.y
            }
            if abs(frame.minY - myFrame.maxY) <= CGFloat(gravityY) {
                gravityY = Float(abs(frame.minY - myFrame.maxY))
                dstFrame.origin.y = myFrame.origin.y + frame.minY - myFrame.maxY
            }
            if abs(frame.maxY - myFrame.minY) <= CGFloat(gravityY) {
                gravityY = Float(abs(frame.maxY - myFrame.minY))
                dstFrame.origin.y = frame.maxY
            }
            if abs(frame.maxY - myFrame.maxY) <= CGFloat(gravityY) {
                gravityY = Float(abs(frame.maxY - myFrame.maxY))
                dstFrame.origin.y = myFrame.origin.y + frame.maxY - myFrame.maxY
            }
        }

        return dstFrame
    }

    /// Whether a window dropped at `myFrame` lands on the window at `frame`,
    /// within 30 points of its top left corner: the two swap places.
    static func swaps(_ frame: NSRect, with myFrame: NSRect) -> Bool {
        return abs(frame.origin.x - myFrame.origin.x) < 30 && abs(frame.maxY - myFrame.maxY) < 30
    }
}
