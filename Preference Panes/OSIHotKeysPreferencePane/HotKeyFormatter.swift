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

/// Shows a hot key in capitals, and the double-click assignments in words.
///
/// Implemented in Swift since #711.
@objc(HotKeyFormatter)
public final class HotKeyFormatter: Formatter {
    public override func isPartialStringValid(_ partialString: String, newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        if (partialString as NSString).length > 1 {
            return false
        }
        return true
    }

    /// A value that is not a string gives nil (the former class raised on it).
    public override func string(for obj: Any?) -> String? {
        guard let anObject = obj as? NSString else { return nil }

        if anObject.isEqual(to: "dbl-click") {
            return NSLocalizedString("dbl-click", comment: "keep it short !")
        }

        if anObject.isEqual(to: "dbl-click + alt") {
            return NSLocalizedString("dbl-click + alt", comment: "keep it short ! dbl-click + alt = double-click + alternate key")
        }

        if anObject.isEqual(to: "dbl-click + cmd") {
            return NSLocalizedString("dbl-click + cmd", comment: "keep it short ! double-click + command key")
        }

        return anObject.uppercased
    }

    public override func editingString(for obj: Any) -> String? {
        obj as? String
    }

    public override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = (string as NSString).copy() as AnyObject
        return true
    }
}
