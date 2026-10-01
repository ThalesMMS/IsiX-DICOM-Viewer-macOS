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

/// Asks for the group and element of a DICOM tag that the tags menu does not
/// list.
///
/// Implemented in Swift since #712: the Objective-C name, the selectors and
/// <Horos/AnonymizationCustomTagPanelController.h> are those of the former class.
@objc(AnonymizationCustomTagPanelController)
public final class AnonymizationCustomTagPanelController: NSWindowController {
    @IBOutlet var groupField: NSTextField!
    @IBOutlet var elementField: NSTextField!

    public override var windowNibName: NSNib.Name? {
        return "AnonymizationCustomTagPanel"
    }

    /// -initWithWindowNibName:@"AnonymizationCustomTagPanel"; the window is
    /// loaded here.
    @objc public init() {
        super.init(window: nil)
        _ = window // load
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @IBAction @objc(cancelButtonAction:)
    public func cancelButtonAction(_ sender: Any!) {
        if let window = window {
            window.sheetParent?.endSheet(window, returnCode: .abort)
        }
    }

    @IBAction @objc(okButtonAction:)
    public func okButtonAction(_ sender: Any!) {
        if let window = window {
            window.sheetParent?.endSheet(window)
        }
    }

    /// Assign in the former header, and never stored: the fields hold it. The
    /// fields' values are sent -unsignedIntValue, as before.
    @objc public var attributeTag: DCMAttributeTag! {
        get {
            let group = (groupField?.objectValue as AnyObject?)?.uint32Value ?? 0
            let element = (elementField?.objectValue as AnyObject?)?.uint32Value ?? 0
            return DCMAttributeTag.tag(withGroup: Int32(bitPattern: group), element: Int32(bitPattern: element)) as? DCMAttributeTag
        }
        set {
            groupField?.objectValue = NSNumber(value: UInt32(bitPattern: newValue?.group ?? 0))
            elementField?.objectValue = NSNumber(value: UInt32(bitPattern: newValue?.element ?? 0))
        }
    }
}
