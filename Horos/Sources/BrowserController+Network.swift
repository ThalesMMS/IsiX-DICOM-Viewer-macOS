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
import IsiXDatabase

// The DICOM network actions of the browser: sending the selection to a node,
// opening Query/Retrieve on it, and linking studies to web portal users.

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
        let objects = NSMutableArray()
        if isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix {
            _ = files(forDatabaseMatrixSelection: objects, onlyImages: false)
        } else {
            _ = files(forDatabaseOutlineSelection: objects, onlyImages: false)
        }
        selectServer(objects as? [Any])
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
        guard row != NSNotFound, let item = outline.item(atRow: row) as AnyObject? else { return }
        let study = BrowserObjC.literallyEqual(item.value(forKey: "type") as? String, "Study") ? item : item.value(forKey: "study") as AnyObject?
        QueryController.current()?.queryPatientID(study?.value(forKey: "patientID") as? String)
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

    /// Links the selected studies to the web portal users chosen in the sheet,
    /// those not linked yet (IsiXDatabase's WebPortalStudyLink).
    @objc(addStudiesToUser:)
    func addStudiesToUser(_ sender: Any!) {
        guard let sheet = horos_addStudiesToUserWindow, let users = horos_notificationEmailArrayController else { return }
        users.setSelectionIndexes(IndexSet())
        window?.beginSheet(sheet, completionHandler: nil)
        let result = NSApp.runModal(for: sheet)
        sheet.makeFirstResponder(nil)

        if result == .stop {
            if users.selectedObjects.isEmpty {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                                message: NSLocalizedString("No user(s) selected, no studies will be added.", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            } else if let exception = BrowserObjC.attempt({ self.link(databaseSelection() ?? [], toUsers: users.selectedObjects) }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController addStudiesToUser:]")
            }
        }
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(self)
    }

    private func link(_ selection: [Any], toUsers users: [Any]) {
        for case let user as NSManagedObject in users {
            func linked(_ key: String) -> [Any] {
                ((user.value(forKey: "studies") as? NSSet)?.allObjects as NSArray?)?.value(forKey: key) as? [Any] ?? []
            }
            var studyUIDs = linked("studyInstanceUID")
            var patientUIDs = linked("patientUID")
            for case var study as NSObject in selection {
                if BrowserObjC.literallyEqual(study.value(forKey: "type") as? String, "Series"), let parent = study.value(forKey: "study") as? NSObject {
                    study = parent
                }
                let studyUID = study.value(forKey: "studyInstanceUID") as? String
                let patientUID = study.value(forKey: "patientUID") as? String
                guard WebPortalStudyLink.needsLink(studyUID: studyUID, patientUID: patientUID,
                                                   linkedStudyUIDs: studyUIDs, linkedPatientUIDs: patientUIDs),
                      let context = user.managedObjectContext else { continue }
                let link = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
                link.setValue(studyUID, forKey: "studyInstanceUID")
                link.setValue(patientUID, forKey: "patientUID")
                link.setValue(user, forKey: "user")
                if let exception = BrowserObjC.attempt({ _ = WebPortal.default()?.database?.save() }) {
                    BrowserObjC.log(exception, stack: true, "-[BrowserController addStudiesToUser:]")
                }
                studyUIDs = linked("studyInstanceUID")
                patientUIDs = linked("patientUID")
                WebPortal.default()?.updateLogEntry(forStudy: study as? NSManagedObject, withMessage: "Add Study to User",
                                                    forUser: user.value(forKey: "name") as? String, ip: nil)
            }
        }
    }

    #endif
}
