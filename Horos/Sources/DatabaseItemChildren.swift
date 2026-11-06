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

import CoreData
import Foundation

/// The children of a row of the database: the series of a study (the image
/// series, or every series with the documents after the pictures) or the
/// sorted images of a series; nothing for a distant or deleted object, nil for
/// anything else. Model objects only, on the thread of their context.
///
/// It keeps no state of the database window: the browser's `childrenArray:`
/// and `childrenArray:onlyImages:`, which the viewers, the plugins and the web
/// portal call, answer through it, and so do the reports, which have no
/// browser of their own.
enum DatabaseItemChildren {

    static func children(of item: Any?, onlyImages: Bool = true) -> [Any]? {
        if (item as AnyObject?)?.isDistant?() ?? false {
            return []
        }

        if let object = item as? NSManagedObject, object.isDeleted {
            NSLog("----- isDeleted - childrenArray : we have to refresh the outlineView...")
            return []
        }

        if let series = item as? DicomSeries {
            return series.sortedImages()
        }

        if let study = item as? DicomStudy {
            var sorted: [Any]?
            if let raised = HorosObjCException.caught({
                if onlyImages {
                    sorted = study.imageSeries() as? [Any]
                } else {
                    // The ROI, comments, reports, PDF and other documents after the
                    // series of pictures.
                    sorted = DicomStudy.imagesBeforeDocuments(study.allSeries() ?? []) as? [Any]
                }
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController childrenArray:onlyImages:]")
            }
            return sorted
        }

        return nil
    }
}
