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

import AppKit

// NSSplitView (Defaults) is implemented in Swift. The selectors and
// <Horos/NSSplitViewSave.h> are those of the former category.

/** \brief Category saves splitView state to User Defaults */
public extension NSSplitView {

    @objc(restoreDefault:)
    func restoreDefault(_ defaultName: String) {
        let frames = UserDefaults.standard.array(forKey: defaultName)

        if (frames?.count ?? 0) == subviews.count {
            var i = 0

            for v in subviews {
                v.frame = NSRectFromString(frames?[i] as? String ?? "")
                i += 1
            }
        }

        adjustSubviews()
    }

    @objc(saveDefault:)
    func saveDefault(_ defaultName: String) {
        let frameArray = NSMutableArray()

        for v in subviews {
            if isSubviewCollapsed(v) {
                // The zeroed frame is not the one saved: the former category
                // stored v.frame here too.
                var frame = v.frame

                if isVertical {
                    frame.size.width = 0
                } else {
                    frame.size.height = 0
                }
                _ = frame

                frameArray.add(NSStringFromRect(v.frame))
            } else {
                frameArray.add(NSStringFromRect(v.frame))
            }
        }
        UserDefaults.standard.set(frameArray, forKey: defaultName)
    }
}
