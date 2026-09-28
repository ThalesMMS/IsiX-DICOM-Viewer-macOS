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

/// A DICOM attribute offered by the custom annotations pane: its tag and its
/// dictionary name. PreferencesWindowController+DCMTK.mm builds them from the
/// DCMTK data dictionary.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors and
/// CIADICOMField.h are those of the former class.
@objc(CIADICOMField)
public final class CIADICOMField: NSObject {
    private var groupValue: Int32 = 0
    private var elementValue: Int32 = 0
    private var nameValue: String?

    /// As the inherited -init did: zero tag, no name.
    public override init() {
        super.init()
    }

    /// The former initializer started from [self init] and then set the ivars.
    @objc(initWithGroup:element:name:)
    public convenience init(group g: Int32, element e: Int32, name n: String!) {
        self.init()
        groupValue = g
        elementValue = e
        nameValue = n
    }

    @objc public func group() -> Int32 {
        return groupValue
    }

    @objc public func element() -> Int32 {
        return elementValue
    }

    @objc public func name() -> String! {
        return nameValue
    }

    @objc public func title() -> String! {
        return String(format: "(0x%04x,0x%04x) %@", groupValue, elementValue, ciaDescription(nameValue))
    }

    public override var description: String {
        return title()
    }
}

/// What `%@` prints for an object: its description, or "(null)" for nil.
func ciaDescription(_ value: Any?) -> String {
    guard let value = value else { return "(null)" }
    return String(describing: value as AnyObject)
}
