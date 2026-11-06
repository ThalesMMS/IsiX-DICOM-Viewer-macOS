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

// Browsing the images of a 2D viewer's series: the index a request lands on,
// the strip slider's position, the image the series opens on when the viewer
// steps to the next or previous series, and the steps of the "Browse" player.
// A flipped series is shown from its last image: the index the user sees
// (and the slider) runs the other way from the view's own.

public enum SeriesBrowsing {

    /// The view's image for the user's index `index`, clamped to the series
    /// (a series without images gives -1, as the viewer did).
    public static func viewImage(forIndex index: Int, count: Int, flipped: Bool) -> Int {
        var index = index
        if index < 0 { index = 0 }
        if index >= count { index = count - 1 }
        return flipped ? count - 1 - index : index
    }

    /// The user's index of the view's image `image`.
    public static func userIndex(ofViewImage image: Int, count: Int, flipped: Bool) -> Int {
        flipped ? count - 1 - image : image
    }

    /// The strip slider's value for the view's image `image`.
    public static func sliderValue(forViewImage image: Int, count: Int, flipped: Bool) -> Int32 {
        Int32(truncatingIfNeeded: flipped ? count - image - 1 : image)
    }

    /// The image a series opens on when the viewer moves to the next (1) or
    /// previous (-1) series: its first image going forwards, its last going
    /// backwards, as the user sees them.
    public static func edgeImage(movingBy direction: Int, count: Int, flipped: Bool) -> Int32 {
        let last = Int32(truncatingIfNeeded: count - 1)
        if direction == -1 { return flipped ? 0 : last }
        return flipped ? last : 0
    }

    /// One step of the "Browse" player from the view's image `image`: `direction`
    /// (+1 or -1, as the user sees it) moves the other way in a flipped series.
    /// Looping, it wraps around; otherwise it bounces off either end and the
    /// direction turns. The arithmetic is the viewer's: a float direction added
    /// to the image index, truncated towards zero.
    public static func step(from image: Int, direction: Float, flipped: Bool, count: Int, loops: Bool) -> (image: Int, direction: Float) {
        var direction = direction
        var value = indexValue(Float(image) + (flipped ? -direction : direction))

        if loops {
            if value < 0 { value = count - 1 }
            if value >= count { value = 0 }
        } else {
            if value < 0 {
                value = 0
                direction = -direction
                value = indexValue(Float(value) + direction)
                if value < 0 { value = 0 }
            }
            if value >= count {
                value = count - 1
                direction = -direction
                value = indexValue(Float(value) + direction)
                if value >= count { value = count - 1 }
            }
        }
        return (value, direction)
    }

    /// A float stored into an integer index, as C converts it: truncated
    /// towards zero.
    private static func indexValue(_ value: Float) -> Int {
        guard value.isFinite else { return 0 }
        return Int(value.rounded(.towardZero))
    }
}
