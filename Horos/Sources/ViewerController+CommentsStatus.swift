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

// The comments and the status of the 2D viewer's series and study (the
// comments sheet, the status pop-up), the database window and the query of
// the study: the selectors of the former Objective-C methods, as a façade over
// StudyAnnotationEditor.

public extension ViewerController {

    /// Closes the comments sheet; its tag says where the comment goes (1 the
    /// series, 2 the study).
    @objc(endSetComments:)
    func endSetComments(_ sender: Any!) {
        studyAnnotations.endComments(tag: ViewerSender.tag(sender))
    }

    /// Opens the comments sheet with the comment shown.
    @objc(setComments:)
    func setComments(_ sender: Any!) {
        studyAnnotations.beginComments()
    }

    /// Writes the status chosen (none is -1) to the study.
    @objc(applyStatusValue)
    func applyStatusValue() {
        studyAnnotations.applyStatus()
    }

    @objc(setStatusValue:)
    func setStatusValue(_ v: Int32) {
        horos_statusValueToApply = v
    }

    /// The status pop-up: the tag of the item chosen.
    @objc(setStatus:)
    func setStatus(_ sender: Any!) {
        setStatusValue(Int32(truncatingIfNeeded: (sender as? NSPopUpButton)?.selectedItem?.tag ?? 0))
    }

    /// Shows the database window; the viewers close unless Shift is down.
    @objc(databaseWindow:)
    func databaseWindow(_ sender: Any!) {
        if !(NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) ?? false) {
            ViewerController.closeAllWindows()
        }
        BrowserStudyAnnotations(processGraph: sessionGraph.processGraph).showDatabase(self)
    }

    @objc(querySelectedStudy:)
    func querySelectedStudy(_ sender: Any!) {
        BrowserStudyAnnotations(processGraph: sessionGraph.processGraph).querySelectedStudy(self)
    }
}
