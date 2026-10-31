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

// The report of the 2D viewer's study: the Report toolbar item (its icon
// after the reports application of the preferences, or a pop-up of the
// templates when the study has no report yet and there is more than one), and
// the commands that create and delete the report through the browser. The
// selectors are those of the former Objective-C methods; the work is
// ViewerImageExporter's. The notifications reach these methods through
// statics that receive the viewer.

public extension ViewerController {

    @objc(deleteReport:)
    func deleteReport(_ sender: Any!) {
        imageExporter.deleteReport(sender)
    }

    @objc(generateReport:)
    func generateReport(_ sender: Any!) {
        imageExporter.generateReport(sender)
    }

    /// The icon of the reports application of the preferences.
    @objc(reportIcon)
    func reportIcon() -> NSImage! {
        ViewerImageExporter.reportIcon(preferences: sessionGraph.preferences)
    }

    /// Puts the Report toolbar item in again, so that it takes the icon or the
    /// pop-up that applies now.
    @objc(updateReportToolbarIcon:)
    func updateReportToolbarIcon(_ note: Notification!) {
        ViewerImageExporter.updateReportToolbarIcon(of: self)
    }

    /// The Report toolbar item: the pop-up of the templates when the study has
    /// no report and the reports application has more than one template, the
    /// application's icon otherwise.
    @objc(setToolbarReportIconForItem:)
    func setToolbarReportIconFor(_ item: NSToolbarItem!) {
        ViewerImageExporter.setReportToolbarIcon(for: item, of: self, preferences: sessionGraph.preferences)
    }

    /// Fills the templates pop-up of the Report toolbar item as it opens.
    @objc(reportToolbarItemWillPopUp:)
    func reportToolbarItemWillPopUp(_ notif: Notification!) {
        ViewerImageExporter.reportTemplatesWillPopUp(notif, of: self, preferences: sessionGraph.preferences)
    }
}
