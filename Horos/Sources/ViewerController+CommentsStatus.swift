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
// the study. The selectors are those of the former Objective-C methods. A
// message to nil answered nil, 0 or NO: the optional chains below answer the
// same.

/// [a isEqualToString: b]: NO when either is nil.
private func objcEqual(_ a: String?, _ b: String) -> Bool {
    guard let a else { return false }
    return (a as NSString).isEqual(to: b)
}

public extension ViewerController {

    /// The file of the image shown: [fileList[curMovieIndex] objectAtIndex: [imageView curImage]].
    private func horosFileShown() -> NSManagedObject? {
        return horos_fileList(at: Int(horos_curMovieIndex))?.object(at: Int(horos_imageView?.curImage ?? 0)) as? NSManagedObject
    }

    /// Writes `value` at `keyPath` of the file shown, through the remote
    /// database too when the browser shows one.
    private func horosWriteToFileShown(_ value: Any?, forKeyPath keyPath: String) {
        horosFileShown()?.setValue(value, forKeyPath: keyPath)

        let browser = BrowserController.currentBrowser()
        if browser?.isCurrentDatabaseBonjour ?? false {
            (browser?.database as? RemoteDicomDatabase)?.object(horosFileShown(), setValue: value, forKey: keyPath)
        }
    }

    /// Closes the comments sheet; its tag says where the comment goes (1 the
    /// series, 2 the study). The comment button shows the series comment, or
    /// else the study's.
    @objc(endSetComments:)
    func endSetComments(_ sender: Any!) {
        horos_CommentsWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(ViewerSender.tag(sender)))

        if ViewerSender.tag(sender) == 1 { // series
            horosWriteToFileShown(horos_CommentsEditField?.stringValue, forKeyPath: "series.comment")

            BrowserController.currentBrowser()?.databaseOutline?.reloadData()

            buildMatrixPreview(false)
        } else if ViewerSender.tag(sender) == 2 { // study
            horosWriteToFileShown(horos_CommentsEditField?.stringValue, forKeyPath: "series.study.comment")

            BrowserController.currentBrowser()?.databaseOutline?.reloadData()

            buildMatrixPreview(false)
        }

        var com = horosFileShown()?.value(forKeyPath: "series.comment") as? String

        if com == nil || objcEqual(com, "") {
            com = horosFileShown()?.value(forKeyPath: "series.study.comment") as? String
        }

        if com == nil || objcEqual(com, "") {
            horos_CommentsField?.title = NSLocalizedString("Add a comment", comment: "")
        } else {
            horos_CommentsField?.title = com ?? ""
        }
    }

    /// Opens the comments sheet with the comment shown.
    @objc(setComments:)
    func setComments(_ sender: Any!) {
        horosLoadViewerPanels()

        if objcEqual(horos_CommentsField?.title, NSLocalizedString("Add a comment", comment: "")) {
            horos_CommentsEditField?.stringValue = ""
        } else {
            horos_CommentsEditField?.stringValue = horos_CommentsField?.title ?? ""
        }

        horos_CommentsEditField?.selectText(self)

        if let sheet = horos_CommentsWindow {
            window?.beginSheet(sheet, completionHandler: nil)
        }
    }

    /// Writes the status chosen (none is -1) to the study.
    @objc(applyStatusValue)
    func applyStatusValue() {
        let value = horos_statusValueToApply
        if value != -1 {
            horosWriteToFileShown(NSNumber(value: value), forKeyPath: "series.study.stateText")

            horos_StatusPopup?.selectItem(withTag: Int(value))

            BrowserController.currentBrowser()?.databaseOutline?.reloadData()
            buildMatrixPreview(false)
        }
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
        BrowserController.currentBrowser()?.showDatabase(self)
    }

    @objc(querySelectedStudy:)
    func querySelectedStudy(_ sender: Any!) {
        BrowserController.currentBrowser()?.querySelectedStudy(self)
    }
}
