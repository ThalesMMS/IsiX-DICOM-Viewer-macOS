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
import IsiXContracts
import IsiXDICOMFile
import IsiXDatabase
import IsiXPreferences
import Synchronization

// Compressing and decompressing DICOM files, in the Decompress service: a chunk
// of files per helper, chunks on an operation queue under the lock the main
// database shares with its independent databases, and the worker that empties
// the queue of a database, which ConversionQueue keeps.
//
// A chunk ran as an NSInvocationOperation, unavailable in Swift: it runs as a
// block operation whose result, or the exception it raised, is read after the
// queue is done, where -[NSInvocationOperation result] answered or raised it.

/// What a chunk answered, or the exception it raised.
private final class ConversionChunkResult: @unchecked Sendable {
    var succeeded = false
    var exception: NSException?
}

/// `DatabaseFileConverting` over one database, nil for what asks nothing of a
/// database: a helper run needs only the files.
///
/// `DatabaseIngest.fileConversion(of:)` makes one for each use. `@unchecked
/// Sendable`: `DicomDatabase` is not Sendable, and a conformance would have to
/// be in the file of the class. The reference never changes, and the database
/// is used only as the thread that runs each method may.
struct DatabaseFileConversion: DatabaseFileConverting, @unchecked Sendable {
    private let database: DicomDatabase?
    private let ingest: DatabaseIngest
    private let queue: ConversionQueue
    private let preferences: UserDefaults
    private let defaultDatabase: @Sendable () -> DicomDatabase?

    init(database: DicomDatabase?, ingest: DatabaseIngest, queue: ConversionQueue, preferences: UserDefaults,
         defaultDatabase: @escaping @Sendable () -> DicomDatabase?) {
        self.database = database
        self.ingest = ingest
        self.queue = queue
        self.preferences = preferences
        self.defaultDatabase = defaultDatabase
    }

    /// Whether compressing an uncompressed file is worth it: an image, not an
    /// encapsulated document nor a structured report, of a modality and a size
    /// the preferences compress.
    static func isWorthCompressing(_ path: String?) -> Bool {
        guard let path, let facts = try? IsiXDCMTKTranscoding.compressionFacts(ofFileAtPath: path) else { return false }
        if facts.pixelDataCompressed { return false }
        let sopClassUID = facts.sopClassUID
        // Images only: not an encapsulated PDF or CDA, nor a structured report.
        guard DICOMSOPClass.isImageStorage(sopClassUID),
              !((sopClassUID as NSString?)?.isEqual(to: DICOMSOPClass.pdfStorageClassUID()) ?? false),
              !((sopClassUID as NSString?)?.isEqual(to: DICOMSOPClass.encapsulatedCDAStorage()) ?? false),
              !DICOMSOPClass.isStructuredReport(sopClassUID) else { return false }
        var resolution: Int32 = 0
        for side in [facts.rows, facts.columns] {
            guard let side = side?.int32Value else { continue }
            if resolution == 0 || resolution > side { resolution = side }
        }
        var quality: Int32 = 0
        let compression = BrowserController.compression(forModality: facts.modality, quality: &quality, resolution: resolution)
        return compression != Int32(compression_none)
    }

    /// Converts `paths` through the Decompress service, 200 files at a time,
    /// from the calling thread, whose progress it reports. False when a chunk
    /// times out, ends the service or fails.
    func convertNow(_ paths: [String], mode: FileConversionMode, into destination: String?) -> Bool {
        let thread = Thread.current
        thread.enterOperation()
        defer { thread.exitOperation() }
        let helperMode = mode == .compress ? "compress" : "decompressList"
        let environment = CompressionHelperRun.Environment(
            progress: { thread.progress = CGFloat($0) },
            now: { Date.timeIntervalSinceReferenceDate },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            logStackTrace: { N2LogStackTraceMessage($0) },
            logLaunchFailure: { error in
                NSLog("%@: %@", mode == .compress ? "+[DicomDatabase(DCMTK) compressDicomFilesAtPaths:intoDirAtPath:]"
                                                  : "+[DicomDatabase(DCMTK) decompressDicomFilesAtPaths:intoDirAtPath:]",
                      error.localizedDescription)
            },
            crashed: { files in
                guard preferences[DatabasePreferences.deletesListenerFiles] else { return }
                for path in files {
                    let errors = defaultDatabase()?.errorsDirPath() ?? ""
                    try? FileManager.default.moveItem(atPath: path,
                                                      toPath: (errors as NSString).appendingPathComponent((path as NSString).lastPathComponent))
                }
            })
        // The service has no preferences of its own: the conversion reads the
        // application's.
        let settings = DecompressConversion.settings(from: preferences)
        let moveIfUnreadable = preferences[DatabasePreferences.decompressMovesUnreadableFiles]
        return CompressionHelperRun.run(paths, mode: helperMode, destination: destination, environment: environment) {
            DecompressConversionTask(arguments: $0, settings: settings, moveIfUnreadable: moveIfUnreadable,
                                     service: DecompressService.shared)
        }
    }

    func convertInChunks(_ paths: [String], mode: FileConversionMode, into destination: String?) throws {
        var succeeded = true
        let thread = Thread.current

        let count = DicomDatabaseObjC.localizedFileCount(paths.count)
        if mode == .compress {
            thread.name = String(format: NSLocalizedString("Compressing %@", comment: ""), count)
        } else {
            thread.name = String(format: NSLocalizedString("Decompressing %@", comment: ""), count)
        }

        thread.status = NSLocalizedString("Waiting for similar threads to complete...", comment: "")
        thread.progress = -1

        if !thread.isMainThread {
            ThreadsManager.default()?.addThreadAndStart(thread) // this thread will be added more than one time, manager supports this.
        }

        let lock = database?.processFilesLock
        lock?.lock()
        if let exception = HorosObjCException.caught({
            thread.status = NSLocalizedString("Processing...", comment: "")

            let chunkSize = ConversionBatches.minimumChunkSize(fileCount: paths.count)
            let chunks = (paths as NSArray).splitArrayIntoArrays(ofMinSize: UInt(chunkSize), maxArrays: UInt(ConversionBatches.maximumChunks))

            let operationQueue = OperationQueue()
            operationQueue.maxConcurrentOperationCount = ConversionBatches.concurrentChunks(processorCount: ProcessInfo.processInfo.processorCount)
            let chunkEnded = DispatchSemaphore(value: 0)
            var results: [ConversionChunkResult] = []
            for case let chunk as [String] in chunks {
                let result = ConversionChunkResult()
                results.append(result)
                operationQueue.addOperation {
                    result.exception = HorosObjCException.caught {
                        result.succeeded = convertNow(chunk, mode: mode, into: destination)
                    }
                    chunkEnded.signal()
                }
            }

            for ended in 1 ..< max(results.count, 1) {
                chunkEnded.wait()
                thread.progress = CGFloat(ended) / CGFloat(results.count)
            }
            operationQueue.waitUntilAllOperationsAreFinished()

            for result in results {
                // -[NSInvocationOperation result] raised what the chunk raised.
                if let raised = result.exception { raised.raise() }
                if !result.succeeded { succeeded = false }
            }
        }) {
            succeeded = false
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase processFilesAtPaths:intoDirAtPath:mode:error:]")
        }
        lock?.unlock()

        if !succeeded {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("DICOM conversion could not be completed.", comment: ""),
                NSLocalizedFailureReasonErrorKey: NSLocalizedString("The compression or decompression process failed. Check that the input files are accessible and valid DICOM files.", comment: ""),
            ])
        }
    }

    func convertLater(_ paths: [String], mode: FileConversionMode, into destination: String?) {
        enqueue(FileConversionBatch(files: paths, mode: mode, destination: destination, isFromScan: false))
    }

    /// Queues files of the decompression folder the scan moved there. What is
    /// converted goes back to the incoming folder, and is imported as any file
    /// that arrives there.
    func convertScanned(_ paths: [String], mode: FileConversionMode) {
        enqueue(FileConversionBatch(files: paths, mode: mode, destination: ingest.incomingFolderPath(of: database), isFromScan: true))
    }

    /// Hands to the queue what a diagnostic probe left in the two arrays of the
    /// database, the only ones who fill them, and starts the worker.
    func convertWhatProbesQueued() {
        for (files, mode) in [(database?.horos_compressQueue, FileConversionMode.compress), (database?.horos_decompressQueue, .decompress)] {
            let paths: [String] = HorosObjCException.synchronized(files) {
                defer { files?.removeAllObjects() }
                return (files as? [String]) ?? []
            }
            convertScanned(paths, mode: mode)
        }
    }

    var isConverting: Bool {
        identifier.map { queue.isConverting($0) } ?? false
    }

    /// Waits for the conversion of what the scan of the incoming folder moved,
    /// not for what a selection or a plug-in asked: the thread
    /// -waitForCompressThread named converted only the former. Whether there was
    /// anything to wait for.
    func waitForScannedFiles() -> Bool {
        identifier.map { queue.waitForScannedFiles($0) } ?? false
    }

    private var identifier: String? {
        database?.sqlFilePath
    }

    private func enqueue(_ batch: FileConversionBatch) {
        guard let database else { return }
        let main = database.isMainDatabase() ? database : ((database.mainDatabase as? DicomDatabase) ?? database)
        queue.enqueue(batch, runner: ConversionWorker(database: main, ingest: ingest))
    }

    /// Indexes as they are the files a failed conversion left behind, through
    /// the single entry, on the calling thread: this is a batch of the queue,
    /// which must end before the next starts, and it waits for no one. On the
    /// queue of the database's context.
    fileprivate func importFailedFiles(_ files: [String]) {
        guard let database else { return }
        let verdict = ConversionImportFallback.recover(
            files: files,
            allocateDestination: {
                var destination: String? = nil
                if HorosObjCException.caught({ destination = database.uniquePathForNewDataFile(withExtension: "dcm") }) != nil {
                    return nil
                }
                return destination
            },
            importFiles: { paths in
                // One commit for the whole batch; the image records say which
                // copy each came from, so every file still gets its verdict.
                var counts: [String: Int] = [:]
                if let exception = HorosObjCException.caught({
                    for case let objectID as NSManagedObjectID in ingest.index(paths, preset: .decompress, in: database) ?? [] {
                        let image = (try? database.managedObjectContext.existingObject(with: objectID)) as? DicomImage
                        if let path = image?.completePath() { counts[path, default: 0] += 1 }
                    }
                }) {
                    DicomDatabaseObjC.log(exception, stack: true, "DatabaseFileConversion.importFailedFiles")
                }
                return counts
            })
        if !verdict.isEmpty {
            NSLog("---- conversion fallback: %@", verdict)
            Thread.current.status = verdict
        }
    }
}

/// The worker of one main database: each batch of its queue on a thread that
/// Activity lists once the conversion starts, as it lists any conversion.
///
/// `@unchecked Sendable`: `DicomDatabase` is not Sendable, and a conformance
/// would have to be in the file of the class. The reference never changes, and
/// the conversion uses it only on the context of its own thread.
private final class ConversionWorker: ConversionRunning, @unchecked Sendable {
    private let database: DicomDatabase
    private let ingest: DatabaseIngest
    let conversionIdentifier: String
    /// The thread of the batch being converted.
    private let converting = Mutex<Thread?>(nil)

    init(database: DicomDatabase, ingest: DatabaseIngest) {
        self.database = database
        self.ingest = ingest
        conversionIdentifier = database.sqlFilePath
    }

    func run(_ batch: FileConversionBatch) async {
        await ActivityThread.runUnlisted(name: NSLocalizedString("Waiting for processing files...", comment: "")) {
            self.converting.withLock { $0 = Thread.current }
            autoreleasepool { self.convert(batch) }
            self.converting.withLock { $0 = nil }
        }
    }

    func filesQueued(_ count: Int) {
        converting.withLock {
            $0?.status = String(format: NSLocalizedString("%d additional files queued", comment: ""), Int32(truncatingIfNeeded: count))
        }
    }

    private func convert(_ batch: FileConversionBatch) {
        // The files and their rows are written by a context on its own queue, and on that queue.
        guard let worker = database.privateQueueIndependentDatabase() as? DicomDatabase else {
            NSLog("---- conversion: no context for %lu file(s) of %@; they stay where they are", UInt(batch.files.count), DicomDatabaseObjC.arg(database.name))
            return
        }
        let conversion = ingest.fileConversion(of: worker)
        if let exception = HorosObjCException.caught({
            worker.performBlockAndWait {
                do {
                    try conversion.convertInChunks(batch.files, mode: batch.mode, into: batch.destination)
                } catch {
                    if batch.isFromScan { conversion.importFailedFiles(batch.files) }
                }
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "ConversionWorker.convert")
        }
    }
}

extension FileConversionMode {
    /// The `Compress` and `Decompress` of the header.
    init(databaseMode mode: Int32) {
        self = mode == Int32(Compress) ? .compress : .decompress
    }
}

extension DatabaseIngest {
    /// The conversion of the files of `database`, which gives back to this entry
    /// what it could not convert. nil for a run of the helper, which asks nothing of a database.
    func fileConversion(of database: DicomDatabase?) -> DatabaseFileConversion {
        let processGraph = processGraph
        return DatabaseFileConversion(database: database, ingest: self, queue: processGraph.conversionQueue,
                                      preferences: processGraph.preferences, defaultDatabase: { processGraph.defaultDatabase })
    }
}

extension DatabaseIngest {
    /// The conversion of the files of `database`, as what consumes the port sees it.
    func fileConverting(of database: DicomDatabase?) -> any DatabaseFileConverting {
        fileConversion(of: database)
    }
}

// The selectors of the contract, and the keys the conversion probe uses.
@objc(Compression) @implementation extension DicomDatabase {

    /// The paths of a selector's array, whatever a caller put among them.
    private final class func conversionPaths(_ paths: [Any]?) -> [String] {
        (paths ?? []).map { "\($0)" }
    }

    func compressFiles(atPaths paths: [Any]!) -> Bool {
        return DicomDatabase.compressDicomFiles(atPaths: paths)
    }

    func compressFiles(atPaths paths: [Any]!, intoDirAtPath destDir: String!) -> Bool {
        return DicomDatabase.compressDicomFiles(atPaths: paths, intoDirAtPath: destDir)
    }

    func decompressFiles(atPaths paths: [Any]!) -> Bool {
        return DicomDatabase.decompressDicomFiles(atPaths: paths)
    }

    func decompressFiles(atPaths paths: [Any]!, intoDirAtPath destDir: String!) -> Bool {
        return DicomDatabase.decompressDicomFiles(atPaths: paths, intoDirAtPath: destDir)
    }

    func processFiles(atPaths paths: [Any]!, intoDirAtPath destDir: String!, mode: Int32) {
        _ = self.processFiles(atPaths: paths, intoDirAtPath: destDir, mode: mode, error: nil)
    }

    // NS_SWIFT_NOTHROW in the header: the error is written to `error`, as the
    // Objective-C callers read it, only when the conversion did not succeed.
    func processFiles(atPaths paths: [Any]!, intoDirAtPath destDir: String!, mode: Int32, error: NSErrorPointer) -> Bool {
        do {
            try DatabaseIngest.process.fileConversion(of: self).convertInChunks(DicomDatabase.conversionPaths(paths), mode: FileConversionMode(databaseMode: mode), into: destDir)
            return true
        } catch let failure {
            error?.pointee = failure as NSError
            return false
        }
    }

    func initiateCompressFiles(atPaths paths: [Any]!) {
        DatabaseIngest.process.fileConversion(of: self).convertLater(DicomDatabase.conversionPaths(paths), mode: .compress, into: nil)
    }

    func initiateCompressFiles(atPaths paths: [Any]!, intoDirAtPath destDir: String!) {
        DatabaseIngest.process.fileConversion(of: self).convertLater(DicomDatabase.conversionPaths(paths), mode: .compress, into: destDir)
    }

    func initiateDecompressFiles(atPaths paths: [Any]!) {
        DatabaseIngest.process.fileConversion(of: self).convertLater(DicomDatabase.conversionPaths(paths), mode: .decompress, into: nil)
    }

    func initiateDecompressFiles(atPaths paths: [Any]!, intoDirAtPath destDir: String!) {
        DatabaseIngest.process.fileConversion(of: self).convertLater(DicomDatabase.conversionPaths(paths), mode: .decompress, into: destDir)
    }

    func waitForCompressThread() -> Bool {
        return DatabaseIngest.process.fileConversion(of: self).waitForScannedFiles()
    }

    /// The queues by key, for the probes that fill them.
    @objc(compressQueue) private var compressQueueByKey: NSMutableArray? { horos_compressQueue }
    @objc(decompressQueue) private var decompressQueueByKey: NSMutableArray? { horos_decompressQueue }

    @objc(kickstartCompressDecompress)
    private func kickstartCompressDecompress() {
        DatabaseIngest.process.fileConversion(of: self).convertWhatProbesQueued()
    }
}
