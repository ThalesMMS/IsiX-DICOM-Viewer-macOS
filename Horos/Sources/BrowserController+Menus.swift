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

// The browser's menus as AppKit and the nib reach them: the list's and the
// albums' contextual menus, the Help menu and the validation of the browser's
// commands are BrowserToolbar's. Locking and unlocking studies stay here.

extension BrowserController {

    // MARK: - Contextual menus

    @objc(menuWillOpen:)
    public func menuWillOpen(_ menu: NSMenu) {
        browserToolbar.menuWillOpen(menu)
    }

    @objc(addHelpMenu)
    func addHelpMenu() {
        browserToolbar.addHelpMenu()
    }

    // MARK: - Validating the commands

    @objc(validateMenuItem:)
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        browserToolbar.validateMenuItem(menuItem)
    }

    // MARK: - Locking studies

    @objc(unlockStudies:)
    @IBAction func unlockStudies(_ sender: Any!) {
        let outline = horos_databaseOutline
        for row in outline?.selectedRowIndexes ?? IndexSet() {
            let object = outline?.item(atRow: row) as? NSObject
            if StudyLocking.unlocks(type: object?.value(forKey: "type"), locked: { object?.value(forKey: "lockedStudy") }) {
                object?.setValue(NSNumber(value: false), forKey: "lockedStudy")
            }
        }
        refreshDatabase(self)
    }

    @objc(lockStudies:)
    @IBAction func lockStudies(_ sender: Any!) {
        let outline = horos_databaseOutline
        for row in outline?.selectedRowIndexes ?? IndexSet() {
            let object = outline?.item(atRow: row) as? NSObject
            if StudyLocking.locks(type: object?.value(forKey: "type"), locked: { object?.value(forKey: "lockedStudy") }) {
                object?.setValue(NSNumber(value: true), forKey: "lockedStudy")
            }
        }
        refreshDatabase(self)
    }
}
