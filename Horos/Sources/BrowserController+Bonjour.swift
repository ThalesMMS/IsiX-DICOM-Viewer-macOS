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

// Bonjour and the databases the browser opens: a shared database's password,
// the local copy of a shared database's image, the sources list, going back
// to the default database when Bonjour sharing changes, and opening a
// database folder, which DatabaseOpener does. The selectors are those of the
// former Objective-C methods.

extension BrowserController {

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

    /// The local file of an image of the database the browser shows, with up
    /// to `no` files fetched at once (DatabaseImageFiles.localFile).
    @objc(getLocalDCMPath::)
    func getLocalDCMPath(_ obj: NSManagedObject!, _ no: Int) -> String! {
        DatabaseImageFiles.localFile(of: obj, in: horos_databaseIvar, maxFiles: no)
    }

    @objc(displayBonjourServices)
    func displayBonjourServices() {
        horos_sourcesTableView?.reloadData()
    }

    /// Back to the local default database, unless it is the one shown.
    @objc(resetToDefaultDatabaseIfNecessary)
    func resetToDefaultDatabaseIfNecessary() {
        databaseOpener.resetToDefaultIfNeeded()
    }

    /// Shows the database of a folder; on failure, back to the local database.
    @objc(openDatabasePath:)
    func openDatabasePath(_ path: String!) {
        databaseOpener.openFolder(path)
    }

    @available(*, deprecated)
    var localDatabasePath: String! {
        DicomDatabase.activeLocal()?.sqlFilePath
    }
}

/// The file here of a database's image: its path, or for a shared database of
/// another computer its copy in the cache, fetched from the server when it is
/// missing.
enum DatabaseImageFiles {
    /// The file of `image`, a row of `database`, with up to `maxFiles` files
    /// fetched at once; nil without a database.
    static func localFile(of image: NSManagedObject?, in database: DicomDatabase?, maxFiles: Int) -> String? {
        guard let database else { return nil }
        if !database.isLocal() {
            return (database as? RemoteDicomDatabase)?.cacheData(for: image as? DicomImage, maxFiles: maxFiles)
        }
        return (image as? DicomImage)?.completePath()
    }

    /// The file of `image`, asked of the database it is a row of, which the
    /// browser may not show: a viewer of a shared study stays open beside a
    /// browser showing a local database, and the reverse.
    static func localFile(ofRow image: NSManagedObject?) -> String? {
        if let shared = RemoteDicomDatabase.database(of: image) {
            return localFile(of: image, in: shared, maxFiles: 0)
        }
        return (image as? DicomImage)?.completePath()
    }
}
