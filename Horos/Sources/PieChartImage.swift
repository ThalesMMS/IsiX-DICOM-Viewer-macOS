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

//  Inspired by the LittleYellowGuy Project
//
//  Created by Daniel Jalkut on 11/10/06.
//  Copyright 2006 Red Sweater Software. All rights reserved.

import AppKit

// NSImage (PieChartImage) and NSBezierPath (RSPieChartUtilities) are
// implemented in Swift: the selectors and <Horos/PieChartImage.h>
// are those of the former categories.

public extension NSImage {
    @objc(pieChartImageWithPercentage:)
    class func pieChartImage(withPercentage percentage: Float) -> NSImage! {
        let fullColor = NSColor(calibratedRed: 0.4, green: 0.8, blue: 0.2, alpha: 1.0)
        let insideColor = NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        let borderColor = NSColor(calibratedRed: 1.0, green: 0.4, blue: 0.0, alpha: 1.0)
        return NSImage.pieChartImage(withPercentage: percentage, borderColor: borderColor, insideColor: insideColor, fullColor: fullColor)
    }

    /// The former method allocated `[self alloc]`, the class it was sent to.
    /// Swift cannot allocate a subclass through an initializer that is not
    /// `required`, so the image is an NSImage; the application only sends it
    /// to NSImage.
    @objc(pieChartImageWithPercentage:borderColor:insideColor:fullColor:)
    class func pieChartImage(withPercentage percentage: Float, borderColor: NSColor!, insideColor: NSColor!, fullColor: NSColor!) -> NSImage! {
        let pieRect = NSMakeRect(0, 0, 14.0, 14.0)
        let pieImage = NSImage(size: pieRect.size, flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let targetRect = NSInsetRect(pieRect, 2.0, 2.0)

            let circle = NSBezierPath(ovalIn: targetRect)

            if percentage == 0 {
                // Fill the circle
                insideColor?.set()
                circle.fill()

                // Stroke the circle
                circle.lineWidth = 1.0
                borderColor?.set()
                circle.stroke()
            } else if percentage == 1 {
                // Fill the circle
                fullColor?.set()
                circle.fill()

                // Stroke the circle
                circle.lineWidth = 1.0
                fullColor?.set()
                circle.stroke()
            } else {
                // Fill the circle
                borderColor?.set()
                circle.fill()

                // Stroke the circle
                circle.lineWidth = 1.0
                borderColor?.set()
                circle.stroke()

                let startingAngle = Float((1.0 - Double(percentage) * 4.0) * 90.0)
                let pie = NSBezierPath.bezierPathForPie(in: targetRect, withWedgeRemovedFromStartingAngle: startingAngle, toEndingAngle: 90.0)

                // Fill the pie
                insideColor?.set()
                pie?.fill()

            }

            return true
        }

        return pieImage
    }
}

public extension NSBezierPath {
    @objc(bezierPathForPieInRect:withWedgeRemovedFromStartingAngle:toEndingAngle:)
    class func bezierPathForPie(in containerRect: NSRect, withWedgeRemovedFromStartingAngle startAngle: Float, toEndingAngle endAngle: Float) -> NSBezierPath! {
        // Creating an arc by swapping the start and finish angles
        let pieRect = NSInsetRect(containerRect, 1.0, 1.0)
        let piePath = NSBezierPath()

        let pieRadius = Float(NSWidth(pieRect) / 2.0) // assume a square rect
        let centerPoint = NSMakePoint(NSMidX(pieRect), NSMidY(pieRect))
        piePath.appendArc(withCenter: centerPoint, radius: CGFloat(pieRadius), startAngle: CGFloat(endAngle), endAngle: CGFloat(startAngle))
        piePath.line(to: centerPoint)
        piePath.close()
        return piePath
    }
}
