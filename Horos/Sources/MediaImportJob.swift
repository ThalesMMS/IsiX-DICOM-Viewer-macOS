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


import AppKit
import IsiXDatabase
import IsiXPreferences
import Synchronization

// The files of a folder or a medium copied into the database folder (or read
// where they are) and indexed. The copying runs on the calling thread, five
// seconds of it at a time; each batch goes to a lane of its own and is indexed
// through the single entry, on a private-queue context, while the next one is
// copied. Cancelling stops the copying; what is already copied is indexed. An
// import that took less than it was given says so in the log, and in an alert
// when a file failed.

/// How an import ended.
struct MediaImportOutcome: Sendable {
    /// The calling thread was cancelled: not everything it was given was taken.
    let stopped: Bool
}

/// What the import read of the browser before it began, so that a choice the
/// user makes during a long import does not move the files of the one under way.
private struct MediaImportDestination: Sendable {
    /// The browser, to select the first study; nil when none is to be selected.
    var browser: BrowserController?
    /// The album the browser shows, when it shows the database of the import.
    var album: NSManagedObjectID?
}

/// The destination, read on the main thread as soon as the import starts. The
/// import does not wait for it: its caller may hold anything, a context's queue
/// included. The first batch does, on a thread that holds nothing, and not for
/// long: the main thread may be waiting for the import, or be quitting, and the
/// files then go in with no album and no selection.
private final class MediaImportDestinationReading: @unchecked Sendable {
    private let read = DispatchSemaphore(value: 0)
    /// Written before `read` is signalled, and read after it.
    private var destination = MediaImportDestination()
    /// The batches run one at a time, so that they share this without a lock.
    private var patience: TimeInterval = 5

    /// `needed` false asks nothing of the main thread: the destination is empty.
    init(needed: Bool, _ reading: @escaping @MainActor @Sendable () -> MediaImportDestination) {
        let finish: @MainActor @Sendable () -> Void = { [self] in
            destination = reading()
            read.signal()
        }
        if !needed {
            read.signal()
        } else if Thread.isMainThread {
            MainActor.assumeIsolated(finish)
        } else {
            onMainRunLoop(finish)
        }
    }

    /// Waits for the reading, which may have ended long ago. Never on the main thread.
    func value() -> MediaImportDestination {
        if read.wait(timeout: .now() + patience) == .timedOut {
            patience = 0
            NSLog("(copyFilesThread): the main thread did not say what the browser shows; importing with no album or selection")
            return MediaImportDestination()
        }
        read.signal()
        return destination
    }
}

/// One batch of copied files.
private struct MediaImportBatch: Sendable {
    let files: [String]
    /// The file each copy came from: copies have a name of the database's own.
    let sources: [String: String]
}

/// What the copying thread and the indexing share.
private final class MediaImportTally: Sendable {
    struct Counts {
        var copied = 0
        var indexed = 0
        /// The files the validation before importing refused, as the user gave them.
        var refusedSources: [String] = []
        var studySelected = false
    }

    let counts = Mutex(Counts())
}

/// Indexes the batches of an import. Runs on threads of the Activity list, one
/// at a time, none of them the import's: cancelling the copy leaves them alone.
///
/// `@unchecked Sendable`: `DicomDatabase` is not Sendable, and a conformance
/// would have to be in the file of the class. The reference never changes, and
/// its contexts are entered on their own queues.
private struct MediaImportIndexer: @unchecked Sendable {
    let database: DicomDatabase
    let request: MediaImportRequest
    let ingest: DatabaseIngest
    let tally: MediaImportTally
    let destination: MediaImportDestinationReading

    /// The import waits for its batches, so each is part of it for the gate: a
    /// batch of files already copied is not refused because quitting has begun.
    func index(_ batch: MediaImportBatch) {
        ingest.asPartOfAdmittedImport {
            if let exception = HorosObjCException.caught({ indexRaising(batch) }) {
                DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase copyFilesThread:]_block_invoke")
            }
        }
    }

    private func indexRaising(_ batch: MediaImportBatch) {
        let thread = Thread.current

        // The files the validation refuses are left out, and only
        // those: the rest of the batch is indexed.
        var acceptedFiles = batch.files

        #if !OSIRIX_LIGHT
        thread.status = NSLocalizedString("Validating the files...", comment: "")
        if MediaScanRules.validatesBeforeIndexing(preference: ingest.processGraph.preferences[DatabasePreferences.validateFilesBeforeImporting],
                                                  mountedVolume: request.mountedVolume) { // mountedVolume : it's too slow to test the files now from a CD
            let refused = (DicomDatabase.filesRefused(byValidation: batch.files) ?? []).compactMap { $0 as? String }
            if !refused.isEmpty {
                let refusedSet = NSSet(array: refused)
                acceptedFiles = batch.files.filter { !refusedSet.contains($0) }

                tally.counts.withLock { counts in
                    counts.refusedSources += refused.map { batch.sources[$0] ?? $0 }
                }

                if request.copyFiles {
                    for f in refused {
                        try? FileManager.default.removeItem(atPath: f)
                    }
                }
            }
        }
        #endif

        guard !acceptedFiles.isEmpty else { return }

        thread.status = NSLocalizedString("Indexing the files...", comment: "")

        // Before the indexing, which can raise: they are in the database folder.
        tally.counts.withLock { $0.copied += acceptedFiles.count }

        let shown = destination.value()
        let indexed = ingest.indexOnOwnContext(acceptedFiles, preset: request.preset, of: database) { worker, objectIDs in
            if let album = shown.album {
                add(objectIDs, toAlbum: album, in: worker)
            }
        } ?? []

        let selecting = tally.counts.withLock { counts in
            counts.indexed += indexed.count
            let first = !indexed.isEmpty && !counts.studySelected
            if first { counts.studySelected = true }
            return first
        }

        if selecting, let browser = shown.browser, let image = indexed.first as? NSManagedObjectID {
            onMainRunLoop { browser.selectStudy(withObjectID: image) }
        }
    }

    /// Adds the studies of the images to the album, on the queue of `worker`.
    private func add(_ objectIDs: [Any]?, toAlbum albumID: NSManagedObjectID, in worker: DicomDatabase) {
        let album = worker.object(withID: albumID) as? NSManagedObject
        let studies = album?.mutableSetValue(forKey: "studies")

        var change = false
        for case let mobject as NSManagedObject in worker.objects(withIDs: objectIDs) ?? [] {
            if let s = mobject.value(forKeyPath: "series.study"), studies?.contains(s) == false {
                change = true
                studies?.add(s)
            }
        }

        if change {
            _ = worker.save()
        }
    }
}

/// One import of files. Run on a thread of its own, or on that of a scan; the
/// thread's name, status, progress and cancellation are the import's.
///
/// `@unchecked Sendable`, as `MediaImportIndexer`: only the reference to the
/// database goes to the thread that runs it.
struct MediaImportJob: @unchecked Sendable {
    let database: DicomDatabase
    let request: MediaImportRequest
    let ingest: DatabaseIngest

    /// Quitting refuses it or cancels it, and waits for its batches too.
    @discardableResult
    func run() -> MediaImportOutcome {
        ingest.whileAdmitted { importing() } ?? MediaImportOutcome(stopped: true)
    }

    private func importing() -> MediaImportOutcome {
        autoreleasepool {
            // What was taken and what became a row. A medium pulled out mid-import
            // leaves the files it managed to copy in the database folder; whether any
            // of them were indexed was not written down anywhere, so the two counts
            // are kept and reported together at the end.
            let tally = MediaImportTally()
            let indexer = MediaImportIndexer(database: database, request: request, ingest: ingest, tally: tally,
                                             destination: destinationReading())
            let lane = IngestBatchLane<MediaImportBatch> { batch in
                await ActivityThread.runWithoutCancel(name: NSLocalizedString("Adding files...", comment: "")) {
                    indexer.index(batch)
                }
            }

            let copyFiles = request.copyFiles
            let mountedVolume = request.mountedVolume
            var failedCopies = 0
            var firstFailure: String?
            var deliveredBatches = 0
            let filesInput = request.orderedFiles // sorting the array should make the data access faster on optical media
            // The headers being imported, to know which .img files come with one.
            var inputHeaders = Set<String>()
            for path in filesInput where ((path as NSString).pathExtension as NSString).lowercased == "hdr" {
                inputHeaders.insert((path as NSString).lowercased)
            }

            var i = 0
            while i < filesInput.count {
                if Thread.current.isCancelled { break }

                let stop: Bool = autoreleasepool {
                    var cancelled = false
                    if let exception = HorosObjCException.caught({
                        var copiedFiles: [String] = []
                        var sourceOfCopy: [String: String] = [:]
                        var lastGUIUpdate: TimeInterval = 0
                        let twentySeconds = Date.timeIntervalSinceReferenceDate + 5 // actually fiveSeconds

                        while i < filesInput.count && twentySeconds > Date.timeIntervalSinceReferenceDate {
                            if Thread.current.isCancelled { break }

                            if Date.timeIntervalSinceReferenceDate - lastGUIUpdate > 1 {
                                lastGUIUpdate = Date.timeIntervalSinceReferenceDate

                                Thread.current.status = DicomDatabaseObjC.localizedCount(filesInput.count - i, NSLocalizedString("file left", comment: ""), NSLocalizedString("files left", comment: ""))
                                Thread.current.progress = CGFloat(Float(i) / Float(filesInput.count))
                            }

                            let srcPath = filesInput[i]

                            if copyFiles {
                                // An image whose header is imported too is copied with it, under
                                // the header's new name: copied on its own, under a number of its
                                // own, neither file could be read.
                                if let imageHeader = HeaderImagePair.headerPath(forImage: srcPath), inputHeaders.contains((imageHeader as NSString).lowercased) {
                                    i += 1
                                    continue
                                }

                                let fileExtension = DataFileExtension.forImportedFile(pathExtension: (srcPath as NSString).pathExtension, isDICOM: false)

                                var dstPath = database.uniquePathForNewDataFile(withExtension: fileExtension)

                                if let exception = HorosObjCException.caught({
                                    HorosObjCException.synchronized(BrowserController.horos_oneCopyAtATimeLock()) {
                                        var copyError: NSError? = nil
                                        let copySucceeded = DicomDatabaseCopyFileForPublication(srcPath, dstPath ?? "", mountedVolume, &copyError)
                                        if !copySucceeded {
                                            failedCopies += 1
                                            if firstFailure == nil {
                                                firstFailure = copyError?.localizedDescription ?? NSLocalizedString("The file could not be copied.", comment: "")
                                            }
                                        }
                                        let pairedImage = copySucceeded ? HeaderImagePair.imagePath(forHeader: srcPath) : nil
                                        if let pairedImage, DicomDatabaseCopyFileForPublication(pairedImage, HeaderImagePair.imagePath(besideStoredHeader: dstPath ?? ""),
                                                                                                mountedVolume, &copyError) == false {
                                            failedCopies += 1
                                            if firstFailure == nil {
                                                firstFailure = copyError?.localizedDescription ?? NSLocalizedString("The file could not be copied.", comment: "")
                                            }
                                        }
                                        if copySucceeded, var copied = dstPath {
                                            if fileExtension != "dcm" {
                                                if DicomFile.isDICOMFile(copied) {
                                                    let newPathExtension = ((copied as NSString).deletingPathExtension as NSString).appendingPathExtension("dcm")
                                                    if let newPathExtension, (try? FileManager.default.moveItem(atPath: copied, toPath: newPathExtension)) != nil {
                                                        copied = newPathExtension
                                                    }
                                                }
                                            }
                                            dstPath = copied

                                            copiedFiles.append(copied)
                                            sourceOfCopy[copied] = srcPath
                                        }
                                    }
                                }) {
                                    DicomDatabaseObjC.log(exception, stack: false, "-[DicomDatabase copyFilesThread:]")
                                }
                            } else {
                                if FileManager.default.fileExists(atPath: srcPath) {
                                    if mountedVolume {
                                        if let exception = HorosObjCException.caught({
                                            if DicomFile(srcPath) != nil { // Pre-load for CD/DVD in cache
                                                copiedFiles.append(srcPath)
                                            } else {
                                                NSLog("**** DicomFile *curFile = nil")
                                            }
                                        }) {
                                            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase copyFilesThread:]")
                                        }
                                    } else {
                                        if ingest.processGraph.preferences[DatabasePreferences.validateFilesBeforeImporting] { // mountedVolume : it's too slow to test the files now from a CD
                                            // Pre-load for faster validating
                                            _ = NSData(contentsOfFile: srcPath)
                                        }
                                        copiedFiles.append(srcPath)
                                    }
                                }
                            }

                            if Thread.current.isCancelled {
                                break
                            }
                            i += 1
                        }

                        if !copiedFiles.isEmpty {
                            deliveredBatches += 1
                            lane.deliver(MediaImportBatch(files: copiedFiles, sources: sourceOfCopy))
                        }

                        if Thread.current.isCancelled {
                            cancelled = true
                        }
                    }) {
                        DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase copyFilesThread:]")
                    }
                    return cancelled
                }
                if stop { break }
            }

            // The lane indexes files that are already in the database folder; it does
            // not touch the medium. Cancelling it threw that away: pulling a disc
            // out cancels the scan thread, which cancels this one, and the batch
            // holding the files copied so far was cancelled before it could run.
            // Measured on a disc of 1200 instances pulled out one second in: 373 files
            // copied, 0 indexed, and 373 files left in the database folder that no row
            // pointed at. Cancelling stops the copying; what is already copied is
            // indexed, so a cut-short import is a smaller import and not a hidden one.
            if deliveredBatches != 0 {
                Thread.current.status = NSLocalizedString("Waiting for subtasks to complete...", comment: "")
            }
            lane.finishAndWait()
            let counts = tally.counts.withLock { $0 }

            // An import that took less than it was given says so, whether the shortfall
            // was in the copying or in the indexing, or it was stopped. Both counts
            // matter: files copied into the database folder and never indexed are
            // invisible to the browser and to every clean-up that works from the database.
            if Thread.current.isCancelled || ImportShortfall.copyIsIncomplete(failedCopies: failedCopies, copied: counts.copied, indexed: counts.indexed) {
                NSLog("%@", ImportShortfall.copyLogLine(offered: filesInput.count, copied: counts.copied, indexed: counts.indexed,
                                                        failedCopies: failedCopies, firstFailure: firstFailure))
            }

            // Refused by the validation before importing: how many, why, and the
            // first of them, so that the user knows which files are missing.
            let refusedSources = counts.refusedSources
            if !refusedSources.isEmpty {
                NSLog("(copyFilesThread): %lu file(s) refused by the validation before importing: %@", UInt(refusedSources.count), refusedSources)
            }

            if let message = ImportShortfall.alertMessage(
                failedCopies: failedCopies, firstFailure: firstFailure, refusedFiles: refusedSources,
                copyFailed: NSLocalizedString("%lu file(s) could not be copied and were not indexed. Source files were preserved.\n\n%@\n\nFor OneDrive or another cloud provider, make the files available offline and retry. Also check access permissions and free disk space.", comment: ""),
                oneRefused: NSLocalizedString("1 file was not imported: the validation before importing found it damaged or unreadable.", comment: ""),
                manyRefused: NSLocalizedString("%lu files were not imported: the validation before importing found them damaged or unreadable.", comment: "")) {
                ImportFeedback(processGraph: ingest.processGraph).alertIncompleteImport(message)
            }

            if MediaScanRules.ejectsAfterImport(asked: request.ejectCDDVD, copied: copyFiles, failedCopies: failedCopies,
                                                ejectPreference: ingest.processGraph.preferences[DatabasePreferences.ejectsMedia]),
               let first = filesInput.first {
                _ = NSWorkspace.shared.unmountAndEjectDevice(atPath: first)
            }

            return MediaImportOutcome(stopped: Thread.current.isCancelled)
        }
    }

    /// Reads what the import needs of the browser.
    private func destinationReading() -> MediaImportDestinationReading {
        let job = self
        return MediaImportDestinationReading(needed: request.usesBrowser) {
            let browser = job.ingest.browser
            let main = job.database.isMainDatabase() ? job.database : job.database.mainDatabase as? DicomDatabase
            let showsIt = job.request.addToAlbum && browser?.database === main
            return MediaImportDestination(browser: job.request.selectStudy ? browser : nil,
                                          album: showsIt ? browser?.currentAlbumID(main) : nil)
        }
    }
}

/// The dictionary of -copyFilesThread: is the part plugins know.
@objc(MediaCopy) @implementation extension DicomDatabase {

    func copyFilesThread(_ dict: [AnyHashable: Any]!) {
        MediaImportJob(database: self, request: MediaImportRequest(options: dict ?? [:]), ingest: DatabaseIngest.process).run()
    }
}
