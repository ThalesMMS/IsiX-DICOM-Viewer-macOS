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
import IsiXImaging

// The report of the 2D viewer's study: the Report toolbar item (its icon
// after the reports application of the preferences, or a pop-up of the
// templates when the study has no report yet and there is more than one), and
// the commands that create and delete the report through the browser. The
// selectors are those of the former Objective-C methods; the OSIRIX_LIGHT
// branches, a build that is not made, are left out.

/// The identifier of the Report toolbar item (a file-scope static of
/// ViewerController.m before; ViewerController+Toolbar.swift has its own).
private let ReportToolbarItemIdentifier = "Report.icns"

/// The REPORTSMODE preference: 0 Word, 1 TextEdit, 2 Pages, 3 DICOM SR.
private func reportsMode() -> Int32 {
    (UserDefaults.standard.string(forKey: "REPORTSMODE") as NSString?)?.intValue ?? 0
}

public extension ViewerController {

    @objc(deleteReport:)
    func deleteReport(_ sender: Any!) {
        BrowserController.currentBrowser()?.deleteReport(sender)
        perform(#selector(ViewerController.updateReportToolbarIcon(_:)), with: nil, afterDelay: 0.1)
    }

    @objc(generateReport:)
    func generateReport(_ sender: Any!) {
        BrowserController.currentBrowser()?.generateReport(sender)
        perform(#selector(ViewerController.updateReportToolbarIcon(_:)), with: nil, afterDelay: 0.1)
    }

    /// The icon of the reports application of the preferences.
    @objc(reportIcon)
    func reportIcon() -> NSImage! {
        return NSImage.toolbarImageNamed(ViewerReportIcon.name(reportsMode: UserDefaults.standard.string(forKey: "REPORTSMODE")))
    }

    /// Puts the Report toolbar item in again, so that it takes the icon or the
    /// pop-up that applies now.
    @objc(updateReportToolbarIcon:)
    func updateReportToolbarIcon(_ note: Notification!) {
        guard let toolbar = horos_toolbar else { return }
        let toolbarItems = toolbar.items
        for (i, item) in toolbarItems.enumerated() where item.itemIdentifier.rawValue == ReportToolbarItemIdentifier {
            toolbar.removeItem(at: i)
            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(ReportToolbarItemIdentifier), at: i)
        }
    }

    /// The Report toolbar item: the pop-up of the templates when the study has
    /// no report and the reports application has more than one template, the
    /// application's icon otherwise.
    @objc(setToolbarReportIconForItem:)
    func setToolbarReportIconFor(_ item: NSToolbarItem!) {
        var templatesArray: NSMutableArray? = nil
        switch reportsMode() {
        case 2:
            templatesArray = Reports.pagesTemplatesList()
        case 0:
            templatesArray = Reports.wordTemplatesList()
        default:
            break
        }

        let studySelected = (horos_fileList(at: 0)?.object(at: 0) as AnyObject?)?.value(forKeyPath: "series.study") as? DicomStudy

        if studySelected?.reportURL == nil && (templatesArray?.count ?? 0) > 1 {
            horos_reportTemplatesImageView?.image = reportIcon()
            item?.view = horos_reportTemplatesView
            let size = ToolbarPolicy.designedSize(of: horos_reportTemplatesView)
            ToolbarPolicy.constrainView(of: item, minimum: size, maximum: size)
        } else {
            item?.image = reportIcon()
        }
    }

    /// Fills the templates pop-up of the Report toolbar item as it opens.
    @objc(reportToolbarItemWillPopUp:)
    func reportToolbarItemWillPopUp(_ notif: Notification!) {
        guard let popUp = horos_reportTemplatesListPopUpButton,
              (notif?.object as? NSObject)?.isEqual(to: popUp) ?? false else { return }

        popUp.removeAllItems()
        popUp.addItem(withTitle: "")

        // Folders of the templates folder are submenus, as in the browser.
        switch reportsMode() {
        case 2:
            ReportTemplateMenu.populate(popUp.menu!, templates: (Reports.pagesTemplatesList() as? [String]) ?? [],
                                        folder: Reports.databasePagesTemplatesDirPath(), target: self, action: #selector(ViewerController.generateReport(_:)))
        case 0:
            ReportTemplateMenu.populate(popUp.menu!, templates: (Reports.wordTemplatesList() as? [String]) ?? [],
                                        folder: Reports.resolvedDatabaseWordTemplatesDirPath(), target: self, action: #selector(ViewerController.generateReport(_:)))
        default:
            break
        }

        popUp.action = #selector(ViewerController.generateReport(_:))
    }
}
