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

// Exporting DICOM files from the browser: the names of the former SDK, the
// export to a folder, which DICOMFolderExport makes, the series of ROIs and
// key images, and burning to a disc.

extension BrowserController {

    // MARK: Names

    @objc(replaceNotAdmitted:)
    nonisolated class func replaceNotAdmitted(_ name: NSString!) -> NSMutableString! {
        return BrowserController.replaceNotAdmitted(name, preserveHyphens: false)
    }

    /// The name cleaned for a file system (ExportNaming.replacingNotAdmitted).
    /// A mutable string is cleaned in place and returned; another is copied.
    @objc(replaceNotAdmitted:preserveHyphens:)
    nonisolated class func replaceNotAdmitted(_ name: NSString!, preserveHyphens: Bool) -> NSMutableString! {
        guard let name else { return nil }
        // Foundation string cluster subclasses can report mutable ancestry
        // even for immutable instances: the coding class tells them apart.
        let text: NSMutableString
        if let mutable = name as? NSMutableString, (name.classForCoder as AnyClass).isSubclass(of: NSMutableString.self) {
            text = mutable
        } else {
            text = NSMutableString(string: name as String)
        }
        text.setString(ExportNaming.replacingNotAdmitted(text as String, preserveHyphens: preserveHyphens))
        return text
    }

    // MARK: Export

    /// The export of the files to a folder (DICOMFolderExport), with the
    /// options of the preferences and the export sheet. Runs on any thread;
    /// returns the patient folder of each file on the main thread, nil elsewhere.
    @objc(exportDICOMFileInt:files:objects:)
    nonisolated func exportDICOMFileInt(_ location: String!, files filesToExport: NSMutableArray!, objects dicomFiles2Export: NSMutableArray!) -> [Any]! {
        let request = exportRequest(location: location ?? "", files: filesToExport as? [Any], objects: dicomFiles2Export as? [Any], options: [:])
        let result = DICOMFolderExport().run(request, for: self)
        return Thread.isMainThread ? result.patientFolderNames : nil
    }

    /// The export of a dictionary: location, filesToExport (paths) and
    /// dicomFiles2Export (images or their IDs), and optional addDICOMDIR,
    /// encrypt, password, folderNaming, folderTreeTag, compressionTag,
    /// quietErrors and showCompletion; options left out are read from the
    /// preferences and the export sheet. A mutable dictionary gets "result",
    /// the patient folders, and "exportError". Runs on any thread; returns the
    /// patient folders on the main thread, nil elsewhere.
    @objc(exportDICOMFileInt:)
    nonisolated func exportDICOMFileInt(_ parameters: NSDictionary!) -> [Any]! {
        let options = parameters as? [String: Any] ?? [:]
        let request = exportRequest(location: options["location"] as? String ?? "", files: options["filesToExport"] as? [Any],
                                    objects: options["dicomFiles2Export"] as? [Any], options: options)
        let result = DICOMFolderExport().run(request, for: self)
        if let reply = parameters as? NSMutableDictionary {
            HorosObjCException.synchronized(reply) {
                reply["result"] = result.patientFolderNames
                if let error = result.error { reply["exportError"] = error }
            }
        }
        return Thread.isMainThread ? result.patientFolderNames : nil
    }

    /// The typed request of the dictionary's options; the sheet's tags are
    /// read on the main thread when the caller gave none.
    nonisolated private func exportRequest(location: String, files: [Any]?, objects: [Any]?, options: [String: Any]) -> DICOMFolderExportRequest {
        func flag(_ key: String) -> Bool? { (options[key] as? NSNumber)?.boolValue }
        let given = (folderTree: (options["folderTreeTag"] as? NSNumber)?.intValue, compression: (options["compressionTag"] as? NSNumber)?.intValue)
        let read = given.folderTree == nil || given.compression == nil
        let tags = read ? onMainActorSync { (folderTree: self.horos_folderTree?.selectedTag() ?? 0, compression: self.horos_compressionMatrix?.selectedTag() ?? 0) } : (folderTree: 0, compression: 0)
        return DICOMFolderExportRequest(location: location, files: (files ?? []).compactMap { $0 as? String },
                                        objects: (objects ?? []).compactMap { ($0 as? NSManagedObjectID) ?? ($0 as? NSManagedObject)?.objectID },
                                        addDICOMDIR: flag("addDICOMDIR"), encrypt: flag("encrypt"),
                                        password: options["password"] as? String ?? horos_passwordForExportEncryption ?? "",
                                        folderNaming: (options["folderNaming"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.intValue },
                                        folderTreeTag: given.folderTree ?? tags.folderTree, compressionTag: given.compression ?? tags.compression,
                                        quietErrors: flag("quietErrors") ?? false, showCompletion: flag("showCompletion") ?? false)
    }

    /// File > Export > DICOM Files: the export sheet, then the export on a
    /// thread of the Activity window (DICOMFolderExport).
    @objc(exportDICOMFile:)
    func exportDICOMFile(_ sender: Any!) {
        DICOMFolderExport.chooseFolderAndExport(from: self, thumbnails: isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix)
    }

    #if !OSIRIX_LIGHT

    /// A new series of screen captures of the selection's images with ROIs
    /// and key images (Option: key images only; Shift: ROIs only), added to
    /// the database and selected.
    @objc(exportROIAndKeyImagesAsDICOMSeries:)
    func exportROIAndKeyImagesAsDICOMSeries(_ sender: Any!) {
        let wait = WaitRendering(NSLocalizedString("Generating the DICOM files...", comment: ""))
        wait?.showWindow(self)

        let exporter = DICOMExport()
        var producedFiles: [Any] = []
        exporter.setSeriesDescription(NSLocalizedString("ROIs and Key Images", comment: ""))
        exporter.setSeriesNumber(0)

        let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []
        let images: [Any]?
        if flags.contains(.option) {
            images = keyImages(self)
        } else if flags.contains(.shift) {
            images = roiImages(self)
        } else {
            images = roisAndKeyImages(self)
        }
        for case let image as DicomImage in images ?? [] {
            if let produced = image.imageAsDICOMScreenCaptureDictionary(exporter) {
                producedFiles.append(produced["file"] ?? NSNull())
            }
        }

        if !producedFiles.isEmpty, let last = GeneratedSeriesImport.process.images(indexing: producedFiles)?.last {
            _ = findAndSelectFile(nil, image: last as? DicomImage, shouldExpand: false)
        }
        wait?.close()
    }

    /// A burn window for the selection; one at a time.
    @objc(burnDICOM:)
    func burnDICOM(_ sender: Any!) {
        for window in NSApp.windows where window.windowController is BurnerWindowController {
            _ = HorosAlertPanel.runInformational(title: NSLocalizedString("Burn", comment: ""),
                                                 message: NSLocalizedString("A burn session is already opened. Close it to burn a new study.", comment: ""),
                                                 defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            window.makeKeyAndOrderFront(self)
            return
        }

        // Burn additional files, not just images: SRs too.
        let selection = SelectedFiles(of: self, thumbnails: isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix, onlyImages: false)
        // The window stays open, retained, until it closes.
        let burner = BurnerWindowController(files: selection.paths, managedObjects: selection.objects)
        _ = Unmanaged.passRetained(burner)
        burner.showWindow(self)
    }

    #endif
}
