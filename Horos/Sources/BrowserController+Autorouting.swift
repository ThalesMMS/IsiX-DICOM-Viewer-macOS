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

// The autorouting functions of the browser: checking the routing filters of
// the preferences and sending the selection through a rule by hand, which
// SourceCopyJob does. The rules themselves are applied by DatabaseRouting,
// through DicomDatabase (Routing).

extension BrowserController {

    /// Tries every routing filter of the preferences on the images of one
    /// study, and says which one has a syntax error.
    @objc(testAutorouting)
    func testAutorouting() {
        SourceCopyJob.checkRoutingFilters(of: database, preferences: sourceList.preferences) { smartAlbumPredicateString($0) }
    }

    /// The study of the image last selected in the thumbnails, else in the list.
    @objc(selectedStudy)
    func selectedStudy() -> DicomStudy! {
        let objects = NSMutableArray()
        _ = files(forDatabaseMatrixSelection: objects, onlyImages: false)
        var image = objects.lastObject as? DicomImage
        if image == nil {
            _ = files(forDatabaseOutlineSelection: objects, onlyImages: false)
            image = objects.lastObject as? DicomImage
        }
        return image?.series?.study
    }

    /// Sends the selection through the menu item's rule, or through every
    /// rule without one: the database window's contextual menu.
    @objc(applyRoutingRule:)
    func applyRoutingRule(_ sender: Any!) {
        let fromThumbnails = isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix
        if fromThumbnails { NSLog("applyRoutingRule from matrix") }

        let objects = NSMutableArray()
        if fromThumbnails {
            _ = files(forDatabaseMatrixSelection: objects, onlyImages: false)
        } else {
            _ = files(forDatabaseOutlineSelection: objects, onlyImages: false)
        }
        SourceCopyJob.route(Array(objects), through: (sender as? NSMenuItem)?.representedObject ?? (sender as? NSCell)?.representedObject,
                            in: database)
    }
}
