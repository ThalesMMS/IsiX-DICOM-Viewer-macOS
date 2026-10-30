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

// Exporting DICOM files from the browser: the export to a folder (patient,
// study and series folders, or a DICOMDIR tree), its options, messages and
// errors, the series of ROIs and key images, and burning to a disc.

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
            text = name.mutableCopy() as! NSMutableString
        }
        text.setString(ExportNaming.replacingNotAdmitted(text as String, preserveHyphens: preserveHyphens))
        return text
    }

    /// The patient folder the export's folder naming options give the image.
    @objc(configuredPatientFolderForImage:naming:)
    nonisolated class func configuredPatientFolder(for image: NSManagedObject!, naming: ExportFolderNaming!) -> String! {
        let study = image?.value(forKeyPath: "series.study") as? NSManagedObject
        var identity = study?.value(forKey: "patientUID") as? String
        if (identity as NSString?)?.length ?? 0 == 0 { identity = study?.value(forKey: "studyInstanceUID") as? String }
        if (identity as NSString?)?.length ?? 0 == 0 { identity = study?.objectID.uriRepresentation().absoluteString }
        return naming.patientFolder(name: study?.value(forKey: "name") as? String, patientID: study?.value(forKey: "patientID") as? String,
                                    identity: identity ?? "")
    }

    @objc(dicomExportPatientFolderName:addDICOMDIR:)
    nonisolated class func dicomExportPatientFolderName(_ name: String!, addDICOMDIR: Bool) -> String! {
        return ExportNaming.patientFolder(name: name, addDICOMDIR: addDICOMDIR)
    }

    /// The error an Objective-C call reported; nil when it failed without
    /// one (Swift then throws a placeholder), as the caller saw it before.
    nonisolated static func reportedError(_ error: Error) -> NSError? {
        let error = error as NSError
        return error.domain == "Foundation._GenericObjCError" ? nil : error
    }

    // MARK: Messages

    /// An informational alert from a dictionary (title, message, button1-3);
    /// its answer is stored under "result". Called on the main thread.
    @objc(runInformationAlertPanel:)
    func runInformationAlertPanel(_ dict: NSMutableDictionary!) {
        let answer = HorosAlertPanel.runInformational(title: dict["title"] as? String ?? "", message: dict["message"] as? String ?? "",
                                                      defaultButton: dict["button1"] as? String, alternateButton: dict["button2"] as? String,
                                                      otherButton: dict["button3"] as? String)
        dict["result"] = NSNumber(value: Int32(answer))
    }

    /// A patient folder that was there before the export: replaced (emptied),
    /// merged, or the export is cancelled (NO).
    @objc(confirmDICOMExportFolder:)
    nonisolated func confirmDICOMExportFolder(_ path: String!) -> Bool {
        let options = NSMutableDictionary(dictionary: [
            "title": NSLocalizedString("Export", comment: ""),
            "message": String(format: NSLocalizedString("A folder already exists. Should I replace it? It will delete the entire content of this folder (%@), or merge the existing content with the new files?", comment: ""), (path as NSString).lastPathComponent),
            "button1": NSLocalizedString("Replace", comment: ""),
            "button2": NSLocalizedString("Cancel", comment: ""),
            "button3": NSLocalizedString("Merge", comment: ""),
        ])
        performSelector(onMainThread: #selector(runInformationAlertPanel(_:)), with: options, waitUntilDone: true)

        let answer = (options["result"] as? NSNumber)?.intValue ?? HorosAlertPanel.alternateResponse
        if answer == HorosAlertPanel.defaultResponse {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        } else if answer == HorosAlertPanel.otherResponse {
            // Merge
        } else {
            return false
        }
        return true
    }

    @objc(showDICOMExportCompletion:)
    func showDICOMExportCompletion(_ result: NSDictionary!) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("DICOM export completed", comment: "")
        alert.informativeText = String(format: NSLocalizedString("Exported files: %@\nDestination: %@", comment: ""),
                                       String(describing: result["count"] ?? "(null)"), String(describing: result["location"] ?? "(null)"))
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }

    /// The error, with what to check: access to the sources, the destination
    /// folder, free space and cloud providers.
    @objc(showDICOMExportError:)
    func showDICOMExportError(_ error: NSError!) {
        let alert = NSAlert(error: error)
        let guidance = NSLocalizedString("Check that the source files are accessible and the destination is a folder you can write to with enough free space. For OneDrive or another cloud provider, make source files available offline and check that the destination provider is available. Files already exported were kept.", comment: "")
        var details: [String] = []
        if !alert.informativeText.isEmpty {
            details.append(alert.informativeText)
        }
        if let reason = error.localizedFailureReason, !reason.isEmpty, (alert.informativeText as NSString).range(of: reason).location == NSNotFound {
            details.append(reason)
        }
        details.append(guidance)
        alert.informativeText = details.joined(separator: "\n\n")
        alert.runModal()
    }

    @objc(showEmptyDICOMExportSelection)
    func showEmptyDICOMExportSelection() {
        _ = HorosAlertPanel.runInformational(title: NSLocalizedString("DICOM Export", comment: ""),
                                             message: NSLocalizedString("No exportable files were found in the selection. Select a study, series, or image and check the export options before trying again.", comment: ""),
                                             defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    // MARK: Export

    @objc(exportDICOMFileInt:files:objects:)
    nonisolated func exportDICOMFileInt(_ location: String!, files filesToExport: NSMutableArray!, objects dicomFiles2Export: NSMutableArray!) -> [Any]! {
        let parameters = NSMutableDictionary()
        parameters["location"] = location
        if let filesToExport { parameters["filesToExport"] = filesToExport }
        if let dicomFiles2Export { parameters["dicomFiles2Export"] = dicomFiles2Export }
        return exportDICOMFileInt(parameters)
    }

    /// The export of files to a folder: location, filesToExport (paths) and
    /// dicomFiles2Export (images or their IDs), and optional addDICOMDIR,
    /// encrypt, password, folderNaming, folderTreeTag, compressionTag,
    /// quietErrors and showCompletion; options left out are read from the
    /// preferences and the export sheet. "result" gets the patient folders,
    /// "exportError" the error. Runs on any thread; returns the patient
    /// folders on the main thread, nil elsewhere.
    @objc(exportDICOMFileInt:)
    nonisolated func exportDICOMFileInt(_ parametersIn: NSDictionary!) -> [Any]! {
        // A caller gets "result" and "exportError" back in its own dictionary.
        let parameters: NSMutableDictionary = (parametersIn as? NSMutableDictionary) ?? NSMutableDictionary(dictionary: parametersIn ?? [:])
        let result = NSMutableArray()
        BrowserObjC.synchronized(parameters) { parameters["result"] = result }

        // The UI's database on the main thread; elsewhere a private-queue one,
        // and the export reads it on its queue.
        let idatabase = (Thread.isMainThread ? self.database : self.database?.privateQueueIndependentDatabase() as? DicomDatabase)
        idatabase?.performBlockAndWait {
            if let exception = BrowserObjC.attempt({
                self.exportDICOMFiles(parameters, result: result, database: idatabase!)
            }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController exportDICOMFileInt:]")
                let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("DICOM export could not be completed.", comment: ""),
                                               NSLocalizedFailureReasonErrorKey: exception.reason ?? ""])
                self.performSelector(onMainThread: #selector(BrowserController.showDICOMExportError(_:)), with: error, waitUntilDone: true)
            }
        }

        horos_passwordForExportEncryption = ""
        return Thread.isMainThread ? result as? [Any] : nil
    }

    /// A tag of the export sheet, read on the main thread.
    nonisolated private func exportSheetTag(_ parameters: NSDictionary, key: String, _ read: @escaping @MainActor () -> Int) -> Int {
        if let tag = parameters[key] as? NSNumber { return tag.intValue }
        if Thread.isMainThread { return MainActor.assumeIsolated { read() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { read() } }
    }

    nonisolated private func exportDICOMFiles(_ parameters: NSMutableDictionary, result: NSMutableArray, database idatabase: DicomDatabase) {
        let location = parameters["location"] as? String ?? ""
        let filesToExport = (parameters["filesToExport"] as? NSMutableArray) ?? NSMutableArray()
        let dicomFiles2Export = NSMutableArray(array: idatabase.objects(withIDs: parameters["dicomFiles2Export"] as? [Any]) ?? [])
        filesToExport.removeDuplicatedStrings(inSyncWithThisArray: dicomFiles2Export)

        let path = location
        let defaults = UserDefaults.standard
        // A file promise captured these before the drop; a menu export reads them now.
        let addDICOMDIR = (parameters["addDICOMDIR"] as? NSNumber)?.boolValue ?? defaults.bool(forKey: "AddDICOMDIRForExport")
        let encryptExport = (parameters["encrypt"] as? NSNumber)?.boolValue ?? defaults.bool(forKey: "encryptForExport")
        let exportPassword = parameters["password"] as? String ?? horos_passwordForExportEncryption
        let quietErrors = (parameters["quietErrors"] as? NSNumber)?.boolValue ?? false
        let folderOptions = parameters["folderNaming"] as? NSDictionary
        let customFolderNaming = (!addDICOMDIR && folderOptions != nil) ? ExportFolderNaming(options: folderOptions!) : nil
        var previousSeries = -1, serieCount = 0

        nonisolated(unsafe) var splash: Wait?
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                splash = Wait(string: NSLocalizedString("Exporting...", comment: ""), true)
            }
        }

        let files2Compress = NSMutableArray()
        var exportAborted = false
        var exportError: NSError?
        let exportedPaths = NSMutableSet()
        var exportedCount = 0
        let renameArray = NSMutableArray()
        let reviewedPatientFolders = NSMutableSet()
        // In the order they were first used: what is indexed and packaged afterwards.
        let patientFolders = NSMutableArray()
        let folderClaims = ExportFolderClaims()
        let files = FileManager.default

        let fileCount = Double(filesToExport.count)
        if let splash {
            MainActor.assumeIsolated {
                splash.setCancel(true)
                splash.showWindow(self)
                splash.progress()?.maxValue = fileCount
            }
        }

        DicomStudy.dbModifyLock()?.lock()
        if let exception = BrowserObjC.attempt({
            var i = 0
            while i < filesToExport.count {
                defer { i += 1 }
                let curImage = dicomFiles2Export[i] as! NSManagedObject
                var pathExtension = ((filesToExport[i] as! String) as NSString).pathExtension
                if let fileType = curImage.value(forKey: "fileType") as? String, fileType.hasPrefix("DICOM") {
                    pathExtension = "dcm"
                }
                if pathExtension.isEmpty { pathExtension = "dcm" }

                var tempPath = (path as NSString).appendingPathComponent(
                    BrowserController.dicomExportPatientFolderName(curImage.value(forKeyPath: "series.study.name") as? String, addDICOMDIR: addDICOMDIR))
                if let customFolderNaming {
                    tempPath = (path as NSString).appendingPathComponent(BrowserController.configuredPatientFolder(for: curImage, naming: customFolderNaming))
                }

                // Two patients of this export may come to the same folder name:
                // the later one gets a numbered sibling, as studies and series do.
                var patientSource = curImage.value(forKeyPath: "series.study.patientUID") as? String
                if (patientSource as NSString?)?.length ?? 0 == 0 { patientSource = curImage.value(forKeyPath: "series.study.studyInstanceUID") as? String }
                if (patientSource as NSString?)?.length ?? 0 == 0 {
                    patientSource = (curImage.value(forKeyPath: "series.study") as? NSManagedObject)?.objectID.uriRepresentation().absoluteString
                }
                tempPath = folderClaims.folder(source: patientSource ?? "", proposed: tempPath, componentLimit: addDICOMDIR ? 8 : 0)

                BrowserObjC.synchronized(parameters) { result.add((tempPath as NSString).lastPathComponent) }

                // Find the DICOM-PATIENT folder. Only one that was there before
                // this export is asked about, once.
                if !files.fileExists(atPath: tempPath) {
                    do {
                        try files.createDirectory(atPath: tempPath, withIntermediateDirectories: true, attributes: nil)
                    } catch let failure {
                        exportError = failure as NSError
                        exportAborted = true
                        break
                    }
                } else if !reviewedPatientFolders.contains(tempPath) {
                    if !self.confirmDICOMExportFolder(tempPath) {
                        exportAborted = true
                        break
                    }
                }
                if !reviewedPatientFolders.contains(tempPath) {
                    reviewedPatientFolders.add(tempPath)
                    patientFolders.add(tempPath)
                }

                let folderTreeSelectedTag = self.exportSheetTag(parameters, key: "folderTreeTag") {
                    self.horos_folderTree?.selectedTag() ?? 0
                }
                if folderTreeSelectedTag == 0 {
                    tempPath = (tempPath as NSString).appendingPathComponent(
                        ExportNaming.studyFolder(name: curImage.value(forKeyPath: "series.study.studyName") as? String,
                                                 id: curImage.value(forKeyPath: "series.study.id") as? String, addDICOMDIR: addDICOMDIR))
                    if let customFolderNaming, let study = curImage.value(forKeyPath: "series.study") as? NSManagedObject {
                        let component = customFolderNaming.studyFolder(name: study.value(forKey: "studyName") as? String, studyID: study.value(forKey: "id") as? String,
                                                                       uid: study.value(forKey: "studyInstanceUID") as? String,
                                                                       identity: study.objectID.uriRepresentation().absoluteString)
                        tempPath = ((tempPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(component)
                    }

                    // Two studies of this export never share a folder: the later
                    // one gets a numbered sibling. Older content was settled at
                    // the patient folder.
                    var studySource = curImage.value(forKeyPath: "series.study.studyInstanceUID") as? String
                    if (studySource as NSString?)?.length ?? 0 == 0 {
                        studySource = (curImage.value(forKeyPath: "series.study") as? NSManagedObject)?.objectID.uriRepresentation().absoluteString
                    }
                    tempPath = folderClaims.folder(source: studySource ?? "", proposed: tempPath, componentLimit: addDICOMDIR ? 8 : 0)

                    // Find the DICOM-STUDY folder
                    if !files.fileExists(atPath: tempPath) {
                        do {
                            try files.createDirectory(atPath: tempPath, withIntermediateDirectories: true, attributes: nil)
                        } catch let failure {
                            exportError = failure as NSError
                            exportAborted = true
                            break
                        }
                    }

                    let seriesNumber = (curImage.value(forKeyPath: "series.id") as? NSNumber) ?? NSNumber(value: 0)
                    tempPath = (tempPath as NSString).appendingPathComponent(
                        ExportNaming.seriesFolder(name: curImage.value(forKeyPath: "series.name") as? String, number: seriesNumber.stringValue,
                                                  addDICOMDIR: addDICOMDIR))
                    if let customFolderNaming, let series = curImage.value(forKey: "series") as? NSManagedObject {
                        let component = customFolderNaming.seriesFolder(name: series.value(forKey: "name") as? String, number: series.value(forKey: "id") as? NSNumber,
                                                                        uid: series.value(forKey: "seriesInstanceUID") as? String,
                                                                        identity: series.objectID.uriRepresentation().absoluteString)
                        tempPath = ((tempPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(component)
                    }

                    // The database splits one DICOM series into several, one per
                    // multi-frame file for instance: those go back into one
                    // folder. Different DICOM series under one name get numbered
                    // siblings.
                    var seriesSource = curImage.value(forKeyPath: "series.seriesDICOMUID") as? String
                    if (seriesSource as NSString?)?.length ?? 0 == 0 { seriesSource = curImage.value(forKeyPath: "series.seriesInstanceUID") as? String }
                    if (seriesSource as NSString?)?.length ?? 0 == 0 {
                        seriesSource = (curImage.value(forKey: "series") as? NSManagedObject)?.objectID.uriRepresentation().absoluteString
                    }
                    tempPath = folderClaims.folder(source: seriesSource ?? "", proposed: tempPath, componentLimit: addDICOMDIR ? 8 : 0)

                    // Find the DICOM-SERIE folder
                    if !files.fileExists(atPath: tempPath) {
                        do {
                            try files.createDirectory(atPath: tempPath, withIntermediateDirectories: true, attributes: nil)
                        } catch let failure {
                            exportError = failure as NSError
                            exportAborted = true
                            break
                        }
                    }
                }

                let imageNo = Int32(truncatingIfNeeded: BrowserObjC.intValue(curImage.value(forKey: "instanceNumber")))
                let seriesID = Int(BrowserObjC.intValue(curImage.value(forKeyPath: "series.id")))
                if previousSeries != seriesID {
                    previousSeries = seriesID
                    serieCount += 1
                }
                let count32 = Int32(truncatingIfNeeded: serieCount)
                var dest = ExportNaming.imageFile(folder: tempPath, seriesCount: count32, imageNumber: imageNo, pathExtension: pathExtension,
                                                  addDICOMDIR: addDICOMDIR)
                var attempt: Int32 = 2
                while files.fileExists(atPath: dest) {
                    dest = ExportNaming.imageFile(folder: tempPath, seriesCount: count32, imageNumber: imageNo, pathExtension: pathExtension,
                                                  addDICOMDIR: addDICOMDIR, attempt: attempt)
                    attempt += 1
                }

                var copyError: NSError?
                var copied = true
                do {
                    try BrowserController.horos_copyFile(forPublication: filesToExport[i] as? String, toPath: dest)
                } catch let failure {
                    copied = false
                    copyError = BrowserController.reportedError(failure)
                }
                if !copied {
                    NSLog("***** %@", copyError.map { String(describing: $0) } ?? "(null)")
                    NSLog("***** src = %@", String(describing: filesToExport[i]))
                    NSLog("***** dst = %@", dest)
                    exportError = copyError ?? NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                                       userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The destination for the DICOM export could not be determined.", comment: "")])
                    exportAborted = true
                    break
                }
                exportedPaths.add(dest)

                if attempt != 2 {
                    renameArray.add(["oldName": ExportNaming.imageFile(folder: tempPath, seriesCount: count32, imageNumber: imageNo, pathExtension: pathExtension,
                                                                       addDICOMDIR: addDICOMDIR),
                                     "newName": ExportNaming.imageFile(folder: tempPath, seriesCount: count32, imageNumber: imageNo, pathExtension: pathExtension,
                                                                       addDICOMDIR: addDICOMDIR, attempt: 1)])
                }

                if (curImage.value(forKey: "fileType") as? String)?.hasPrefix("DICOM") ?? false {
                    let compressionTag = self.exportSheetTag(parameters, key: "compressionTag") {
                        self.horos_compressionMatrix?.selectedTag() ?? 0
                    }
                    if compressionTag == 1 || compressionTag == 2 {
                        files2Compress.add(dest)
                    }
                }

                if pathExtension == "hdr" { // ANALYZE -> COPY IMG
                    try? files.copyItem(atPath: (((filesToExport[i] as! NSString).deletingPathExtension) as NSString).appendingPathExtension("img")!,
                                        toPath: ((dest as NSString).deletingPathExtension as NSString).appendingPathExtension("img")!)
                }

                if let splash { MainActor.assumeIsolated { splash.increment(by: 1) } }
                Thread.current.progress = CGFloat(Float(i) / Float(filesToExport.count))
                Thread.current.status = BrowserObjC.singularPlural(filesToExport.count - i, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))

                let aborted = splash.map { splash in MainActor.assumeIsolated { splash.aborted() } } ?? false
                if aborted || Thread.current.isCancelled {
                    i = filesToExport.count
                    exportAborted = true
                }
            }
        }) {
            BrowserObjC.log(exception, stack: true, "-[BrowserController exportDICOMFileInt:]")
            exportAborted = true
            exportError = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                  userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("DICOM export could not be completed.", comment: ""),
                                             NSLocalizedFailureReasonErrorKey: exception.reason ?? ""])
        }
        DicomStudy.dbModifyLock()?.unlock()

        let renamedSources = NSMutableSet()
        for case let rename as NSDictionary in renameArray {
            let oldName = rename["oldName"] as! String, newName = rename["newName"] as! String
            if renamedSources.contains(oldName) { continue }
            do {
                try files.moveItem(atPath: oldName, toPath: newName)
            } catch let failure {
                if exportError == nil { exportError = failure as NSError }
                exportAborted = true
                break
            }
            renamedSources.add(oldName)
            if exportedPaths.contains(oldName) {
                exportedPaths.remove(oldName)
                exportedPaths.add(newName)
            }
            for index in 0..<files2Compress.count where BrowserObjC.literallyEqual(files2Compress[index] as? String, oldName) {
                files2Compress[index] = newName
            }
        }

        // Close the progress window.
        if let splash { MainActor.assumeIsolated { splash.close() } }

        if let exportError {
            BrowserObjC.synchronized(parameters) { parameters["exportError"] = exportError }
            if !quietErrors {
                performSelector(onMainThread: #selector(BrowserController.showDICOMExportError(_:)), with: exportError, waitUntilDone: true)
            }
        }

        #if !OSIRIX_LIGHT
        if files2Compress.count > 0 && !exportAborted {
            let compressionTag = exportSheetTag(parameters, key: "compressionTag") {
                self.horos_compressionMatrix?.selectedTag() ?? 0
            }
            if compressionTag == 1 || compressionTag == 2 {
                var conversionError: NSError?
                var converted = true
                do {
                    try BrowserController.horos_processFiles(atPaths: files2Compress as? [Any], in: idatabase,
                                                             mode: Int32(compressionTag == 1 ? Compress : Decompress))
                } catch let failure {
                    converted = false
                    conversionError = BrowserController.reportedError(failure)
                }
                if !converted {
                    exportAborted = true
                    performSelector(onMainThread: #selector(BrowserController.showDICOMExportError(_:)), with: conversionError, waitUntilDone: true)
                }
            }
        }

        // A DICOMDIR per patient folder, so that dcmkdir scans the exported
        // folders only, not the rest of the destination.
        if addDICOMDIR && !exportAborted {
            for case let tempPath as String in patientFolders {
                Thread.current.status = NSLocalizedString("Writing DICOMDIR...", comment: "")
                var dicomdirError: NSError?
                var written = true
                do {
                    try BrowserController.horos_createDicomDir(atDir: tempPath)
                } catch let failure {
                    written = false
                    dicomdirError = BrowserController.reportedError(failure)
                }
                if !written {
                    exportAborted = true
                    performSelector(onMainThread: #selector(BrowserController.showDICOMExportError(_:)), with: dicomdirError, waitUntilDone: true)
                    break
                }
            }
        }
        #endif
        for case let exportedPath as String in exportedPaths where files.fileExists(atPath: exportedPath) {
            exportedCount += 1
        }

        // One archive for the whole export: studies of one person that differ
        // in patient ID or birth date get folders of their own, and a CT and
        // an echo exported together are still one file to send.
        if encryptExport && !exportAborted && patientFolders.count > 0 {
            var zipError: NSError?
            let folders = patientFolders.compactMap { $0 as? String }
            if !BrowserController.encryptFilesOrFolders(folders, inZIPFile: folderClaims.archivePath(forFolders: folders), password: exportPassword,
                                                        deleteSource: true, showGUI: !quietErrors, error: &zipError) {
                exportAborted = true
                BrowserObjC.synchronized(parameters) { if let zipError { parameters["exportError"] = zipError } }
                if !quietErrors {
                    performSelector(onMainThread: #selector(BrowserController.showDICOMExportError(_:)), with: zipError, waitUntilDone: true)
                }
            }
        }
        if !exportAborted && !Thread.current.isCancelled && exportedCount > 0 && ((parameters["showCompletion"] as? NSNumber)?.boolValue ?? false) {
            performSelector(onMainThread: #selector(BrowserController.showDICOMExportCompletion(_:)),
                            with: ["count": NSNumber(value: exportedCount), "location": location] as NSDictionary, waitUntilDone: true)
        }
    }

    /// File > Export > DICOM Files: the export sheet (folder naming, DICOMDIR,
    /// compression, encryption), then the export on a thread of the Activity
    /// window. The private SR series are left out unless "Add ROIs" is on.
    @objc(exportDICOMFile:)
    func exportDICOMFile(_ sender: Any!) {
        let exportMatrixSelection = isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix
        let hasSelection = exportMatrixSelection ? (horos_oMatrix?.selectedCells.count ?? 0) > 0 : (horos_databaseOutline?.selectedRowIndexes.count ?? 0) > 0
        guard hasSelection else {
            showEmptyDICOMExportSelection()
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("Select the location where to export the DICOM files:", comment: "")
        panel.prompt = NSLocalizedString("Choose", comment: "")
        panel.title = NSLocalizedString("Export", comment: "")
        panel.canCreateDirectories = true
        let accessory = horos_exportAccessoryView
        let legacyAccessoryFrame = accessory?.frame ?? .zero
        let folderOptionsView = accessory.map { ExportFolderOptions(legacyView: $0) }
        panel.accessoryView = folderOptionsView
        passwordForExportEncryption = ""

        horos_compressionMatrix?.selectCell(withTag: UserDefaults.standard.integer(forKey: "Compression Mode for Export"))

        let panelResult = panel.runModal()
        let folderOptions = panelResult == .OK ? folderOptionsView?.acceptedOptions() : nil
        accessory?.removeFromSuperview()
        accessory?.frame = legacyAccessoryFrame
        panel.accessoryView = accessory
        guard panelResult == .OK else { return }
        panel.makeFirstResponder(nil)

        var dicomFiles2Export = NSMutableArray()
        var filesToExport: NSMutableArray?

        let wait = WaitRendering(NSLocalizedString("Preparing the files...", comment: ""))
        wait?.showWindow(self)
        if exportMatrixSelection {
            filesToExport = files(forDatabaseMatrixSelection: dicomFiles2Export, onlyImages: false)
        } else {
            filesToExport = files(forDatabaseOutlineSelection: dicomFiles2Export, onlyImages: false)
        }
        if !UserDefaults.standard.bool(forKey: "AddROIsForExport") {
            if let exception = BrowserObjC.attempt({
                for predicate in ExportSeriesFilter.predicates() {
                    dicomFiles2Export = NSMutableArray(array: dicomFiles2Export.filtered(using: predicate))
                }
            }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController exportDICOMFile:]")
            }
            filesToExport = (dicomFiles2Export.value(forKey: "completePath") as? NSArray)?.mutableCopy() as? NSMutableArray
        }
        wait?.close()

        guard let filesToExport, filesToExport.count > 0, dicomFiles2Export.count > 0 else {
            showEmptyDICOMExportSelection()
            return
        }

        let parameters = NSMutableDictionary(dictionary: ["location": panel.url?.path as Any, "filesToExport": filesToExport,
                                                          "dicomFiles2Export": dicomFiles2Export.value(forKey: "objectID") as Any])
        if let folderOptions { parameters["folderNaming"] = folderOptions }
        parameters["showCompletion"] = NSNumber(value: true)
        let thread = Thread(target: self, selector: #selector(BrowserController.exportDICOMFileInt(_:)), object: parameters)
        thread.name = NSLocalizedString("Exporting...", comment: "")
        thread.supportsCancel = true
        thread.status = BrowserObjC.singularPlural(filesToExport.count, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))
        ThreadsManager.default()?.addThreadAndStart(thread)

        UserDefaults.standard.set(horos_compressionMatrix?.selectedTag() ?? 0, forKey: "Compression Mode for Export")
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
        let producedFiles = NSMutableArray()
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
                producedFiles.add(produced)
            }
        }

        if producedFiles.count > 0, let database = BrowserController.currentBrowser()?.database {
            var objects = database.addFiles(atPaths: producedFiles.value(forKey: "file") as? [Any], postNotifications: true, dicomOnly: true,
                                            rereadExistingItems: true, generatedByOsiriX: true)
            objects = database.objects(withIDs: objects)
            if let last = (objects as NSArray?)?.lastObject {
                _ = findAndSelectFile(nil, image: last as? DicomImage, shouldExpand: false)
            }
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

        let managedObjects = NSMutableArray()
        // Burn additional files, not just images: SRs too.
        let filesToBurn: NSMutableArray?
        if isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix {
            filesToBurn = files(forDatabaseMatrixSelection: managedObjects, onlyImages: false)
        } else {
            filesToBurn = files(forDatabaseOutlineSelection: managedObjects, onlyImages: false)
        }
        // The window stays open, retained, until it closes.
        let burner = BurnerWindowController(files: filesToBurn as? [Any], managedObjects: managedObjects as? [Any])
        _ = Unmanaged.passRetained(burner)
        burner.showWindow(self)
    }

    #endif
}
