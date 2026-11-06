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

// The ZIP archives of the former SDK's names: plain or encrypted archives of
// files and folders, and the protected attachment of "Send by e-mail", which
// IsiXDatabase's ProtectedZipArchiver makes with /usr/bin/zip.

extension BrowserController {

    /// The files, at the archive's root, in groups of a thousand.
    @objc(encryptFiles:inZIPFile:password:)
    nonisolated class func encryptFiles(_ srcFiles: [Any]!, inZIPFile destFile: String!, password: String!) {
        DICOMFolderExport.archiveFlat((srcFiles ?? []).compactMap { $0 as? String }, to: destFile ?? "", password: password)
    }

    @objc(encryptFileOrFolder:inZIPFile:password:)
    nonisolated class func encryptFileOrFolder(_ srcFolder: String!, inZIPFile destFile: String!, password: String!) {
        BrowserController.encryptFileOrFolder(srcFolder, inZIPFile: destFile, password: password, deleteSource: true, showGUI: true)
    }

    @objc(encryptFileOrFolder:inZIPFile:password:deleteSource:)
    nonisolated class func encryptFileOrFolder(_ srcFolder: String!, inZIPFile destFile: String!, password: String!, deleteSource: Bool) {
        BrowserController.encryptFileOrFolder(srcFolder, inZIPFile: destFile, password: password, deleteSource: deleteSource, showGUI: true)
    }

    @objc(encryptFileOrFolder:inZIPFile:password:deleteSource:showGUI:)
    nonisolated class func encryptFileOrFolder(_ srcFolder: String!, inZIPFile destFile: String!, password: String!, deleteSource: Bool, showGUI: Bool) {
        try? BrowserController.zipFileOrFolder(srcFolder, inZIPFile: destFile, password: password, deleteSource: deleteSource,
                                               showGUI: showGUI)
    }

    /// The archive wrapped in a generic encrypted entry, Images.zip; a password is required.
    @objc(prepareProtectedEmailAttachment:destination:password:error:)
    nonisolated class func prepareProtectedEmailAttachment(_ source: String!, destination: String!, password: String!) throws {
        try ProtectedZipArchiver().protectedAttachment(from: source ?? "", to: destination ?? "", password: password)
    }

    @objc(encryptFileOrFolder:inZIPFile:password:deleteSource:showGUI:error:)
    nonisolated class func zipFileOrFolder(_ srcFolder: String!, inZIPFile destFile: String!, password: String!, deleteSource: Bool,
                                           showGUI: Bool) throws {
        let items: [Any] = ((srcFolder as NSString?)?.length ?? 0) > 0 ? [srcFolder!] : []
        try BrowserController.encryptFilesOrFolders(items, inZIPFile: destFile, password: password, deleteSource: deleteSource,
                                                    showGUI: showGUI)
    }

    /// The items, which must share one folder, each under its own name; the
    /// archive is published only when zip succeeded, and the sources are then
    /// removed if asked.
    @objc(encryptFilesOrFolders:inZIPFile:password:deleteSource:showGUI:error:)
    nonisolated class func encryptFilesOrFolders(_ srcItems: [Any]!, inZIPFile destFile: String!, password: String!, deleteSource: Bool,
                                                 showGUI: Bool) throws {
        try DICOMFolderExport.archive((srcItems ?? []).compactMap { $0 as? String }, to: destFile ?? "", password: password,
                                      deletingSources: deleteSource, showGUI: showGUI)
    }
}
