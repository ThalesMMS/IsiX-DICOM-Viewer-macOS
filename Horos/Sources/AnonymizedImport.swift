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

/// What the anonymization sheet hands back to its end: the selection's DICOM
/// files and their images, in step.
struct AnonymizationSelection {
    let paths: [String]
    let images: [DicomImage]
}

/// The anonymization of the browser's selection: the sheet, the anonymized
/// files saved to a folder, or imported into the database through the single
/// ingest entry next to the originals or in their place, in one batch that is
/// undone as a whole.
@MainActor struct AnonymizedImport {
    let database: DicomDatabase?

    /// A refusal of the batch before anything is kept, with its reason.
    private struct Refusal: Error {
        let reason: String
    }

    /// What the batch records as it goes: an object, not values passed inout,
    /// because the indexer may raise an Objective-C exception through the
    /// batch, and an unwound inout access would be left open.
    private final class Ledger {
        var fileFailures: [String: [String]] = [:]
        var retired = Set<DicomImage>()
    }

    // MARK: The sheet

    /// The selection's DICOM files, to the anonymization sheet, whose end goes
    /// to `delegate`'s `didEnd`.
    static func showSheet(for browser: BrowserController, thumbnails: Bool, didEnd: Selector) {
        let selection = SelectedFiles(of: browser, thumbnails: thumbnails, onlyImages: true).removingDuplicatePaths()
        var paths: [String] = [], images: [DicomImage] = []
        for (path, object) in zip(selection.paths, selection.objects) {
            guard let image = object as? DicomImage, BrowserObjC.literallyEqual(image.fileType(), "DICOM") else { continue }
            paths.append(path)
            images.append(image)
        }

        if images.isEmpty {
            _ = HorosAlertPanel.run(title: NSLocalizedString("Anonymize Error", comment: ""), message: NSLocalizedString("No DICOM files in this selection.", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
        } else {
            _ = Anonymization.showSavePanel(forDefaultsKey: "AnonymizationFields", modalFor: browser.window, modalDelegate: browser,
                                        didEnd: didEnd, representedObject: AnonymizationSelection(paths: paths, images: images))
        }
    }

    /// The sheet's end: "Save As" writes the anonymized files to the chosen
    /// folder; "Add" and "Replace" anonymize into a private staging folder,
    /// import from there, and the browser refreshes after a committed import.
    func finish(_ panel: AnonymizationSavePanelController, refresh: () -> Void) {
        guard let selection = panel.representedObject as? AnonymizationSelection else { return }
        let paths = selection.paths as NSArray, images = selection.images as NSArray
        let tags = panel.anonymizationViewController.tagsValues() as NSArray?

        switch panel.end {
        case Int32(AnonymizationSavePanelSaveAs.rawValue):
            var anonymizationError: NSError?
            let outputs = Anonymization.anonymizeFiles(paths, dicomImages: images, toPath: panel.outputDir, withTags: tags, error: &anonymizationError)
            if !HorosAnonymizationOutputsComplete(selection.paths, outputs as? [AnyHashable: Any]) && !Self.isUserCancel(anonymizationError) {
                AnonymizationErrorPresenter.present(error: anonymizationError)
            }

        case Int32(AnonymizationSavePanelAdd.rawValue), Int32(AnonymizationSavePanelReplace.rawValue):
            var temporaryError: NSError?
            guard let tempDir = HorosCreateAnonymizationStagingDirectory(NSTemporaryDirectory(), &temporaryError) else {
                _ = HorosAlertPanel.run(title: NSLocalizedString("Anonymize Error", comment: ""), message: temporaryError?.localizedDescription ?? "",
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                break
            }
            defer { try? FileManager.default.removeItem(atPath: tempDir) }
            var anonymizationError: NSError?
            let anonymized = Anonymization.anonymizeFiles(paths, dicomImages: images, toPath: tempDir, withTags: tags, error: &anonymizationError)
            let outputs = anonymized as? [String: String] ?? [:]
            if !HorosAnonymizationOutputsComplete(selection.paths, outputs) {
                if !Self.isUserCancel(anonymizationError) {
                    AnonymizationErrorPresenter.present(error: anonymizationError)
                }
                break
            }
            do {
                try importFiles(outputs, originals: selection.images, replace: panel.end == Int32(AnonymizationSavePanelReplace.rawValue))
                refresh()
            } catch let failure {
                if !Self.isUserCancel(failure as NSError) {
                    AnonymizationErrorPresenter.present(error: failure as NSError)
                }
            }

        default:
            break
        }
    }

    private static func isUserCancel(_ error: NSError?) -> Bool {
        error?.domain == NSCocoaErrorDomain && error?.code == NSUserCancelledError
    }

    // MARK: The import

    /// Imports the anonymized files (original path -> anonymized copy) into
    /// the database, and with `replace` removes the originals' images (and
    /// series and studies left empty); the viewers that showed a removed
    /// image close. All or nothing: on any failure, or when the user cancels,
    /// nothing is imported, the copies are removed, and the error lists each
    /// file's outcome.
    func importFiles(_ files: [String: String], originals: [DicomImage], replace: Bool) throws {
        let retired = try importBatch(files, originals: originals, replace: replace)
        for case let viewer as ViewerController in ViewerController.getDisplayed2DViewers() ?? [] {
            for case let image as DicomImage in viewer.fileList() ?? [] where retired.contains(image) {
                viewer.window?.close()
                break
            }
        }
    }

    /// The batch of the import; the images it retired.
    private func importBatch(_ files: [String: String], originals: [DicomImage], replace: Bool) throws -> Set<DicomImage> {
        let sources = Array(files.keys)
        let target = database
        let context = target?.managedObjectContext as? N2ManagedObjectContext
        var originalForCopy: [String: String] = [:]
        let ledger = Ledger()
        var copiedPaths: [String] = []
        var captured = Set<DicomImage>()
        var expectedCounts: [String: UInt] = [:]
        var committed = false
        var progress: Wait?
        var failure: NSError?

        /// Throws the user's cancel once the progress window was cancelled.
        func throwIfCancelled() throws {
            if progress?.pollCancellation() ?? false {
                throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
            }
        }

        func importAll() throws {
            guard let target, let context, !target.isReadOnly, HorosAnonymizationOutputsComplete(sources, files) else {
                throw Refusal(reason: "The destination is read-only or the output files are incomplete.")
            }
            let sourcePaths = Set(sources)
            var sourceSeries = Set<DicomSeries>()
            for image in originals {
                if image.managedObjectContext !== context || image.isDeleted || !sourcePaths.contains(image.completePath() ?? "")
                    || (replace && (image.series?.study?.lockedStudy?.boolValue ?? false)) {
                    throw Refusal(reason: "The original images or active database changed, or a study is locked.")
                }
                if let series = image.series { sourceSeries.insert(series) }
            }
            // Visit each series once, including all indexed frames of selected files.
            for series in sourceSeries {
                for case let frame as DicomImage in series.images ?? [] where sourcePaths.contains(frame.completePath() ?? "") {
                    captured.insert(frame)
                }
            }
            if replace && captured.isEmpty {
                throw Refusal(reason: "No original images remain to replace.")
            }
            // Preserve unrelated pending edits before entering the clean-context batch.
            guard target.save(&failure) else { return }
            progress = Wait(string: NSLocalizedString("Importing anonymized images...", comment: ""))
            progress?.progress()?.maxValue = Double(files.count * 2)
            progress?.setCancel(true)
            progress?.showWindow(nil)
            for (original, source) in files {
                try throwIfCancelled()
                let destination = target.uniquePathForNewDataFile(withExtension: "dcm") ?? ""
                do {
                    try FileManager.default.copyItem(atPath: source, toPath: destination)
                } catch let copyError {
                    failure = copyError as NSError
                    ledger.fileFailures[original] = [NSLocalizedString("The anonymized file could not be copied into the database.", comment: "")]
                    return
                }
                copiedPaths.append(destination)
                originalForCopy[destination] = original
                let elements = DicomFile(destination, dicomOnly: true)?.dicomElements()
                let frames = max(1, (elements?["numberOfFrames"] as? NSNumber)?.intValue ?? 0)
                let seriesCount = (elements?["numberOfSeries"] as? NSNumber)?.uintValue ?? 0
                if elements == nil || seriesCount == 0 || UInt(frames) > UInt.max / seriesCount {
                    ledger.fileFailures[original] = [NSLocalizedString("The anonymized file could not be parsed completely for import.", comment: "")]
                    throw Refusal(reason: "An anonymized file could not be parsed completely.")
                }
                expectedCounts[destination] = UInt(frames) * seriesCount
                progress?.increment(by: 1)
            }
            let batch = (copiedPaths: copiedPaths, expectedCounts: expectedCounts, originalForCopy: originalForCopy, captured: captured, progress: progress)
            do {
                try context.performAtomicChanges { pointer in
                    MainActor.assumeIsolated {
                        do {
                            try self.indexCopies(batch.copiedPaths, into: target, context: context, expectedCounts: batch.expectedCounts,
                                                 originalForCopy: batch.originalForCopy, ledger: ledger, captured: batch.captured, replace: replace,
                                                 progress: batch.progress, throwIfCancelled: throwIfCancelled)
                            return true
                        } catch is BatchRefused {
                            // A batch the index or the counts refused fails without an error.
                            return false
                        } catch {
                            pointer?.pointee = error as NSError
                            return false
                        }
                    }
                }
                committed = true
            } catch let batchError {
                // A batch that failed without an error is reported as the
                // import's own failure below.
                if let batchError = objcReportedError(batchError) { failure = batchError }
            }
        }

        // The database window's context, on the main thread.
        N2ManagedObjectContextPerformAndWait(context) {
            MainActor.assumeIsolated {
                var refusal: String?
                if let exception = HorosObjCException.caught({
                    do {
                        try importAll()
                    } catch let error as Refusal {
                        refusal = error.reason
                    } catch let other {
                        failure = other as NSError
                    }
                }) {
                    refusal = exception.reason ?? "Anonymized images could not be imported."
                }
                if let refusal {
                    failure = NSError(domain: "HorosAnonymizationImport", code: 1, userInfo: [NSLocalizedDescriptionKey: refusal])
                }
                progress?.close()
                if !committed {
                    for path in copiedPaths {
                        try? FileManager.default.removeItem(atPath: path)
                    }
                }
            }
        }
        guard committed else {
            let base = failure ?? NSError(domain: "HorosAnonymizationImport", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The anonymized images could not be imported. The originals were preserved.", comment: "")])
            var info = base.userInfo
            let wasCancelled = base.domain == NSCocoaErrorDomain && base.code == NSUserCancelledError
            info["HorosAnonymizationFileResults"] = HorosAnonymizationFileResults(sources, ledger.fileFailures, wasCancelled)
            throw NSError(domain: base.domain, code: base.code, userInfo: info)
        }
        return ledger.retired
    }

    /// A batch the index or the count of its records refused, which says no
    /// more than that: the import reports its own failure.
    private struct BatchRefused: Error {}

    /// The batch inside the atomic changes: index the copies by 32, check that
    /// each gave all its images, and retire the originals' images (and their
    /// emptied series and studies) on replace. Throws the cancel, the failed
    /// lookup or the incomplete index, and BatchRefused for the others.
    private func indexCopies(_ copiedPaths: [String], into target: DicomDatabase, context: N2ManagedObjectContext, expectedCounts: [String: UInt],
                             originalForCopy: [String: String], ledger: Ledger, captured: Set<DicomImage>, replace: Bool,
                             progress: Wait?, throwIfCancelled: @MainActor () throws -> Void) throws {
        var identifiers: [Any] = []
        for offset in stride(from: 0, to: copiedPaths.count, by: 32) {
            try throwIfCancelled()
            let chunk = Array(copiedPaths[offset..<min(offset + 32, copiedPaths.count)])
            guard let added = DatabaseIngest.process.index(chunk, preset: .anonymization, in: target) else { throw BatchRefused() }
            identifiers.append(contentsOf: added)
            progress?.increment(by: Double(chunk.count))
        }
        try throwIfCancelled()
        var imported = Set<DicomImage>()
        var counts: [String: UInt] = [:]
        for case let identifier as NSManagedObjectID in identifiers {
            guard let image = try context.existingObject(with: identifier) as? DicomImage, !image.isDeleted else { throw BatchRefused() }
            let path = image.completePath() ?? ""
            if expectedCounts[path] == nil { throw BatchRefused() }
            if imported.insert(image).inserted {
                counts[path, default: 0] += 1
            }
        }
        if counts != expectedCounts {
            for (path, expected) in expectedCounts {
                let actual = counts[path] ?? 0
                if actual != expected, let original = originalForCopy[path] {
                    ledger.fileFailures[original] = [String(format: NSLocalizedString("The importer retained %lu of %lu expected image records. The import batch was rolled back.", comment: ""), actual, expected)]
                }
            }
            throw NSError(domain: "HorosAnonymizationImport", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Not all anonymized files could be indexed. The import was rolled back and the original images were preserved.", comment: "")])
        }
        if replace {
            var series = Set<DicomSeries>(), studies = Set<DicomStudy>()
            for image in captured {
                if imported.contains(image) { continue } // unchanged SOP/frame reused in place
                if let item = image.series { series.insert(item) }
                if let item = image.series?.study { studies.insert(item) }
                ledger.retired.insert(image)
                context.delete(image)
            }
            context.processPendingChanges()
            for item in series {
                if Self.liveCount(item.images) == 0 {
                    context.delete(item)
                } else {
                    item.numberOfImages = NSNumber(value: 0)
                    item.thumbnail = nil
                }
            }
            context.processPendingChanges()
            for item in studies {
                if Self.liveCount(item.series) == 0 {
                    context.delete(item)
                } else {
                    item.numberOfImages = NSNumber(value: 0)
                }
            }
        }
    }

    /// The objects of a relationship that are not deleted.
    private static func liveCount<Objects: Sequence>(_ objects: Objects?) -> Int {
        guard let objects else { return 0 }
        return objects.reduce(0) { count, object in ((object as? NSManagedObject)?.isDeleted ?? true) ? count : count + 1 }
    }
}
