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

// The window of a 2D viewer as its "Set WL/WW" sheet edits it, by level and
// width or by the range of values it shows, and the names of its stored presets.

public enum WindowLevel {

    /// The range of values a window shows: level ∓ width / 2.
    public static func range(level: Float, width: Float) -> (from: Float, to: Float) {
        return (level - width / 2, level + width / 2)
    }

    /// The window that shows a range of values.
    public static func window(from: Float, to: Float) -> (level: Float, width: Float) {
        return (from + (to - from) / 2, to - from)
    }

    /// The name of a stored preset from the title of its menu item, which
    /// precedes it with four characters (its shortcut and a separator); nil
    /// for a shorter title.
    public static func presetName(fromMenuTitle title: String) -> String? {
        let title = title as NSString
        guard title.length >= 4 else { return nil }
        return title.substring(from: 4)
    }
}
