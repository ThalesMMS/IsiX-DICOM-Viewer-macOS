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


import Foundation
import IsiXDatabase

// What becomes of the files an import does not index: a file inside the
// database folder that cannot be indexed leaves it, for the NOT READABLE
// folder or, with DELETEFILELISTENER, for good; and what a scan moved out of
// the incoming folder and did not index goes back there. Plain Swift members
// of DicomDatabase, called by the import and the scan of the incoming folder.

extension DicomDatabase {

    /// A name of its own in `directory`: two archives can each hold a
    /// readme.txt, and two senders can each send a file called IM1. Moving the
    /// second one onto the first fails, and the fallback then deleted it - the
    /// opposite of what the preference that keeps unreadable files asks for.
    final func availablePath(inDirectory directory: String?, name: String) -> String? {
        guard let directory else { return nil }
        return AvailablePath.inDirectory(directory, name: name)
    }

    /// A file inside the database folder that cannot be indexed has to leave it,
    /// or it sits there for ever with no row pointing at it. This used to be
    /// done only for a file that opened and produced no dictionary; a file that
    /// -[DicomFile init:] could not construct at all fell outside the enclosing
    /// if( curFile) and was left where it was. Measured on an import of 1204
    /// files, one truncated: the database folder ended with 1201 files for 1200
    /// images, and NOT READABLE was empty.
    final func disposeOfUnreadable(_ unreadable: String, dataDirPath: String?, errorsDirPath: String?, deleteFileListener: Bool) {
        guard let dataDirPath, unreadable.hasPrefix(dataDirPath) else { return }

        let manager = FileManager.default
        // The image stored beside an Analyze or NIfTI header leaves with it.
        let pairedImage = HeaderImagePair.imagePath(forHeader: unreadable)
        let name = (unreadable as NSString).lastPathComponent

        if deleteFileListener {
            do {
                try manager.removeItem(atPath: unreadable)
                NSLog("---- import: %@ could not be indexed; deleted (DELETEFILELISTENER)", name)
                if let pairedImage { try? manager.removeItem(atPath: pairedImage) }
            } catch {
                NSLog("---- import: %@ could not be indexed and could not be deleted (%@); it stays in the database folder",
                      name, DicomDatabaseObjC.arg((error as NSError).localizedDescription))
            }
            return
        }

        let kept = availablePath(inDirectory: errorsDirPath, name: name)
        do {
            guard let kept else { throw CocoaError(.fileNoSuchFile) }
            try manager.moveItem(atPath: unreadable, toPath: kept)
            NSLog("---- import: %@ could not be indexed; kept in %@", name, DicomDatabaseObjC.arg((errorsDirPath as NSString?)?.lastPathComponent))
            if let pairedImage {
                var keptImage: String? = HeaderImagePair.imagePath(besideStoredHeader: kept)
                if DicomDatabaseObjC.fileExists(keptImage) {
                    keptImage = availablePath(inDirectory: errorsDirPath, name: (pairedImage as NSString).lastPathComponent)
                }
                if (try? keptImage.map { try manager.moveItem(atPath: pairedImage, toPath: $0) }) == nil {
                    try? manager.removeItem(atPath: pairedImage)
                }
            }
        } catch {
            NSLog("---- import: %@ could not be indexed and could not be kept (%@); deleted",
                  name, DicomDatabaseObjC.arg((error as NSError).localizedDescription))
            try? manager.removeItem(atPath: unreadable)
            if let pairedImage { try? manager.removeItem(atPath: pairedImage) }
        }
    }

    /// A described file that turned out unreadable, inside the database folder:
    /// deleted with DELETEFILELISTENER, moved to NOT READABLE otherwise, and
    /// deleted when it cannot be moved there.
    final func removeUnreadableDescribedFile(_ newFile: String?, dataDirPath: String?, errorsDirPath: String?, deleteFileListener: Bool) {
        guard let newFile, let dataDirPath, newFile.hasPrefix(dataDirPath) else { return }
        NSLog("**** Unreadable file: %@", newFile)

        if deleteFileListener {
            try? FileManager.default.removeItem(atPath: newFile)
        } else {
            let destination = DicomDatabaseObjC.appending(errorsDirPath, (newFile as NSString).lastPathComponent)
            if (try? destination.map { try FileManager.default.moveItem(atPath: newFile, toPath: $0) }) == nil {
                try? FileManager.default.removeItem(atPath: newFile)
            }
        }
    }

    // What a pass moved out of the incoming folder and did not index goes back
    // there, under the name it arrived with: left in the database folder it had no
    // row, and nothing would ever index it.
    final func returnFilesToIncomingDir(_ paths: [String]) {
        if paths.isEmpty { return }

        NSLog("---- import: %lu file(s) not indexed go back to the incoming folder", UInt(paths.count))

        for path in paths {
            if !FileManager.default.fileExists(atPath: path) { // refused files were already disposed of
                continue
            }

            var name = ImportedFileNames.name(forPath: path) ?? ""
            if (name as NSString).length == 0 || name.hasPrefix(".") {
                name = (path as NSString).lastPathComponent
            }
            let back = availablePath(inDirectory: self.incomingDirPath(), name: name)
            let pairedImage = HeaderImagePair.imagePath(forHeader: path)
            do {
                guard let back else { throw CocoaError(.fileNoSuchFile) }
                try FileManager.default.moveItem(atPath: path, toPath: back)
                if let pairedImage, let besideBack = ((back as NSString).deletingPathExtension as NSString).appendingPathExtension((pairedImage as NSString).pathExtension) {
                    try? FileManager.default.moveItem(atPath: pairedImage, toPath: besideBack)
                }
            } catch {
                NSLog("---- import: %@ was not indexed and could not go back to the incoming folder (%@)",
                      (path as NSString).lastPathComponent, DicomDatabaseObjC.arg((error as NSError).localizedDescription))
            }
        }
    }
}
