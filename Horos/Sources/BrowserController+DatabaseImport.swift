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

// Adding files to the browser's database. What is dropped or chosen, the
// URLs and the WADO downloads are DroppedFilesImport (DroppedFilesImport.swift),
// the archives ArchiveImport (ArchiveImport.swift); the selectors the nib, the
// Objective-C, AppleScript and plugins send stay here as forwarding methods.
// Copying the linked files of the selection into the database folder is here.

extension BrowserController {

    /// Rebuilds the thumbnails of the viewers that are shown and not being
    /// dragged in.
    func rebuildViewers(_ vlToRebuild: NSMutableArray!) {
        for case let viewer as ViewerController in vlToRebuild ?? [] {
            if viewer.windowWillClose() == false && viewer.window?.isVisible == true && (viewer.imageView()?.mouseDragging ?? false) == false {
                viewer.buildMatrixPreview(false)
            }
        }
    }

    // MARK: WADO, archives, files and folders (DroppedFilesImport, ArchiveImport)

    @objc(asyncWADOXMLDownloadURL:)
    nonisolated class func asyncWADOXMLDownloadURL(_ url: URL!) {
        DroppedFilesImport.downloadWADOManifest(url)
    }

    @objc(expandArchiveIntoIncomingFolder:)
    func expandArchiveIntoIncomingFolder(_ archive: String!) {
        if let archive { archiveImport.expandIntoIncomingFolder(archive) }
    }

    @objc(addFilesAndFolderToDatabase:)
    func addFilesAndFolder(toDatabase filenames: [Any]!) {
        droppedFiles.add((filenames ?? []).compactMap { $0 as? String })
    }

    /// Adds the files a DICOMDIR lists to `files`.
    @objc(addDICOMDIR::)
    func addDICOMDIR(_ dicomdir: String!, _ files: NSMutableArray!) {
        DicomDirParser(dicomdir).parseArray(files)
    }

    /// The sheet's "Add" and "Cancel" (tag 1 and 0), or files chosen in
    /// Finder; the plugin bundles among them are installed.
    @objc(subSelectFilesAndFoldersToAdd:)
    func subSelectFilesAndFolders(toAdd filenames: [Any]!) {
        let plugins = droppedFiles.addOrOpen((filenames ?? []).compactMap { $0 as? String })
        if !plugins.isEmpty { AppController.shared()?.installPlugins(plugins) }
    }

    @objc(selectFilesAndFoldersToAdd:)
    func selectFilesAndFoldersToAdd(_ sender: Any!) {
        droppedFiles.chooseFilesAndFolders(sender)
    }

    // MARK: URLs (DroppedFilesImport)

    @discardableResult
    @objc(addURLToDatabaseFiles:)
    nonisolated func addURLToDatabaseFiles(_ URLs: [Any]!) -> [Any]! {
        return addURLToDatabaseFiles(URLs, report: nil)
    }

    /// A URL import, waited for on the calling thread, which must not be the
    /// main thread; the UI and AppleScript use -importURLs:completion:.
    @discardableResult
    @objc(addURLToDatabaseFiles:report:)
    nonisolated func addURLToDatabaseFiles(_ URLs: [Any]!, report: AutoreleasingUnsafeMutablePointer<NSString?>?) -> [Any]! {
        let result = DroppedFilesImport.importURLsWaiting((URLs ?? []).compactMap { $0 as? URL }, shownBy: self)
        report?.pointee = result.report as NSString?
        return result.files
    }

    @discardableResult
    @objc(importURLs:completion:)
    func importURLs(_ URLs: [Any]!, completion: (([Any]?, String?, Bool) -> Void)!) -> Thread! {
        return droppedFiles.importURLs((URLs ?? []).compactMap { $0 as? URL }, completion: completion ?? { _, _, _ in })
    }

    @objc(addURLToDatabaseEnd:)
    func addURLToDatabaseEnd(_ sender: Any!) {
        droppedFiles.endURLSheet(sender)
    }

    @objc(addURLToDatabase:)
    func addURLToDatabase(_ sender: Any!) {
        droppedFiles.showURLSheet()
    }

    // MARK: Copying into the database

    @objc(copyFilesThread:)
    nonisolated func copyFilesThread(_ dict: NSDictionary!) {
        self.database?.copyFilesThread(dict as? [AnyHashable: Any])
    }

    /// Copies the linked files of the selection into the database folder.
    @objc(copyToDBFolder:)
    func copyToDBFolder(_ sender: Any!) {
        guard let database = self.database, database.isLocal() else { return }

        var fromThumbnails = false
        if isThumbnailMenuItem(sender) || self.window?.firstResponder === horos_oMatrix {
            fromThumbnails = true
            NSLog("copyToDBFolder from matrix")
        }
        let objects = NSMutableArray()
        let files = (fromThumbnails ? files(forDatabaseMatrixSelection: objects, onlyImages: false)
                                    : files(forDatabaseOutlineSelection: objects, onlyImages: false)) ?? NSMutableArray()

        let splash = Wait(string: NSLocalizedString("Copying linked files into Database...", comment: ""), true)
        splash?.showWindow(self)
        splash?.progress()?.maxValue = Double(objects.count)
        splash?.setCancel(true)

        files.removeDuplicatedStrings(inSyncWithThisArray: objects)

        if let exception = HorosObjCException.caught({
            for case let image as NSManagedObject in objects {
                if (image.value(forKey: "inDatabaseFolder") as? NSNumber)?.boolValue == false || image.value(forKey: "inDatabaseFolder") == nil {
                    copyIntoDatabaseFolder(image, database: database)
                }
                splash?.increment(by: 1)
                if splash?.aborted() == true { break }
            }
        }) {
            BrowserObjC.log(exception, stack: true, "-[BrowserController copyToDBFolder:]")
        }
        splash?.close()
    }

    /// Copies a linked image's file into the data folder and points the
    /// image, and the other frames of the same file, at the copy.
    private func copyIntoDatabaseFolder(_ image: NSManagedObject, database: DicomDatabase) {
        guard let source = image.value(forKey: "completePath") as? String else { return }
        let isDICOM = (image.value(forKey: "fileType") as? NSString)?.hasPrefix("DICOM") ?? false
        let pathExtension = DataFileExtension.forLinkedFile(pathExtension: (source as NSString).pathExtension, isDICOM: isDICOM)
        guard let destination = database.uniquePathForNewDataFile(withExtension: pathExtension),
              (try? FileManager.default.copyItem(atPath: source, toPath: destination)) != nil else { return }

        let series = image.value(forKey: "series") as? NSManagedObject
        series?.setValue(NSNumber(value: false), forKey: "mountedVolume")
        for case let frame as NSManagedObject in ((image.value(forKeyPath: "series.images") as? NSSet)?.allObjects ?? []) {
            if BrowserObjC.literallyEqual(frame.value(forKey: "completePath") as? String, source) {
                frame.setValue(NSNumber(value: true), forKey: "inDatabaseFolder")
                frame.setValue((destination as NSString).lastPathComponent, forKey: "path")
                frame.setValue(NSNumber(value: false), forKey: "mountedVolume")
            }
        }
    }

    /// Imports files into the local database, copied or linked
    /// (DroppedFilesImport); cancelling empties `filesInput`.
    @objc(copyFilesIntoDatabaseIfNeeded:options:)
    func copyFilesIntoDatabaseIfNeeded(_ filesInput: NSMutableArray!, options: [AnyHashable: Any]!) {
        if !droppedFiles.importFiles((filesInput ?? []).compactMap { $0 as? String }, options: options ?? [:]) {
            filesInput?.removeAllObjects()
        }
    }
}
