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

// The keys of the 2D viewer's window: play and stop, the speeds of a
// shuttle controller (ShuttlePRO), the time points of a 4D series and the
// next series.

public enum ViewerKeyCommand: Equatable {
    /// Return, Enter or space: play or stop the movie.
    case playStop
    /// 1 to 7 forward, a to g backward: play at that speed.
    case shuttle(speed: Float, direction: Float)
    /// 0: stop the movie if it plays.
    case stop
    /// Up arrow: the previous time point.
    case previousTimePoint
    /// Down arrow: the next time point.
    case nextTimePoint
    /// Command-left arrow: the previous series.
    case previousSeries
    /// Command-right arrow: the next series.
    case nextSeries
    /// Any other key: the window's responder chain.
    case other

    // NSUpArrowFunctionKey and the others of NSEvent.h.
    static let upArrow: UInt16 = 0xF700
    static let downArrow: UInt16 = 0xF701
    static let leftArrow: UInt16 = 0xF702
    static let rightArrow: UInt16 = 0xF703

    /// The command of the first character of a key event.
    public static func of(character c: UInt16, command: Bool) -> ViewerKeyCommand {
        let one = UInt16(UInt8(ascii: "1")), seven = UInt16(UInt8(ascii: "7"))
        let a = UInt16(UInt8(ascii: "a")), g = UInt16(UInt8(ascii: "g"))
        if c == 3 || c == 13 || c == UInt16(UInt8(ascii: " ")) { return .playStop }
        if (c >= one && c <= seven) || (c >= a && c <= g) {
            let forward = c >= one && c <= seven
            let step = forward ? c - one + 1 : c - a + 1
            let speeds: [Float] = [2, 5, 10, 15, 25, 30, 60]
            return .shuttle(speed: speeds[Int(step) - 1], direction: forward ? 1 : -1)
        }
        if c == UInt16(UInt8(ascii: "0")) { return .stop }
        if c == upArrow { return .previousTimePoint }
        if c == downArrow { return .nextTimePoint }
        if c == leftArrow && command { return .previousSeries }
        if c == rightArrow && command { return .nextSeries }
        return .other
    }

    /// The time point after `current` one step back (-1) or forward (1),
    /// round the `count` time points.
    public static func timePoint(after current: Int16, step: Int16, count: Int16) -> Int16 {
        let next = current &+ step
        if step < 0 { return next < 0 ? count &- 1 : next }
        return next >= count ? 0 : next
    }
}

/// The first or last image of a movie export, as its fields show it: from 1,
/// counted from the end when the slices are flipped.
public enum MovieExportPosition {
    public static func fieldValue(image: Int, imageCount: Int, flipped: Bool) -> Int32 {
        Int32(truncatingIfNeeded: flipped ? imageCount &- image : image &+ 1)
    }
}
