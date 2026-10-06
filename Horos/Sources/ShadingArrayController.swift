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

/// The shading presets of the 3D viewers, kept in the shadingsPresets default.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/ShadingArrayController.h> are those of the former class, the array
/// controller of the presets in VR.xib, MPR.xib, CPR.xib and Endoscopy.xib.
@objc(ShadingArrayController)
public final class ShadingArrayController: NSArrayController {
    /// The former _enableEditing ivar. The xibs bind to enableEditing, and
    /// -setEnableEditing: notifies them as the synthesized KVO did.
    @objc public dynamic var enableEditing: Bool = false

    public override func add(_ sender: Any?) {
        self.enableEditing = true
        super.add(sender)
    }

    public override func addObject(_ object: Any) {
        let previous = (self.selectedObjects as NSArray).lastObject as AnyObject?
        // [[self content] count], an int; 0 without content, as a message to nil.
        let count = Int32(truncatingIfNeeded: (self.content as? NSArray)?.count ?? 0)
        let item = object as AnyObject

        if count > 0 {
            item.setValue(String(format: "%@ %d", NSLocalizedString("Preset", comment: ""), count + 1), forKey: "name")
            item.setValue(previous?.value(forKey: "ambient"), forKey: "ambient")
            item.setValue(previous?.value(forKey: "diffuse"), forKey: "diffuse")
            item.setValue(previous?.value(forKey: "specular"), forKey: "specular")
            item.setValue(previous?.value(forKey: "specularPower"), forKey: "specularPower")
        } else {
            item.setValue(NSLocalizedString("Default", comment: ""), forKey: "name")
            item.setValue("0.15", forKey: "ambient")
            item.setValue("0.9", forKey: "diffuse")
            item.setValue("0.3", forKey: "specular")
            item.setValue("15", forKey: "specularPower")
        }

        super.addObject(object)
    }

    public override func prepareContent() {
        let array = NSMutableArray()
        let src = UserDefaults.standard.array(forKey: "shadingsPresets") as NSArray?

        for loopItem in src ?? NSArray() {
            array.add((loopItem as AnyObject).mutableCopy() as Any)
        }

        self.content = array
    }

    deinit {
        UserDefaults.standard.set(self.content, forKey: "shadingsPresets")
    }
}
