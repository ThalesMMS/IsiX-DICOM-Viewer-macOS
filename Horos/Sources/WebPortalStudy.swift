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

// WebPortalStudy is implemented in Swift since #718. The Objective-C name, the
// selectors and <Horos/WebPortalStudy.h> are those of the former class, and
// the web portal database model still names the class of its Study entity
// WebPortalStudy.

@objc(WebPortalStudy)
public final class WebPortalStudy: NSManagedObject {

    @NSManaged public var dateAdded: Date!
    @NSManaged public var patientUID: String!
    @NSManaged public var studyInstanceUID: String!
    @NSManaged public var user: WebPortalUser!

    // TODO: we're accessing the defaultWebPortal database, and this is bad
    @objc public var study: DicomStudy! {
        let ddb = WebPortal.default()?.dicomDatabase?.independentDatabase() as? DicomDatabase

        let patientUID = self.patientUID
        let studyInstanceUID = self.studyInstanceUID
        // predicateWithFormat: made a nil argument the nil constant.
        let predicate = NSPredicate(format: "patientUID BEGINSWITH[cd] \(patientUID == nil ? "nil" : "%@") AND studyInstanceUID == \(studyInstanceUID == nil ? "nil" : "%@")",
                                    argumentArray: [patientUID as Any?, studyInstanceUID as Any?].compactMap { $0 })
        let studies = ddb?.objects(forEntity: ddb?.studyEntity(), predicate: predicate) as NSArray?

        if studies?.count != 1 {
            NSLog("Warning: Study request with \"patientUID == %@ AND studyInstanceUID == %@\" returned %d objects", patientUID ?? "(null)", studyInstanceUID ?? "(null)", Int32(truncatingIfNeeded: studies?.count ?? 0))
            return nil
        }

        return studies!.object(at: 0) as? DicomStudy
    }
}
