/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit

// What the browser keeps for released plugins and the former SDK: the web
// portal's user database, now WebPortal.defaultWebPortal's, and the file name
// of a string.

extension BrowserController {

    @available(*, deprecated, message: "Use WebPortal.defaultWebPortal.database")
    @objc(saveUserDatabase)
    public func saveUserDatabase() -> Int {
        _ = WebPortal.default()?.database?.save(nil)
        return 0
    }

    @available(*, deprecated, message: "Use WebPortal.defaultWebPortal.database")
    @objc public var userManagedObjectModel: NSManagedObjectModel! {
        return WebPortal.default()?.database?.managedObjectModel
    }

    @available(*, deprecated, message: "Use WebPortal.defaultWebPortal.database")
    @objc public var userManagedObjectContext: NSManagedObjectContext! {
        return WebPortal.default()?.database?.managedObjectContext
    }

    @available(*, deprecated, message: "Use WebPortal.defaultWebPortal.database")
    @objc(userWithName:)
    public func userWithName(_ name: String!) -> WebPortalUser! {
        return WebPortal.default()?.database?.user(withName: name)
    }
}

extension NSString {

    /// The string as a file name: in ASCII, without the characters a file
    /// name does not admit; "AAA" when nothing is left.
    @objc(filenameString)
    public func filenameString() -> NSMutableString {
        let ascii = NSMutableString(string: (self.ASCIIString() as String?) ?? "")
        let cleaned: NSMutableString = BrowserController.replaceNotAdmitted(ascii) ?? NSMutableString()
        return cleaned.length == 0 ? NSMutableString(string: "AAA") : cleaned
    }
}
