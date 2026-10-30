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

// Anonymizing the browser's selection: the anonymization sheet, saving the
// anonymized files to a folder, or importing them into the database next to
// the originals or in their place, in one batch that is undone as a whole.

extension BrowserController {

    #if !OSIRIX_LIGHT

    /// The selection's DICOM files, to the anonymization sheet.
    @objc(anonymizeDICOM:)
    func anonymizeDICOM(_ sender: Any!) {
        let dicomFiles2Anonymize = NSMutableArray()
        let filesToAnonymize: NSMutableArray?
        if isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix {
            filesToAnonymize = files(forDatabaseMatrixSelection: dicomFiles2Anonymize)
        } else {
            filesToAnonymize = files(forDatabaseOutlineSelection: dicomFiles2Anonymize)
        }
        filesToAnonymize?.removeDuplicatedStrings(inSyncWithThisArray: dicomFiles2Anonymize)

        var i = 0
        while i < dicomFiles2Anonymize.count {
            if !BrowserObjC.literallyEqual((dicomFiles2Anonymize[i] as AnyObject).value(forKey: "fileType") as? String, "DICOM") {
                dicomFiles2Anonymize.removeObject(at: i)
                filesToAnonymize?.removeObject(at: i)
            } else {
                i += 1
            }
        }

        if dicomFiles2Anonymize.count == 0 {
            _ = HorosAlertPanel.run(title: NSLocalizedString("Anonymize Error", comment: ""), message: NSLocalizedString("No DICOM files in this selection.", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
        } else {
            let representedObject: [Any] = [filesToAnonymize ?? NSMutableArray(), dicomFiles2Anonymize]
            Anonymization.showSavePanel(forDefaultsKey: "AnonymizationFields", modalFor: window, modalDelegate: self,
                                        didEnd: #selector(anonymizationSavePanelDidEnd(_:)), representedObject: representedObject)
        }
    }

    /// Imports the anonymized files (original path -> anonymized copy) into
    /// the database, and with `replace` removes the originals' images (and
    /// series and studies left empty). All or nothing: on any failure, or
    /// when the user cancels, nothing is imported and the copies are removed;
    /// the error lists each file's outcome.
    @objc(importAnonymizedFiles:originalImages:replace:error:)
    func importAnonymizedFiles(_ files: [AnyHashable: Any]!, originalImages: [Any]!, replace: Bool, error: NSErrorPointer) -> Bool {
        error?.pointee = nil
        let files = (files ?? [:]) as NSDictionary
        let target = self.database
        let originalForCopy = NSMutableDictionary()
        let fileFailures = NSMutableDictionary()
        let context = target?.managedObjectContext as? N2ManagedObjectContext
        let copiedPaths = NSMutableArray()
        let captured = NSMutableSet()
        let sourceSeries = NSMutableSet()
        let retired = NSMutableSet()
        let expectedCounts = NSMutableDictionary()
        var committed = false
        var progress: Wait?
        var failure: NSError?

        // The database window's context, on the main thread.
        N2ManagedObjectContextPerformAndWait(context) { MainActor.assumeIsolated {
            @MainActor func importAll() {
                guard let target, let context else {
                    NSException(name: NSExceptionName("AnonymizationImport"), reason: "The destination is read-only or the output files are incomplete.", userInfo: nil).raise()
                    return
                }
                if target.isReadOnly || !HorosAnonymizationOutputsComplete(files.allKeys, files as? [AnyHashable: Any]) {
                    NSException(name: NSExceptionName("AnonymizationImport"), reason: "The destination is read-only or the output files are incomplete.", userInfo: nil).raise()
                }
                let sourcePaths = NSSet(array: files.allKeys)
                for case let image as DicomImage in originalImages ?? [] {
                    if image.managedObjectContext !== context || image.isDeleted || !sourcePaths.contains(image.completePath() as Any)
                        || (replace && (image.series?.study?.lockedStudy?.boolValue ?? false)) {
                        NSException(name: NSExceptionName("AnonymizationImport"), reason: "The original images or active database changed, or a study is locked.", userInfo: nil).raise()
                    }
                    if let series = image.series { sourceSeries.add(series) }
                }
                // Visit each series once, including all indexed frames of selected files.
                for case let series as DicomSeries in sourceSeries {
                    for case let frame as DicomImage in (series.value(forKey: "images") as? NSSet) ?? [] where sourcePaths.contains(frame.completePath() as Any) {
                        captured.add(frame)
                    }
                }
                if replace && captured.count == 0 {
                    NSException(name: NSExceptionName("AnonymizationImport"), reason: "No original images remain to replace.", userInfo: nil).raise()
                }
                // Preserve unrelated pending edits before entering the clean-context batch.
                guard target.save(&failure) else { return }
                progress = Wait(string: NSLocalizedString("Importing anonymized images...", comment: ""))
                progress?.progress()?.maxValue = Double(files.count * 2)
                progress?.setCancel(true)
                progress?.showWindow(self)
                @MainActor func cancelled(_ pointer: NSErrorPointer) -> Bool {
                    guard progress?.pollCancellation() ?? false else { return false }
                    pointer?.pointee = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
                    return true
                }
                for case let original as String in files.allKeys {
                    let source = files[original] as? String
                    if cancelled(&failure) { return }
                    let destination = target.uniquePathForNewDataFile(withExtension: "dcm") ?? ""
                    do {
                        try FileManager.default.copyItem(atPath: source ?? "", toPath: destination)
                    } catch let copyError {
                        failure = copyError as NSError
                        fileFailures[original] = [NSLocalizedString("The anonymized file could not be copied into the database.", comment: "")]
                        return
                    }
                    copiedPaths.add(destination)
                    originalForCopy[destination] = original
                    let elements = DicomFile(destination, dicomOnly: true)?.dicomElements()
                    let frames = max(1, (elements?["numberOfFrames"] as? NSNumber)?.intValue ?? 0)
                    let seriesCount = (elements?["numberOfSeries"] as? NSNumber)?.uintValue ?? 0
                    if elements == nil || seriesCount == 0 || UInt(frames) > UInt.max / seriesCount {
                        fileFailures[original] = [NSLocalizedString("The anonymized file could not be parsed completely for import.", comment: "")]
                        NSException(name: NSExceptionName("AnonymizationImport"), reason: "An anonymized file could not be parsed completely.", userInfo: nil).raise()
                    }
                    expectedCounts[destination] = NSNumber(value: UInt(frames) * seriesCount)
                    progress?.increment(by: 1)
                }
                do {
                    try context.performAtomicChanges { pointer in
                        self.importCopies(copiedPaths, into: target, context: context, expectedCounts: expectedCounts, originalForCopy: originalForCopy,
                                          fileFailures: fileFailures, captured: captured, retired: retired, replace: replace, progress: progress,
                                          cancelled: cancelled, error: pointer)
                    }
                    committed = true
                } catch let batchError {
                    // A batch that failed without an error is reported as
                    // the import's own failure below.
                    if let batchError = BrowserController.reportedError(batchError) { failure = batchError }
                }
            }

            if let exception = BrowserObjC.attempt({ importAll() }) {
                failure = NSError(domain: "HorosAnonymizationImport", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: exception.reason ?? "Anonymized images could not be imported."])
            }
            progress?.close()
            if !committed {
                for case let path as String in copiedPaths {
                    try? FileManager.default.removeItem(atPath: path)
                }
                let base = failure ?? NSError(domain: "HorosAnonymizationImport", code: 1,
                                              userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The anonymized images could not be imported. The originals were preserved.", comment: "")])
                let info = NSMutableDictionary(dictionary: base.userInfo)
                let wasCancelled = base.domain == NSCocoaErrorDomain && base.code == NSUserCancelledError
                info["HorosAnonymizationFileResults"] = HorosAnonymizationFileResults(files.allKeys, fileFailures as? [AnyHashable: Any], wasCancelled)
                failure = NSError(domain: base.domain, code: base.code, userInfo: info as? [String: Any])
            }
        } }
        error?.pointee = failure

        if committed {
            for case let viewer as ViewerController in ViewerController.getDisplayed2DViewers() ?? [] {
                for case let image as DicomImage in viewer.fileList() ?? [] where retired.contains(image) {
                    viewer.window?.close()
                    break
                }
            }
            outlineViewRefresh()
            refreshAlbums()
        }
        return committed
    }

    /// The batch of -importAnonymizedFiles: inside the atomic changes: index
    /// the copies by 32, check that each gave all its images, and retire the
    /// originals' images (and their emptied series and studies) on replace.
    nonisolated private func importCopies(_ copiedPaths: NSArray, into target: DicomDatabase, context: N2ManagedObjectContext, expectedCounts: NSDictionary,
                              originalForCopy: NSDictionary, fileFailures: NSMutableDictionary, captured: NSSet, retired: NSMutableSet, replace: Bool,
                              progress: Wait?, cancelled: (NSErrorPointer) -> Bool, error failure: NSErrorPointer) -> Bool {
        let identifiers = NSMutableArray()
        var offset = 0
        while offset < copiedPaths.count {
            if cancelled(failure) { return false }
            let chunk = copiedPaths.subarray(with: NSRange(location: offset, length: min(32, copiedPaths.count - offset)))
            guard let added = target.addFiles(atPaths: chunk, postNotifications: true, dicomOnly: true, rereadExistingItems: true,
                                              generatedByOsiriX: true, importedFiles: false, returnArray: true) else { return false }
            identifiers.addObjects(from: added)
            let chunkCount = Double(chunk.count)
            if let progress { MainActor.assumeIsolated { progress.increment(by: chunkCount) } }
            offset += 32
        }
        if cancelled(failure) { return false }
        let imported = NSMutableSet()
        let counts = NSMutableDictionary()
        for case let identifier as NSManagedObjectID in identifiers {
            let image: DicomImage
            do {
                guard let existing = try context.existingObject(with: identifier) as? DicomImage, !existing.isDeleted else { return false }
                image = existing
            } catch let lookupError {
                failure?.pointee = lookupError as NSError
                return false
            }
            let path = image.completePath() ?? ""
            if expectedCounts[path] == nil { return false }
            if !imported.contains(image) {
                imported.add(image)
                counts[path] = NSNumber(value: ((counts[path] as? NSNumber)?.uintValue ?? 0) + 1)
            }
        }
        if !counts.isEqual(to: expectedCounts as! [AnyHashable: Any]) {
            for case let path as String in expectedCounts.allKeys {
                let actual = (counts[path] as? NSNumber)?.uintValue ?? 0
                let expected = (expectedCounts[path] as? NSNumber)?.uintValue ?? 0
                if actual != expected, let original = originalForCopy[path] {
                    fileFailures[original] = [String(format: NSLocalizedString("The importer retained %lu of %lu expected image records. The import batch was rolled back.", comment: ""), actual, expected)]
                }
            }
            failure?.pointee = NSError(domain: "HorosAnonymizationImport", code: 2,
                                       userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Not all anonymized files could be indexed. The import was rolled back and the original images were preserved.", comment: "")])
            return false
        }
        if replace {
            let series = NSMutableSet(), studies = NSMutableSet()
            for case let image as DicomImage in captured {
                if imported.contains(image) { continue } // unchanged SOP/frame reused in place
                if let item = image.series { series.add(item) }
                if let item = image.series?.study { studies.add(item) }
                retired.add(image)
                context.delete(image)
            }
            context.processPendingChanges()
            let notDeleted = NSPredicate(format: "isDeleted == NO")
            for case let item as DicomSeries in series {
                if ((item.value(forKey: "images") as? NSSet)?.filtered(using: notDeleted).count ?? 0) == 0 {
                    context.delete(item)
                } else {
                    item.setValue(NSNumber(value: 0), forKey: "numberOfImages")
                    item.setValue(nil, forKey: "thumbnail")
                }
            }
            context.processPendingChanges()
            for case let item as DicomStudy in studies {
                if ((item.value(forKey: "series") as? NSSet)?.filtered(using: notDeleted).count ?? 0) == 0 {
                    context.delete(item)
                } else {
                    item.setValue(NSNumber(value: 0), forKey: "numberOfImages")
                }
            }
        }
        return true
    }

    /// The anonymization sheet's end: "Save As" writes the anonymized files
    /// to the chosen folder; "Add" and "Replace" anonymize into a private
    /// staging folder and import from there.
    @objc(anonymizationSavePanelDidEnd:)
    func anonymizationSavePanelDidEnd(_ aspc: AnonymizationSavePanelController!) {
        let represented = aspc.representedObject as? NSArray
        let imagePaths = represented?[0] as? NSArray
        let imageObjs = represented?[1] as? NSArray

        switch aspc.end {
        case Int32(AnonymizationSavePanelSaveAs.rawValue):
            var anonymizationError: NSError?
            let outputs = Anonymization.anonymizeFiles(imagePaths, dicomImages: imageObjs, toPath: aspc.outputDir,
                                                       withTags: aspc.anonymizationViewController.tagsValues() as NSArray?, error: &anonymizationError)
            if !HorosAnonymizationOutputsComplete(imagePaths as? [Any], outputs as? [AnyHashable: Any]) && !BrowserController.isUserCancel(anonymizationError) {
                AnonymizationErrorPresenter.present(error: anonymizationError)
            }

        case Int32(AnonymizationSavePanelAdd.rawValue), Int32(AnonymizationSavePanelReplace.rawValue):
            var temporaryError: NSError?
            guard let tempDir = HorosCreateAnonymizationStagingDirectory(NSTemporaryDirectory(), &temporaryError) else {
                _ = HorosAlertPanel.run(title: NSLocalizedString("Anonymize Error", comment: ""), message: temporaryError?.localizedDescription ?? "",
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                break
            }
            var anonymizationError: NSError?
            let anonymizedFiles = Anonymization.anonymizeFiles(imagePaths, dicomImages: imageObjs, toPath: tempDir,
                                                               withTags: aspc.anonymizationViewController.tagsValues() as NSArray?, error: &anonymizationError)
            if !HorosAnonymizationOutputsComplete(imagePaths as? [Any], anonymizedFiles as? [AnyHashable: Any]) {
                if !BrowserController.isUserCancel(anonymizationError) {
                    AnonymizationErrorPresenter.present(error: anonymizationError)
                }
                try? FileManager.default.removeItem(atPath: tempDir)
                break
            }
            var importError: NSError?
            if !importAnonymizedFiles(anonymizedFiles as? [AnyHashable: Any], originalImages: imageObjs as? [Any],
                                      replace: aspc.end == Int32(AnonymizationSavePanelReplace.rawValue), error: &importError)
                && !BrowserController.isUserCancel(importError) {
                AnonymizationErrorPresenter.present(error: importError)
            }
            try? FileManager.default.removeItem(atPath: tempDir)

        default:
            break
        }
    }

    private static func isUserCancel(_ error: NSError?) -> Bool {
        error?.domain == NSCocoaErrorDomain && error?.code == NSUserCancelledError
    }

    #endif
}
