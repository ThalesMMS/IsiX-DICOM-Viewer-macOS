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
import IsiXPreferences

/// What an export of DICOM files to a folder is asked for.
struct DICOMFolderExportRequest: Sendable {
    /// The folder the patient folders go into.
    var location: String
    /// The files, in step with `objects`.
    var files: [String]
    /// The database images of the files.
    var objects: [NSManagedObjectID]
    /// A DICOMDIR tree per patient folder; the preference when nil.
    var addDICOMDIR: Bool?
    /// The folders packed into one ZIP archive protected by `password`; the preference when nil.
    var encrypt: Bool?
    var password: String
    /// The fields the folders are named after, as the export sheet accepted them
    /// (patient, study, series); nil for the usual names.
    var folderNaming: [String: Int]?
    /// The folder tree of the export sheet: 0 for patient, study and series folders.
    var folderTreeTag: Int
    /// The compression of the export sheet: 1 compresses, 2 decompresses the DICOM files.
    var compressionTag: Int
    /// No alert for the errors the caller reports itself.
    var quietErrors = false
    /// The count of exported files and the destination shown at the end.
    var showCompletion = false
}

/// What an export to a folder did.
struct DICOMFolderExportResult: Sendable {
    /// The patient folder each exported file went to, once per file, in order.
    var patientFolderNames: [String] = []
    var error: NSError?
}

/// The export of DICOM files to a folder: patient, study and series folders
/// (or a DICOMDIR tree), named by IsiXDatabase's ExportNaming or the fields
/// the export sheet chose, compressed or decompressed by the database, indexed
/// in a DICOMDIR per patient folder, and packed into one protected ZIP archive.
/// It runs on the calling thread; on the main thread it shows its progress.
final class DICOMFolderExport: Sendable {
    private let preferences: any PreferenceStore
    private let archiver: ProtectedZipArchiver

    init(preferences: any PreferenceStore = PreferencesSource.process.preferences, archiver: ProtectedZipArchiver = ProtectedZipArchiver()) {
        self.preferences = preferences
        self.archiver = archiver
    }

    /// The export of `request` from the browser's database on the main thread,
    /// from a private-queue one elsewhere; the export password of the browser
    /// is cleared afterwards.
    func run(_ request: DICOMFolderExportRequest, for browser: BrowserController) -> DICOMFolderExportResult {
        var result = DICOMFolderExportResult()
        let database = Thread.isMainThread ? browser.database : browser.database?.privateQueueIndependentDatabase() as? DicomDatabase
        if let database {
            result = run(request, in: database)
        }
        browser.horos_passwordForExportEncryption = ""
        return result
    }

    /// The export of `request`, on the queue of `database`.
    func run(_ request: DICOMFolderExportRequest, in database: DicomDatabase) -> DICOMFolderExportResult {
        let outcome = Outcome()
        database.performBlockAndWait {
            if let exception = HorosObjCException.caught({ self.export(request, database: database, into: outcome) }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController exportDICOMFileInt:]")
                Self.presentError(Self.incompleteExportError(reason: exception.reason))
            }
        }
        return outcome.result
    }

    /// The result as the export fills it: an object, not a value passed inout,
    /// because an Objective-C exception may unwind through the export, and an
    /// unwound inout access would be left open.
    private final class Outcome {
        var result = DICOMFolderExportResult()
    }

    // MARK: Export

    private func export(_ request: DICOMFolderExportRequest, database: DicomDatabase, into outcome: Outcome) {
        let location = request.location
        let unique = SelectedFiles(paths: request.files, objects: database.objects(withIDs: request.objects)?.compactMap { $0 as? NSManagedObject } ?? [])
            .removingDuplicatePaths()
        let paths = unique.paths, images = unique.objects.map { $0 as? DicomImage }

        // A file promise captured these before the drop; a menu export reads them now.
        let addDICOMDIR = request.addDICOMDIR ?? preferences[ApplicationPreferences.addDICOMDIRForExport]
        let encryptExport = request.encrypt ?? preferences[ApplicationPreferences.encryptsExport]
        let customFolderNaming = request.folderNaming.flatMap { addDICOMDIR ? nil : ExportFolderNaming(options: $0 as NSDictionary) }
        let componentLimit = addDICOMDIR ? 8 : 0
        let compresses = request.compressionTag == 1 || request.compressionTag == 2
        var previousSeries = -1, serieCount = 0

        let splash: ExportSplash? = Thread.isMainThread ? MainActor.assumeIsolated { ExportSplash(count: paths.count) } : nil

        var filesToCompress: [String] = []
        var exportAborted = false
        var exportError: NSError?
        var exportedPaths = Set<String>()
        var renames: [(oldName: String, newName: String)] = []
        var reviewedPatientFolders = Set<String>()
        // In the order they were first used: what is indexed and packaged afterwards.
        var patientFolders: [String] = []
        let folderClaims = ExportFolderClaims()
        let files = FileManager.default

        DicomStudy.dbModifyLock()?.lock()
        if let exception = HorosObjCException.caught({
            var i = 0
            while i < paths.count {
                defer { i += 1 }
                guard i < images.count, let image = images[i] else {
                    exportError = Self.incompleteExportError(reason: "The image of \(paths[i]) is not in the database.")
                    exportAborted = true
                    break
                }
                let source = paths[i]
                let series = image.series
                let study = series?.study
                var pathExtension = (source as NSString).pathExtension
                if image.fileType()?.hasPrefix("DICOM") ?? false {
                    pathExtension = "dcm"
                }
                if pathExtension.isEmpty { pathExtension = "dcm" }

                var tempPath = (location as NSString).appendingPathComponent(ExportNaming.patientFolder(name: study?.name, addDICOMDIR: addDICOMDIR))
                if let customFolderNaming {
                    tempPath = (location as NSString).appendingPathComponent(Self.configuredPatientFolder(of: study, naming: customFolderNaming))
                }

                // Two patients of this export may come to the same folder name:
                // the later one gets a numbered sibling, as studies and series do.
                let patientSource = Self.identity(study?.patientUID, study?.studyInstanceUID, of: study)
                tempPath = folderClaims.folder(source: patientSource, proposed: tempPath, componentLimit: componentLimit)

                outcome.result.patientFolderNames.append((tempPath as NSString).lastPathComponent)

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
                    if !Self.confirmExistingFolder(tempPath) {
                        exportAborted = true
                        break
                    }
                }
                if reviewedPatientFolders.insert(tempPath).inserted {
                    patientFolders.append(tempPath)
                }

                if request.folderTreeTag == 0 {
                    tempPath = (tempPath as NSString).appendingPathComponent(
                        ExportNaming.studyFolder(name: study?.studyName, id: study?.id, addDICOMDIR: addDICOMDIR))
                    if let customFolderNaming, let study {
                        let component = customFolderNaming.studyFolder(name: study.studyName, studyID: study.id, uid: study.studyInstanceUID,
                                                                       identity: study.objectID.uriRepresentation().absoluteString)
                        tempPath = ((tempPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(component)
                    }

                    // Two studies of this export never share a folder: the later
                    // one gets a numbered sibling. Older content was settled at
                    // the patient folder.
                    let studySource = Self.identity(study?.studyInstanceUID, of: study)
                    tempPath = folderClaims.folder(source: studySource, proposed: tempPath, componentLimit: componentLimit)

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

                    let seriesNumber = series?.id ?? NSNumber(value: 0)
                    tempPath = (tempPath as NSString).appendingPathComponent(
                        ExportNaming.seriesFolder(name: series?.name, number: seriesNumber.stringValue, addDICOMDIR: addDICOMDIR))
                    if let customFolderNaming, let series {
                        let component = customFolderNaming.seriesFolder(name: series.name, number: series.id, uid: series.seriesInstanceUID,
                                                                        identity: series.objectID.uriRepresentation().absoluteString)
                        tempPath = ((tempPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(component)
                    }

                    // The database splits one DICOM series into several, one per
                    // multi-frame file for instance: those go back into one
                    // folder. Different DICOM series under one name get numbered
                    // siblings.
                    let seriesSource = Self.identity(series?.seriesDICOMUID, series?.seriesInstanceUID, of: series)
                    tempPath = folderClaims.folder(source: seriesSource, proposed: tempPath, componentLimit: componentLimit)

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

                let imageNo = image.instanceNumber?.int32Value ?? 0
                let seriesID = Int(series?.id?.int32Value ?? 0)
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

                do {
                    try BrowserController.horos_copyFile(forPublication: source, toPath: dest)
                } catch let failure {
                    let copyError = objcReportedError(failure)
                    NSLog("***** %@", copyError.map { String(describing: $0) } ?? "(null)")
                    NSLog("***** src = %@", source)
                    NSLog("***** dst = %@", dest)
                    exportError = copyError ?? NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                                       userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The destination for the DICOM export could not be determined.", comment: "")])
                    exportAborted = true
                    break
                }
                exportedPaths.insert(dest)

                if attempt != 2 {
                    renames.append((oldName: ExportNaming.imageFile(folder: tempPath, seriesCount: count32, imageNumber: imageNo, pathExtension: pathExtension,
                                                                    addDICOMDIR: addDICOMDIR),
                                    newName: ExportNaming.imageFile(folder: tempPath, seriesCount: count32, imageNumber: imageNo, pathExtension: pathExtension,
                                                                    addDICOMDIR: addDICOMDIR, attempt: 1)))
                }

                if compresses && (image.fileType()?.hasPrefix("DICOM") ?? false) {
                    filesToCompress.append(dest)
                }

                if pathExtension == "hdr" { // ANALYZE -> COPY IMG
                    try? files.copyItem(atPath: ((source as NSString).deletingPathExtension as NSString).appendingPathExtension("img")!,
                                        toPath: ((dest as NSString).deletingPathExtension as NSString).appendingPathExtension("img")!)
                }

                if let splash { MainActor.assumeIsolated { splash.step() } }
                Thread.current.progress = CGFloat(Float(i) / Float(paths.count))
                Thread.current.status = BrowserObjC.singularPlural(paths.count - i, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))

                let aborted = splash.map { splash in MainActor.assumeIsolated { splash.aborted } } ?? false
                if aborted || Thread.current.isCancelled {
                    i = paths.count
                    exportAborted = true
                }
            }
        }) {
            BrowserObjC.log(exception, stack: true, "-[BrowserController exportDICOMFileInt:]")
            exportAborted = true
            exportError = Self.incompleteExportError(reason: exception.reason)
        }
        DicomStudy.dbModifyLock()?.unlock()

        var renamedSources = Set<String>()
        for rename in renames {
            if renamedSources.contains(rename.oldName) { continue }
            do {
                try files.moveItem(atPath: rename.oldName, toPath: rename.newName)
            } catch let failure {
                if exportError == nil { exportError = failure as NSError }
                exportAborted = true
                break
            }
            renamedSources.insert(rename.oldName)
            if exportedPaths.remove(rename.oldName) != nil {
                exportedPaths.insert(rename.newName)
            }
            for index in filesToCompress.indices where BrowserObjC.literallyEqual(filesToCompress[index], rename.oldName) {
                filesToCompress[index] = rename.newName
            }
        }

        // Close the progress window.
        if let splash { MainActor.assumeIsolated { splash.close() } }

        if let exportError {
            outcome.result.error = exportError
            if !request.quietErrors {
                Self.presentError(exportError)
            }
        }

        #if !OSIRIX_LIGHT
        if !filesToCompress.isEmpty && !exportAborted && compresses {
            do {
                try BrowserController.horos_processFiles(atPaths: filesToCompress, in: database,
                                                         mode: Int32(request.compressionTag == 1 ? Compress : Decompress))
            } catch let failure {
                exportAborted = true
                Self.presentError(objcReportedError(failure) ?? Self.incompleteExportError(reason: nil))
            }
        }

        // A DICOMDIR per patient folder, so that dcmkdir scans the exported
        // folders only, not the rest of the destination.
        if addDICOMDIR && !exportAborted {
            for tempPath in patientFolders {
                Thread.current.status = NSLocalizedString("Writing DICOMDIR...", comment: "")
                do {
                    try BrowserController.horos_createDicomDir(atDir: tempPath)
                } catch let failure {
                    exportAborted = true
                    Self.presentError(objcReportedError(failure) ?? Self.incompleteExportError(reason: nil))
                    break
                }
            }
        }
        #endif
        let exportedCount = exportedPaths.filter { files.fileExists(atPath: $0) }.count

        // One archive for the whole export: studies of one person that differ
        // in patient ID or birth date get folders of their own, and a CT and
        // an echo exported together are still one file to send.
        if encryptExport && !exportAborted && !patientFolders.isEmpty {
            do {
                try Self.archive(patientFolders, to: folderClaims.archivePath(forFolders: patientFolders), password: request.password,
                                 deletingSources: true, showGUI: !request.quietErrors, archiver: archiver)
            } catch let failure {
                exportAborted = true
                outcome.result.error = failure as NSError
                if !request.quietErrors {
                    Self.presentError(failure as NSError)
                }
            }
        }
        if !exportAborted && !Thread.current.isCancelled && exportedCount > 0 && request.showCompletion {
            Self.presentCompletion(count: exportedCount, location: location)
        }
    }

    // MARK: Names

    /// The first identifier that is not empty, else the object's URI: what
    /// tells the patients, studies and series of one export apart.
    private static func identity(_ identifiers: String?..., of object: NSManagedObject?) -> String {
        if let identifier = identifiers.lazy.compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            return identifier
        }
        return object?.objectID.uriRepresentation().absoluteString ?? ""
    }

    /// The patient folder the export's folder naming options give the study.
    static func configuredPatientFolder(of study: DicomStudy?, naming: ExportFolderNaming) -> String {
        naming.patientFolder(name: study?.name, patientID: study?.patientID,
                             identity: identity(study?.patientUID, study?.studyInstanceUID, of: study))
    }

    // MARK: Archive

    /// The items, which share one folder, in one ZIP archive (ProtectedZipArchiver),
    /// with the progress window when asked on the main thread.
    static func archive(_ items: [String], to destination: String, password: String?, deletingSources: Bool, showGUI: Bool,
                        archiver: ProtectedZipArchiver = ProtectedZipArchiver()) throws {
        if !AppController.hasMacOSXSnowLeopard() && Thread.isMainThread && !(password ?? "").isEmpty {
            MainActor.assumeIsolated { zipEncryptionUnsupportedAlert() }
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: nil)
        }
        let progress: ArchiveProgress? = Thread.isMainThread && showGUI ? MainActor.assumeIsolated { ArchiveProgress() } : nil
        defer {
            if let progress { MainActor.assumeIsolated { progress.close() } }
        }
        Thread.current.status = NSLocalizedString("Compressing the files...", comment: "")
        try archiver.archive(items: items, to: destination, password: password, deletingSources: deletingSources)
    }

    /// The files at the archive's root, with the progress window on the main thread.
    static func archiveFlat(_ files: [String], to destination: String, password: String?) {
        if !AppController.hasMacOSXSnowLeopard() && Thread.isMainThread && !(password ?? "").isEmpty {
            MainActor.assumeIsolated { zipEncryptionUnsupportedAlert() }
            return
        }
        let progress: ArchiveProgress? = Thread.isMainThread ? MainActor.assumeIsolated { ArchiveProgress() } : nil
        ProtectedZipArchiver().archiveFlat(files: files, to: destination, password: password)
        if let progress { MainActor.assumeIsolated { progress.close() } }
    }

    /// Before MacOS 10.6 zip could not encrypt: the archive is not made.
    @MainActor private static func zipEncryptionUnsupportedAlert() {
        _ = HorosAlertPanel.runCritical(title: NSLocalizedString("ZIP Encryption", comment: ""),
                                        message: NSLocalizedString("ZIP encryption requires MacOS 10.6 or higher. The ZIP file will be generated, but NOT encrypted with a password.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    // MARK: Messages

    static func incompleteExportError(reason: String?) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("DICOM export could not be completed.", comment: ""),
                           NSLocalizedFailureReasonErrorKey: reason ?? ""])
    }

    /// A patient folder that was there before the export: replaced (emptied),
    /// merged, or the export is cancelled (false). Asked from the main run
    /// loop, which the export waits for.
    static func confirmExistingFolder(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let answer = onMainRunLoopSync {
            HorosAlertPanel.runInformational(title: NSLocalizedString("Export", comment: ""),
                                             message: String(format: NSLocalizedString("A folder already exists. Should I replace it? It will delete the entire content of this folder (%@), or merge the existing content with the new files?", comment: ""), name),
                                             defaultButton: NSLocalizedString("Replace", comment: ""),
                                             alternateButton: NSLocalizedString("Cancel", comment: ""),
                                             otherButton: NSLocalizedString("Merge", comment: ""))
        }
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

    /// The count of exported files and the destination, from the main run loop.
    static func presentCompletion(count: Int, location: String) {
        onMainRunLoopSync {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("DICOM export completed", comment: "")
            alert.informativeText = String(format: NSLocalizedString("Exported files: %@\nDestination: %@", comment: ""), String(describing: count), location)
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
        }
    }

    /// The error, with what to check: access to the sources, the destination
    /// folder, free space and cloud providers. From the main run loop.
    static func presentError(_ error: NSError) {
        onMainRunLoopSync {
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
    }

    @MainActor static func presentEmptySelection() {
        _ = HorosAlertPanel.runInformational(title: NSLocalizedString("DICOM Export", comment: ""),
                                             message: NSLocalizedString("No exportable files were found in the selection. Select a study, series, or image and check the export options before trying again.", comment: ""),
                                             defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    // MARK: File > Export > DICOM Files

    /// The export sheet (folder naming, DICOMDIR, compression, encryption) for
    /// the thumbnails' or the list's selection, then the export on a thread of
    /// the Activity window. The private SR series are left out unless "Add
    /// ROIs" is on.
    @MainActor static func chooseFolderAndExport(from browser: BrowserController, thumbnails: Bool) {
        let hasSelection = thumbnails ? (browser.horos_oMatrix?.selectedCells.count ?? 0) > 0 : (browser.horos_databaseOutline?.selectedRowIndexes.count ?? 0) > 0
        guard hasSelection else {
            presentEmptySelection()
            return
        }
        let preferences = PreferencesSource.process.preferences

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("Select the location where to export the DICOM files:", comment: "")
        panel.prompt = NSLocalizedString("Choose", comment: "")
        panel.title = NSLocalizedString("Export", comment: "")
        panel.canCreateDirectories = true
        let accessory = browser.horos_exportAccessoryView
        let legacyAccessoryFrame = accessory?.frame ?? .zero
        let folderOptionsView = accessory.map { ExportFolderOptions(legacyView: $0) }
        panel.accessoryView = folderOptionsView
        browser.passwordForExportEncryption = ""

        browser.horos_compressionMatrix?.selectCell(withTag: preferences[ApplicationPreferences.exportCompressionMode])

        let panelResult = panel.runModal()
        let folderOptions = panelResult == .OK ? folderOptionsView?.acceptedOptions() : nil
        accessory?.removeFromSuperview()
        accessory?.frame = legacyAccessoryFrame
        panel.accessoryView = accessory
        guard panelResult == .OK else { return }
        panel.makeFirstResponder(nil)

        let wait = WaitRendering(NSLocalizedString("Preparing the files...", comment: ""))
        wait?.showWindow(browser)
        var selection = SelectedFiles(of: browser, thumbnails: thumbnails, onlyImages: false)
        if !preferences[ApplicationPreferences.addROIsForExport] {
            var kept = selection.objects
            if let exception = HorosObjCException.caught({
                for predicate in ExportSeriesFilter.predicates() {
                    kept = kept.filter { predicate.evaluate(with: $0) }
                }
            }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController exportDICOMFile:]")
            }
            selection = SelectedFiles(paths: kept.map { ($0 as? DicomImage)?.completePath() ?? "" }, objects: kept)
        }
        wait?.close()

        guard !selection.paths.isEmpty, !selection.objects.isEmpty else {
            presentEmptySelection()
            return
        }

        let request = DICOMFolderExportRequest(location: panel.url?.path ?? "", files: selection.paths, objects: selection.objects.map(\.objectID),
                                               password: browser.passwordForExportEncryption ?? "",
                                               folderNaming: folderOptions?.compactMapValues { ($0 as? NSNumber)?.intValue },
                                               folderTreeTag: browser.horos_folderTree?.selectedTag() ?? 0,
                                               compressionTag: browser.horos_compressionMatrix?.selectedTag() ?? 0,
                                               showCompletion: true)
        let export = DICOMFolderExport(preferences: preferences)
        let count = selection.paths.count
        ActivityThread.startListed(name: NSLocalizedString("Exporting...", comment: ""), configure: { thread in
            thread.status = BrowserObjC.singularPlural(count, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))
        }) {
            _ = export.run(request, for: browser)
        }

        preferences.set(browser.horos_compressionMatrix?.selectedTag() ?? 0, for: ApplicationPreferences.exportCompressionMode)
    }
}

/// The error an Objective-C call reported; nil when it failed without one
/// (Swift then throws a placeholder).
func objcReportedError(_ error: Error) -> NSError? {
    let error = error as NSError
    return error.domain == "Foundation._GenericObjCError" ? nil : error
}

/// The files of a browser selection and the database objects they belong to, in step.
struct SelectedFiles {
    var paths: [String]
    var objects: [NSManagedObject]

    init(paths: [String], objects: [NSManagedObject]) {
        self.paths = paths
        self.objects = objects
    }

    /// The thumbnails' selection, or the list's.
    @MainActor init(of browser: BrowserController, thumbnails: Bool, onlyImages: Bool) {
        let objects = NSMutableArray()
        let paths = thumbnails ? browser.files(forDatabaseMatrixSelection: objects, onlyImages: onlyImages)
                               : browser.files(forDatabaseOutlineSelection: objects, onlyImages: onlyImages)
        self.init(paths: (paths as? [String]) ?? [], objects: objects.compactMap { $0 as? NSManagedObject })
    }

    /// Without the later occurrences of a path (compared as Foundation strings
    /// are), and their objects with them.
    func removingDuplicatePaths() -> SelectedFiles {
        var seen = Set<[UInt16]>()
        var kept = SelectedFiles(paths: [], objects: [])
        for (index, path) in paths.enumerated() where seen.insert(Array(path.utf16)).inserted {
            kept.paths.append(path)
            if index < objects.count { kept.objects.append(objects[index]) }
        }
        // Objects without a path stay, as the arrays kept them.
        if objects.count > paths.count { kept.objects.append(contentsOf: objects[paths.count...]) }
        return kept
    }
}

/// The progress window of an export run on the main thread.
@MainActor private final class ExportSplash {
    private let wait: Wait?

    init(count: Int) {
        wait = Wait(string: NSLocalizedString("Exporting...", comment: ""), true)
        wait?.setCancel(true)
        wait?.showWindow(nil)
        wait?.progress()?.maxValue = Double(count)
    }

    func step() { wait?.increment(by: 1) }
    var aborted: Bool { wait?.aborted() ?? false }
    func close() { wait?.close() }
}

/// The window of an archive made on the main thread.
@MainActor private final class ArchiveProgress {
    private let wait: WaitRendering?

    init() {
        wait = WaitRendering(NSLocalizedString("Compressing the files...", comment: ""))
        wait?.showWindow(nil)
    }

    func close() { wait?.close() }
}
