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

// The DICOM network actions of the browser: sending the selection to a node
// (SendController), opening Query/Retrieve on it (QueryController), and
// linking studies to web portal users (PortalStudyLinks).

extension BrowserController {

    /// Sends the files to the node chosen in the send window.
    @objc(selectServer:)
    func selectServer(_ objects: [Any]!) {
        if let objects, !objects.isEmpty {
            SendController.sendFiles(objects)
        } else {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Send", comment: ""),
                                            message: NSLocalizedString("No files are selected...", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    /// "Send to DICOM node": the thumbnails' selection when the menu or the
    /// focus is theirs, else the list's.
    @objc(export2PACS:)
    func export2PACS(_ sender: Any!) {
        window?.makeKeyAndOrderFront(sender)
        selectServer(SelectedFiles(of: self, thumbnails: isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix, onlyImages: false).objects)
    }

    #if !OSIRIX_LIGHT

    /// Query/Retrieve on the patient ID of the study selected in the list.
    @objc(querySelectedStudy:)
    func querySelectedStudy(_ sender: Any!) {
        window?.makeKeyAndOrderFront(sender)
        if QueryController.current() == nil {
            // The controller keeps itself as the current one.
            _ = QueryController(autoQuery: false)
        }
        QueryController.current()?.showWindow(self)

        guard let outline = horos_databaseOutline else { return }
        let row = outline.selectedRowIndexes.first ?? NSNotFound
        guard row != NSNotFound, let item = outline.item(atRow: row) else { return }
        let study = (item as? DicomStudy) ?? (item as? DicomSeries)?.study
        QueryController.current()?.queryPatientID(study?.patientID)
    }

    /// Query/Retrieve (tag 0) or the automatic query (tag 1); with Shift,
    /// the patient of the selected study.
    @objc(queryDICOM:)
    func queryDICOM(_ sender: Any!) {
        if NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) == true {
            querySelectedStudy(self)
            return
        }
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag ?? 0
        if tag == 0 && QueryController.current() == nil {
            _ = QueryController(autoQuery: false)
        } else if tag == 1 && QueryController.currentAuto() == nil {
            _ = QueryController(autoQuery: true)
        }
        if tag == 0 {
            QueryController.current()?.showWindow(self)
        }
        if tag == 1 {
            QueryController.currentAuto()?.showWindow(self)
        }
    }

    #endif

    /// Called when a storescp the browser started is done; under ARC the
    /// sender needs no release.
    @objc(storeSCPComplete:)
    func storeSCPComplete(_ sender: Any!) {
    }

    #if !OSIRIX_LIGHT

    /// Links the selected studies to the web portal users chosen in the sheet.
    @objc(addStudiesToUser:)
    func addStudiesToUser(_ sender: Any!) {
        PortalStudyLinks.addSelection(of: self)
    }

    #endif
}
