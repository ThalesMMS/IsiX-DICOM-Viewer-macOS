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

// Bonjour and the databases the browser opens: a shared database's password,
// the local copy of a shared database's image, the sources list, going back
// to the default database when Bonjour sharing changes, and opening a
// database folder. What decides without the app's classes is IsiXDatabase's
// DefaultDatabase. The selectors are those of the former Objective-C methods.

extension BrowserController {

    @available(*, deprecated)
    @objc(setBonjourDatabaseValue:value:forKey:)
    func setBonjourDatabaseValue(_ obj: NSManagedObject!, value: Any!, forKey key: String!) {
        (horos_databaseIvar as? RemoteDicomDatabase)?.object(obj, setValue: value, forKey: key)
    }

    /// The password of a shared database, asked in a sheet: nil when cancelled.
    @objc(askPassword)
    func askPassword() -> String! {
        let passwordWindow = horos_bonjourPasswordWindow
        horos_password?.stringValue = ""

        if let passwordWindow { window?.beginSheet(passwordWindow, completionHandler: nil) }

        let result = passwordWindow.map { NSApp.runModal(for: $0) } ?? .abort
        passwordWindow?.makeFirstResponder(nil)

        if let passwordWindow { passwordWindow.sheetParent?.endSheet(passwordWindow) }
        passwordWindow?.orderOut(self)

        if result == .stop {
            return horos_password?.stringValue
        }
        return nil
    }

    /// The local file of an image: its path, or for a shared database its
    /// copy in the cache, with up to `no` files fetched at once.
    @objc(getLocalDCMPath::)
    func getLocalDCMPath(_ obj: NSManagedObject!, _ no: Int) -> String! {
        if !(horos_databaseIvar?.isLocal() ?? false) {
            return (horos_databaseIvar as? RemoteDicomDatabase)?.cacheData(for: obj as? DicomImage, maxFiles: no)
        }
        return obj?.value(forKey: "completePath") as? String
    }

    @objc(displayBonjourServices)
    func displayBonjourServices() {
        horos_sourcesTableView?.reloadData()
    }

    @available(*, deprecated)
    @objc(switchToDefaultDBIfNeeded)
    func switchToDefaultDBIfNeeded() {
        resetToDefaultDatabaseIfNecessary()
    }

    /// Back to the local default database, unless it is the one shown.
    @objc(resetToDefaultDatabaseIfNecessary)
    func resetToDefaultDatabaseIfNecessary() {
        let defaults = UserDefaults.standard
        let defaultPath = DicomDatabase.baseDirPath(forMode: Int32(truncatingIfNeeded: defaults.integer(forKey: "DEFAULT_DATABASELOCATION")),
                                                    path: defaults.string(forKey: "DEFAULT_DATABASELOCATIONURL"))

        if DefaultDatabase.needsReset(shown: self.database?.baseDirPath, defaultPath: defaultPath) {
            resetToLocalDatabase()
        }
    }

    /// Shows the database of a folder, refusing a folder whose Database.sql is
    /// not a database index; on failure, back to the local database.
    @objc(openDatabasePath:)
    func openDatabasePath(_ path: String!) {
        let thread = Thread.current
        thread.name = NSLocalizedString("Opening database...", comment: "")
        let modal = thread.startModal(for: window)

        if let raised = BrowserObjC.attempt({
            let indexPath = (DicomDatabase.baseDirPath(forPath: path) as NSString?)?.appendingPathComponent("Database.sql")
            if let indexPath, FileManager.default.fileExists(atPath: indexPath), !HorosIsDatabaseFile(indexPath) {
                NSException(name: .genericException, reason: "The selected folder contains an unrecognized database index.", userInfo: nil).raise()
            }
            if let db = DicomDatabase(atPath: path) {
                self.database = db
            } else {
                NSException(name: .genericException, reason: "DicomDatabase == nil", userInfo: nil).raise()
            }
        }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController openDatabasePath:]")
            HorosAlertPanel.run(title: NSLocalizedString("IsiX DICOM Viewer Database", comment: ""),
                                message: NSLocalizedString("IsiX DICOM Viewer cannot read/create this file/folder. Permissions error?", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            resetToLocalDatabase()
        }

        modal?.invalidate()
    }

    @available(*, deprecated)
    @objc(localDatabasePath)
    var localDatabasePath: String! {
        DicomDatabase.activeLocal()?.sqlFilePath
    }
}
