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

/// The key images of the 2D viewer, over KeyImageSearch: the state of the key
/// image check box and of the "key images only" popup, toggling the image
/// shown, and where the "next" and "previous key image" buttons go: the next
/// key image of the series shown, or else the first one of another series of
/// the study, looked for in order.
public enum KeyImageNavigation {

    /// The check box and the popup: both disabled for a post processed
    /// series (the box keeps its state), otherwise enabled, the box checked
    /// when the image shown is a key image.
    public struct Controls: Sendable, Equatable {
        public var isEnabled: Bool
        /// The state the box takes; nil to leave it as it is.
        public var isChecked: Bool?

        public init(isEnabled: Bool, isChecked: Bool?) {
            self.isEnabled = isEnabled
            self.isChecked = isChecked
        }
    }

    /// The controls for the image `current` of the frame shown; `isKey` is
    /// asked only for an image there is.
    public static func controls(postprocessed: Bool, current: Int, isKey: (Int) -> Bool) -> Controls {
        if postprocessed {
            return Controls(isEnabled: false, isChecked: nil)
        }
        return Controls(isEnabled: true, isChecked: current >= 0 && isKey(current))
    }

    /// The key image shortcut: the state the check box toggles to.
    public static func toggled(isChecked: Bool) -> Bool {
        !isChecked
    }

    /// The key image a button finds in the series shown, from image `current`
    /// of `count` towards the way the button looks; nil when there is none
    /// further.
    public static func nextInSeries(from current: Int, count: Int, isPrevious: Bool, flipped: Bool, isKey: (Int) -> Bool) -> Int? {
        if KeyImageSearch.runsForward(isPrevious: isPrevious, flipped: flipped) {
            return KeyImageSearch.firstKeyImage(in: stride(from: current + 1, to: count, by: 1), isKey: isKey)
        }
        return KeyImageSearch.firstKeyImage(in: stride(from: current - 1, through: 0, by: -1), isKey: isKey)
    }

    /// The other series of the study to look through, in order, when the
    /// series shown, at `position` among `count`, has no key image further:
    /// the later series for "next", the earlier ones backwards for
    /// "previous"; none when the series is not among them.
    public static func seriesToSearch(from position: Int?, count: Int, nextSeries: Bool) -> [Int] {
        guard let position else { return [] }
        if nextSeries {
            return Array(stride(from: position + 1, to: count, by: 1))
        }
        return Array(stride(from: position - 1, through: 0, by: -1))
    }

    /// Where a button lands in the series it moved to, of `count` images: its
    /// first key image from the end the search starts at; nil for none.
    public static func landing(count: Int, nextSeries: Bool, flipped: Bool, isKey: (Int) -> Bool) -> Int? {
        if KeyImageSearch.startsFromLastImage(nextSeries: nextSeries, flipped: flipped) {
            return KeyImageSearch.firstKeyImage(in: stride(from: count - 1, through: 0, by: -1), isKey: isKey)
        }
        return KeyImageSearch.firstKeyImage(in: 0..<max(count, 0), isKey: isKey)
    }
}
