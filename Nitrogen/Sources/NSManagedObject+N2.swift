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

import CoreData

// NSManagedObject (N2) is implemented in Swift; the selectors and
// <Horos/NSManagedObject+N2.h> are those of the former category, less
// +UrlForXid:, which nothing called.

@objc(N2) @implementation extension NSManagedObject {
    /// The URI string of the object an identifier of -XID names.
    @objc(UidForXid:)
    class func uid(forXid xid: String!) -> String! {
        coreDataURLPrefix.appending(xid)
    }

    /// The object's URI without its "x-coredata://" scheme: the identifier
    /// the browser, the albums and the web portal give an object.
    @objc(XID)
    func xid() -> String! {
        (objectID.uriRepresentation().absoluteString as NSString).substring(from: coreDataURLPrefix.length)
    }

    /// -XID with its slashes made hyphens, for a file name.
    @objc(XIDFilename)
    func xidFilename() -> String! {
        (xid() as NSString).replacingOccurrences(of: "/", with: "-")
    }
}

// nonisolated(unsafe): an immutable NSString literal.
nonisolated(unsafe) private let coreDataURLPrefix: NSString = "x-coredata://"
