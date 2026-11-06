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

// The decisions of a 2D viewer's XA mask subtraction tool: the range of the
// subtracted values, the pixel shift of the mask chosen by the arrows of the
// tool and of the menu, the indicator of the shift, and the sliders' steps.
// The images are subtracted by DCMPix; the viewer applies these answers to them
// and to its controls.

public enum MaskSubtraction {

    /// The range of the subtracted values over the images the mask is
    /// subtracted from, from each one's own range (-[DCMPix subMinMax::]): the
    /// lowest minimum and the highest maximum, as whole numbers, starting from
    /// a minimum of 1024 and a maximum of 0. Without any image, (1024, 0).
    public static func range(of ranges: [CGPoint]) -> CGPoint {
        var minimum = 1024, maximum = 0
        for range in ranges {
            // The Objective-C assigned the CGFloat to a long: truncated toward zero.
            if range.x < CGFloat(minimum), let value = Int(exactly: range.x.rounded(.towardZero)) { minimum = value }
            if range.y > CGFloat(maximum), let value = Int(exactly: range.y.rounded(.towardZero)) { maximum = value }
        }
        return CGPoint(x: CGFloat(minimum), y: CGFloat(maximum))
    }

    /// The mask's pixel shift after a button of the shift tool or its menu
    /// item, by tag: 1 to 9 as on a numeric keypad, 5 for no shift.
    /// Another tag leaves the shift as it is.
    public static func shift(_ offset: CGPoint, afterTag tag: Int) -> CGPoint {
        var offset = offset
        switch tag {
        case 1: offset.x -= 1; offset.y -= 1        // SW
        case 2: offset.y -= 1                       // S
        case 3: offset.x += 1; offset.y -= 1        // SE
        case 4: offset.x -= 1                       // W
        case 5: offset = .zero                      // no shift
        case 6: offset.x += 1                       // E
        case 7: offset.x -= 1; offset.y += 1        // NW
        case 8: offset.y += 1                       // N
        case 9: offset.x += 1; offset.y += 1        // NE
        default: break
        }
        return offset
    }

    /// Whether a shift is applied: less than 30 pixels each way.
    public static func isApplicable(_ offset: CGPoint) -> Bool {
        return offset.x > -30 && offset.x < 30 && offset.y > -30 && offset.y < 30
    }

    /// One coordinate of the shift as a column or row of the indicator:
    /// -2 or less 0, -1 1, 0 4, 1 2, 2 or more 3 (-threeTestsFivePosibilities:).
    public static func indicatorIndex(_ f: Int) -> Int {
        if f == 0 { return 4 }
        if abs(f) > 1 { return f > 1 ? 3 : 0 }
        return f == 1 ? 2 : 1
    }

    /// The indicator code of a shift: indicatorIndex(y) * 5 + indicatorIndex(x).
    public static func indicatorCode(_ offset: CGPoint) -> Int {
        // The Objective-C cast each CGFloat coordinate to int.
        func index(_ value: CGFloat) -> Int {
            guard let whole = Int32(exactly: value.rounded(.towardZero)) else { return indicatorIndex(value < 0 ? -2 : 2) }
            return indicatorIndex(Int(whole))
        }
        return index(offset.y) * 5 + index(offset.x)
    }

    /// The states of the indicator's nine buttons sc1 … sc9 (true on) for an
    /// indicator code, or nil for a code that leaves them as they are. The
    /// buttons lit show the direction of the shift on a 3 × 3 keypad; "on" is
    /// stronger than "off" (-offsetMatrixSetting:).
    public static func indicatorStates(code: Int) -> [Bool]? {
        // Rows from the top of the keypad: sc7 sc8 sc9 / sc4 sc5 sc6 / sc1 sc2 sc3.
        let rows: [String]
        switch code {
        // y = -2
        case 0: rows = ["110", "111", "111"]
        case 1: rows = ["100", "111", "111"]
        case 4: rows = ["000", "111", "111"]
        case 2: rows = ["001", "111", "111"]
        case 3: rows = ["011", "111", "111"]
        // y = -1
        case 5: rows = ["110", "110", "111"]
        case 6: rows = ["100", "100", "111"]
        case 9: rows = ["000", "000", "111"]
        case 7: rows = ["001", "001", "111"]
        case 8: rows = ["011", "011", "111"]
        // y = 0
        case 20: rows = ["110", "110", "110"]
        case 21: rows = ["100", "100", "100"]
        case 24: rows = ["000", "000", "000"]
        case 22: rows = ["001", "001", "001"]
        case 23: rows = ["011", "011", "011"]
        // y = 1
        case 10: rows = ["111", "110", "110"]
        case 11: rows = ["111", "100", "100"]
        case 14: rows = ["111", "000", "000"]
        case 12: rows = ["111", "001", "001"]
        case 13: rows = ["111", "011", "011"]
        // y = 2
        case 15: rows = ["111", "111", "110"]
        case 16: rows = ["111", "111", "100"]
        case 19: rows = ["111", "111", "000"]
        case 17: rows = ["111", "111", "001"]
        case 18: rows = ["111", "111", "011"]
        default: return nil
        }
        let lit = rows.map { $0.map { $0 == "1" } }
        // sc1 … sc9: the bottom row first.
        return lit[2] + lit[1] + lit[0]
    }

    /// The window level and width after a menu item of the subtraction
    /// sliders, by tag: 37/38/39 level -5 / 128 / +5 ("gamma"), 34/35/36 width
    /// -5 / 256 / +5 ("zero"); nil for another tag.
    public static func window(afterSliderTag tag: Int, level: Float, width: Float) -> (level: Float, width: Float)? {
        switch tag {
        case 37: return (level - 5, width)
        case 38: return (128, width)
        case 39: return (level + 5, width)
        case 34: return (level, width - 5)
        case 35: return (level, 256)
        case 36: return (level, width + 5)
        default: return nil
        }
    }

    /// The value of the stack sum slider after a menu item, by tag: 31 one
    /// less, 32 one, 33 one more; nil for another tag.
    public static func sum(afterTag tag: Int, current: Float) -> Float? {
        switch tag {
        case 31: return current - 1
        case 32: return 1
        case 33: return current + 1
        default: return nil
        }
    }
}
