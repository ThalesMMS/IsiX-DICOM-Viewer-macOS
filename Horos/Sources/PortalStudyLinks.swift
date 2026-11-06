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

/// The links of the browser's studies to web portal users: a study of the web
/// portal's own database, not a DICOM study, for each selected study (a
/// series stands for its study) that the user is not linked to yet
/// (IsiXDatabase's WebPortalStudyLink), with a line in the portal's log.
@MainActor struct PortalStudyLinks {
    let portal: WebPortal?

    init(portal: WebPortal? = WebPortal.default()) {
        self.portal = portal
    }

    /// The sheet "Add studies to users": the users chosen get the selection.
    static func addSelection(of browser: BrowserController) {
        guard let sheet = browser.horos_addStudiesToUserWindow, let users = browser.horos_notificationEmailArrayController else { return }
        users.setSelectionIndexes(IndexSet())
        browser.window?.beginSheet(sheet, completionHandler: nil)
        let result = NSApp.runModal(for: sheet)
        sheet.makeFirstResponder(nil)

        if result == .stop {
            if users.selectedObjects.isEmpty {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                                message: NSLocalizedString("No user(s) selected, no studies will be added.", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            } else if let exception = HorosObjCException.caught({ PortalStudyLinks().link(browser.databaseSelection() ?? [], to: users.selectedObjects) }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController addStudiesToUser:]")
            }
        }
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(browser)
    }

    /// Links each study of `selection` to each of `users` not linked to it
    /// yet, added on `dateAdded` when given, saving the portal's database
    /// after each link.
    func link(_ selection: [Any], to users: [Any], dateAdded: Date? = nil) {
        for case let user as WebPortalUser in users {
            func linked(_ value: (WebPortalStudy) -> String?) -> [Any] {
                (user.studies ?? []).compactMap { ($0 as? WebPortalStudy).flatMap(value) }
            }
            var studyUIDs = linked { $0.studyInstanceUID }
            var patientUIDs = linked { $0.patientUID }
            for item in selection {
                guard let study = (item as? DicomSeries)?.study ?? (item as? DicomStudy) else { continue }
                let studyUID: String? = study.studyInstanceUID
                let patientUID: String? = study.patientUID
                guard WebPortalStudyLink.needsLink(studyUID: studyUID, patientUID: patientUID,
                                                   linkedStudyUIDs: studyUIDs, linkedPatientUIDs: patientUIDs),
                      let context = user.managedObjectContext,
                      let link = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context) as? WebPortalStudy else { continue }
                link.studyInstanceUID = studyUID
                link.patientUID = patientUID
                if let dateAdded { link.dateAdded = dateAdded }
                link.user = user
                if let exception = HorosObjCException.caught({ _ = portal?.database?.save() }) {
                    BrowserObjC.log(exception, stack: true, "-[BrowserController addStudiesToUser:]")
                }
                studyUIDs = linked { $0.studyInstanceUID }
                patientUIDs = linked { $0.patientUID }
                portal?.updateLogEntry(forStudy: study, withMessage: "Add Study to User", forUser: user.name, ip: nil)
            }
        }
    }
}
