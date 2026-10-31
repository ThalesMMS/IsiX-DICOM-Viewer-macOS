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

// The report actions of the browser. Its nib's menu items, its report toolbar
// item, the notifications it observes and the application's activation send
// these selectors, which forward to StudyReports.

public extension BrowserController {

    /// Archives again each report opened in the session that changed.
    @objc(syncReportsIfNecessary)
    func syncReportsIfNecessary() {
        reports.synchronizeOpenReports()
    }

    @objc(convertReportToDICOMSR:)
    func convertReportToDICOMSR(_ sender: Any!) {
        reports.convertSelectionToDICOMPDF()
    }

    @objc(convertReportToPDF:)
    func convertReportToPDF(_ sender: Any!) {
        reports.exportSelectedReportAsPDF()
    }

    @objc(deleteReport:)
    func deleteReport(_ sender: Any!) {
        reports.deleteSelectedReport()
    }

    @objc(generateReport:)
    func generateReport(_ sender: Any!) {
        reports.generateReport(sender: sender)
    }

    @objc(updateReportToolbarIcon:)
    func updateReportToolbarIcon(_ note: Notification!) {
        reports.updateToolbarIcon()
    }

    @objc(setToolbarReportIconForItem:)
    func setToolbarReportIconFor(_ item: NSToolbarItem!) {
        reports.setToolbarIcon(for: item)
    }

    @objc(reportToolbarItemWillPopUp:)
    func reportToolbarItemWillPopUp(_ notif: Notification!) {
        reports.templatesWillPopUp(notif)
    }

    @objc(importReport:UID:)
    func importReport(_ path: String!, uid: String!) {
        do {
            try reports.attachReport(atPath: path, toStudyWithUID: uid)
        } catch {
            NSLog("Report attachment failed: %@", error.localizedDescription)
        }
    }

    @objc(importReport:UID:error:)
    func attachReport(atPath path: String!, toStudyWithUID uid: String!) throws {
        try reports.attachReport(atPath: path, toStudyWithUID: uid)
    }

    @objc(attachExistingReport:)
    func attachExistingReport(_ sender: Any!) {
        reports.attachExistingReport()
    }

    @objc(insertSelectedImagesIntoReport:)
    func insertSelectedImagesIntoReport(_ sender: Any!) {
        reports.insertSelectedImages()
    }
}
