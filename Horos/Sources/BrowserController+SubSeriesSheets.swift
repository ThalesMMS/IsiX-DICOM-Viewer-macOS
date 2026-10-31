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

// The two sheets of opening a series in parts, as the nib and the bindings
// reach them: the 3D/4D sheet's buttons end its modal session with their
// choice, and the sub-series sheet's fields set the range through their
// setters. The sheets themselves are the browser's ViewerOpener's.

extension BrowserController {

    // MARK: 3D/4D sheet

    @objc(selectSubSeriesAndOpen:)
    func selectSubSeriesAndOpen(_ sender: Any!) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 2))
    }

    @objc(selectAll3DSeries:)
    func selectAll3DSeries(_ sender: Any!) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 6))
    }

    @objc(reparseIn3D:)
    func reparseIn3D(_ sender: Any!) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 10))
    }

    @objc(reparseIn4D:)
    func reparseIn4D(_ sender: Any!) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 11))
    }

    @objc(selectAll4DSeries:)
    func selectAll4DSeries(_ sender: Any!) {
        if horos_subOpenMatrix4D?.isEnabled ?? false {
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 7))
        }
    }

    // MARK: Sub-series sheet

    @objc(checkMemory:)
    func checkMemory(_ sender: Any!) {
        viewerOpener.checkMemory()
    }

    @objc(setSubInterval:)
    func setSubInterval(_ sender: Any!) {
        viewerOpener.setSubInterval(sender)
    }

    @objc(setSubFrom:)
    func setSubFrom(_ sender: Any!) {
        viewerOpener.setSubFrom(sender)
    }

    @objc(setSubTo:)
    func setSubTo(_ sender: Any!) {
        viewerOpener.setSubTo(sender)
    }

    /// The sub-series sheet: the images kept of each list, or nil when it is
    /// cancelled or cannot be shown (another sheet, a full-screen window).
    @objc(openSubSeries:)
    func openSubSeries(_ toOpenArray: [Any]!) -> [Any]! {
        viewerOpener.chooseSubSeriesRange(toOpenArray)
    }
}
