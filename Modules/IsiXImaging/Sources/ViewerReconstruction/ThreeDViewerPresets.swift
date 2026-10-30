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

// The presets the 3D viewers share: the window level sheet and which item of
// the colour and opacity menus is checked. The stored colour tables are
// ColorLookupTable's, as for the 2D viewer; the window controllers and their
// sheets stay in the app.

/// The sheet that sets the window level by its level and width or by the
/// range it shows.
public enum ThreeDWindowLevelSheet {
    /// The range a level and a width show: level − width / 2 to level + width / 2.
    public static func range(level: Float, width: Float) -> (from: Float, to: Float) {
        (level - width / 2, level + width / 2)
    }

    /// The level and width of a range: its middle, from + (to − from) / 2, and
    /// its extent, to − from.
    public static func levelAndWidth(from: Float, to: Float) -> (level: Float, width: Float) {
        (from + (to - from) / 2, to - from)
    }
}

/// Which item of the colour and opacity menus of a 3D viewer is checked.
public enum ThreeDPresetMenus {
    /// Whether an item is checked: its title is the current table's name,
    /// compared character by character as NSString compares. No item is
    /// checked without a current table.
    public static func checksItem(title: String, current: String?) -> Bool {
        guard let current else { return false }
        return (title as NSString).isEqual(to: current)
    }
}
