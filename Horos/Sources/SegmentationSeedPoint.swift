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

/// The seed point the calcium scoring window and the region growing window
/// take from a click in their viewer: what they show of it and the cross they
/// draw on it.
enum SegmentationSeedPoint {
    /// The texts of the clicked pixel (`x`, `y`) of the viewer's current image:
    /// its position in pixels, its position in patient millimetres (the pixel's
    /// centre) and its value.
    @MainActor
    static func texts(viewer: ViewerController, x: Int32, y: Int32) -> (pixel: String, world: String, value: String) {
        var location: [Float] = [0, 0, 0]
        let pix = viewer.imageView()?.curDCM
        pix?.convertX(Float(x), pixY: Float(y), toDICOMCoords: &location, pixelCenter: true)

        let pixel = String(format: NSLocalizedString("px:\t\tx:%d y:%d", comment: ""), x, y)
        let world = String(format: NSLocalizedString("mm:\t\tx:%2.2f y:%2.2f z:%2.2f", comment: ""),
                           Double(location[0]), Double(location[1]), Double(location[2]))
        let value = String(format: NSLocalizedString("value:\t%2.2f", comment: ""),
                           Double(pix?.getPixelValueX(Int(x), y: Int(y)) ?? 0))
        return (pixel, world, value)
    }

    /// Draws the cross on `point` in the canvas the image view is drawing, with
    /// the scale and offset its drawing notification gives; nothing for a point
    /// at 0 on either axis, which is no seed.
    @MainActor
    static func drawCross(at point: NSPoint, userInfo: [AnyHashable: Any]?, backingScaleFactor: CGFloat) {
        guard point.x != 0 && point.y != 0 else { return }

        ROIGL.color3f(0.0, 1.0, 0.5)
        ROIGL.lineWidth(Float(2.0 * backingScaleFactor))
        ROIGL.begin(0x0001) // GL_LINES

        let scaleValue = floatValue(userInfo?["scaleValue"])

        let crossx = Float(point.x) - floatValue(userInfo?["offsetx"])
        let crossy = Float(point.y) - floatValue(userInfo?["offsety"])

        ROIGL.vertex2f(scaleValue * (crossx - 40), scaleValue * crossy)
        ROIGL.vertex2f(scaleValue * (crossx - 5), scaleValue * crossy)
        ROIGL.vertex2f(scaleValue * (crossx + 40), scaleValue * crossy)
        ROIGL.vertex2f(scaleValue * (crossx + 5), scaleValue * crossy)

        ROIGL.vertex2f(scaleValue * crossx, scaleValue * (crossy - 40))
        ROIGL.vertex2f(scaleValue * crossx, scaleValue * (crossy - 5))
        ROIGL.vertex2f(scaleValue * crossx, scaleValue * (crossy + 5))
        ROIGL.vertex2f(scaleValue * crossx, scaleValue * (crossy + 40))
        ROIGL.end()
    }

    /// `[value intValue]` of a number or a string; 0 for nothing.
    static func intValue(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        return (value as? NSString)?.intValue ?? 0
    }

    /// `[value floatValue]` of a number or a string; 0 for nothing.
    private static func floatValue(_ value: Any?) -> Float {
        if let number = value as? NSNumber { return number.floatValue }
        return (value as? NSString)?.floatValue ?? 0
    }
}
