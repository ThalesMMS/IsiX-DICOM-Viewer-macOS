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
import Synchronization

// DicomDatabase (Compression): compressing and decompressing DICOM files, in
// chunks on an operation queue, under the lock the main database shares with
// its independent databases; and the queue of the incoming files waiting for
// it, which one thread empties, the main database's.
//
// A chunk ran as an NSInvocationOperation, unavailable in Swift: it runs as a
// block operation whose result, or the exception it raised, is read after the
// queue is done, where -[NSInvocationOperation result] answered or raised it.

/// The lock -threadBridgeForProcessFilesAtPaths: took: one conversion at a
/// time from the threads it starts.
nonisolated(unsafe) private let processFilesBridgeLock = NSObject()
/// The threads waiting for that lock; past 50, a new one gives up.
private let processFilesBridgeWaitingThreads = Atomic<Int>(0)

/// What a chunk answered, or the exception it raised.
private final class ConversionChunkResult: @unchecked Sendable {
    var succeeded = false
    var exception: NSException?
}

@objc(Compression) @implementation extension DicomDatabase {

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
        var succeeded = true
        var queue: OperationQueue? = nil
        let thread = Thread.current
        let files = (paths as NSArray?) ?? NSArray()

        let count = DicomDatabaseObjC.localizedFileCount(files.count)
        if mode == Int32(Compress) {
            thread.name = String(format: NSLocalizedString("Compressing %@", comment: ""), count)
        } else {
            thread.name = String(format: NSLocalizedString("Decompressing %@", comment: ""), count)
        }

        thread.status = NSLocalizedString("Waiting for similar threads to complete...", comment: "")
        thread.progress = -1

        if !thread.isMainThread {
            ThreadsManager.default()?.addThreadAndStart(thread) // this thread will be added more than one time, manager supports this.
        }

        let lock = processFilesLock
        lock?.lock()
        if let exception = DicomDatabaseObjC.attempt({
            thread.status = NSLocalizedString("Processing...", comment: "")

            let chunkSize = ConversionBatches.minimumChunkSize(fileCount: files.count)
            let chunks = files.splitArrayIntoArrays(ofMinSize: UInt(chunkSize), maxArrays: UInt(ConversionBatches.maximumChunks))

            let operationQueue = OperationQueue()
            queue = operationQueue
            var results: [ConversionChunkResult] = []
            operationQueue.maxConcurrentOperationCount = ConversionBatches.concurrentChunks(processorCount: ProcessInfo.processInfo.processorCount)
            nonisolated(unsafe) let database = self
            for case let chunk as NSArray in chunks {
                let result = ConversionChunkResult()
                nonisolated(unsafe) let work = chunk
                results.append(result)
                operationQueue.addOperation {
                    result.exception = DicomDatabaseObjC.attempt {
                        result.succeeded = database.processChunk(work, mode: mode, intoDirAtPath: destDir)
                    }
                }
            }

            let initialOpCount = operationQueue.operationCount
            while operationQueue.operationCount != 0 {
                if operationQueue.operationCount != initialOpCount {
                    thread.progress = CGFloat(initialOpCount - operationQueue.operationCount) / CGFloat(initialOpCount)
                }
                Thread.sleep(forTimeInterval: 0.01)
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
        queue?.waitUntilAllOperationsAreFinished()
        lock?.unlock()

        if !succeeded {
            error?.pointee = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("DICOM conversion could not be completed.", comment: ""),
                NSLocalizedFailureReasonErrorKey: NSLocalizedString("The compression or decompression process failed. Check that the input files are accessible and valid DICOM files.", comment: ""),
            ])
        }
        return succeeded
    }

    /// -_processFilesAtPaths_processChunk:.
    private final func processChunk(_ chunk: NSArray, mode: Int32, intoDirAtPath destDir: String?) -> Bool {
        if mode == Int32(Compress) {
            return DicomDatabase.compressDicomFiles(atPaths: chunk as? [Any], intoDirAtPath: destDir)
        } else {
            return DicomDatabase.decompressDicomFiles(atPaths: chunk as? [Any], intoDirAtPath: destDir)
        }
    }

    @objc(threadBridgeForProcessFilesAtPaths:)
    private func threadBridgeForProcessFiles(_ params: NSDictionary) {
        autoreleasepool {
            let thread = Thread.current
            thread.name = NSLocalizedString("Waiting for processing files...", comment: "")

            ThreadsManager.default()?.addThreadAndStart(thread)

            guard processFilesBridgeWaitingThreads.load(ordering: .relaxed) < 50 else { return }
            processFilesBridgeWaitingThreads.add(1, ordering: .relaxed)

            DicomDatabaseObjC.synchronized(processFilesBridgeLock) {
                if let exception = DicomDatabaseObjC.attempt({
                    // The files and their rows are written by a context on its own
                    // queue, and on that queue.
                    let worker = self.isMainDatabase() ? (self.privateQueueIndependentDatabase() as? DicomDatabase) : self
                    worker?.performBlockAndWait {
                        worker?.processFiles(atPaths: params.object(forKey: ":") as? [Any],
                                             intoDirAtPath: params.object(forKey: "intoDirAtPath:") as? String,
                                             mode: (params.object(forKey: "mode:") as? NSNumber)?.int32Value ?? 0)
                    }
                }) {
                    DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase threadBridgeForProcessFilesAtPaths:]")
                }
            }

            processFilesBridgeWaitingThreads.subtract(1, ordering: .relaxed)
        }
    }

    /// -initiateProcessFilesAtPaths:intoDirAtPath:mode:: on a thread of its own.
    private final func initiateProcessFiles(atPaths paths: [Any]!, intoDirAtPath destDir: String?, mode: Int32) {
        let params = DicomDatabaseObjC.dictionary([(paths as NSArray?, ":"), (NSNumber(value: mode), "mode:"),
                                                   (destDir, "intoDirAtPath:") /* destDir can be nil */])
        self.performSelector(inBackground: #selector(DicomDatabase.threadBridgeForProcessFiles(_:)), with: params)
    }

    func initiateCompressFiles(atPaths paths: [Any]!) {
        initiateProcessFiles(atPaths: paths, intoDirAtPath: nil, mode: Int32(Compress))
    }

    func initiateCompressFiles(atPaths paths: [Any]!, intoDirAtPath destDir: String!) {
        initiateProcessFiles(atPaths: paths, intoDirAtPath: destDir, mode: Int32(Compress))
    }

    func initiateDecompressFiles(atPaths paths: [Any]!) {
        initiateProcessFiles(atPaths: paths, intoDirAtPath: nil, mode: Int32(Decompress))
    }

    func initiateDecompressFiles(atPaths paths: [Any]!, intoDirAtPath destDir: String!) {
        initiateProcessFiles(atPaths: paths, intoDirAtPath: destDir, mode: Int32(Decompress))
    }

    // MARK: - The queue of the incoming files

    /// The main database: the one whose thread empties the queues.
    final var conversionDatabase: DicomDatabase {
        return self.isMainDatabase() ? self : ((self.mainDatabase as? DicomDatabase) ?? self)
    }

    func waitForCompressThread() -> Bool {
        let mdb = conversionDatabase

        if mdb.horos_compressDecompressThread?.isFinished == true || mdb.horos_compressDecompressThread?.isCancelled == true {
            return false
        }

        if mdb.horos_compressDecompressThread?.isExecuting == true {
            while mdb.horos_compressDecompressThread?.isExecuting == true {
                Thread.sleep(forTimeInterval: 0.1)
            }
            return true
        }

        return false
    }

    /// Queues files of the decompression folder for decompression (the queue the
    /// worker takes them from, under its own lock) and starts the worker.
    final func queueForDecompression(_ paths: [String]) {
        DicomDatabaseObjC.synchronized(horos_decompressQueue) {
            horos_decompressQueue?.addObjects(from: paths)
        }
        kickstartCompressDecompress()
    }

    /// Queues files of the decompression folder for compression and starts the worker.
    final func queueForCompression(_ paths: [String]) {
        // Under the lock the worker takes this queue with: under the other
        // one, a scan could add while the worker copied and emptied it, and
        // what it added stayed in the decompression folder, which nothing
        // reads again.
        DicomDatabaseObjC.synchronized(horos_compressQueue) {
            horos_compressQueue?.addObjects(from: paths)
        }
        kickstartCompressDecompress()
    }

    /// The queues by key, for the probes that fill them.
    @objc(compressQueue) private var compressQueueByKey: NSMutableArray? { horos_compressQueue }
    @objc(decompressQueue) private var decompressQueueByKey: NSMutableArray? { horos_decompressQueue }

    @objc(kickstartCompressDecompress)
    private func kickstartCompressDecompress() {
        DicomDatabaseObjC.synchronized(horos_compressQueue) {
            DicomDatabaseObjC.synchronized(horos_decompressQueue) {
                let mdb = conversionDatabase
                if mdb.horos_compressDecompressThread == nil {
                    let thread = Thread(target: self, selector: #selector(DicomDatabase.threadCompressDecompress), object: nil)
                    mdb.horos_compressDecompressThread = thread
                    thread.start()
                } else {
                    mdb.horos_compressDecompressThread?.status = String(format: NSLocalizedString("%d additional files queued", comment: ""),
                                                                        Int32(truncatingIfNeeded: (horos_compressQueue?.count ?? 0) + (horos_decompressQueue?.count ?? 0)))
                }
            }
        }
    }

    @objc(_threadCompressDecompress)
    private func threadCompressDecompress() {
        var finished = false
        while !finished {
            for i in 0..<2 { // i 0 -> compression; i 1 -> decompression
                autoreleasepool {
                    let queue = i == 0 ? horos_compressQueue : horos_decompressQueue
                    let todo: NSArray = DicomDatabaseObjC.synchronized(queue) {
                        let todo = (queue?.copy() as? NSArray) ?? NSArray()
                        queue?.removeAllObjects()
                        return todo
                    }

                    if todo.count != 0 {
                        // Converted and indexed by a context on its own queue, on that queue.
                        let worker = (self.isMainDatabase() ? (self.privateQueueIndependentDatabase() as? DicomDatabase) : self)
                        worker?.performBlockAndWait {
                            guard let worker else { return }
                            var conversionError: NSError? = nil
                            if !worker.processFiles(atPaths: todo as? [Any], intoDirAtPath: self.incomingDirPath(),
                                                    mode: Int32(i == 0 ? Compress : Decompress), error: &conversionError) {
                                let verdict = ConversionImportFallback.recover(
                                    files: (todo as? [String]) ?? [],
                                    allocateDestination: {
                                        var destination: String? = nil
                                        if DicomDatabaseObjC.attempt({ destination = worker.uniquePathForNewDataFile(withExtension: "dcm") }) != nil {
                                            return nil
                                        }
                                        return destination
                                    },
                                    importFiles: { paths in
                                        // One commit for the whole batch; the image records say which
                                        // copy each came from, so every file still gets its verdict.
                                        var counts: [String: Int] = [:]
                                        if let exception = DicomDatabaseObjC.attempt({
                                            let objectIDs = worker.addFiles(atPaths: paths as [Any], postNotifications: true, dicomOnly: true,
                                                                            rereadExistingItems: false, generatedByOsiriX: false) as NSArray?
                                            for case let objectID as NSManagedObjectID in objectIDs ?? [] {
                                                let image = (try? worker.managedObjectContext.existingObject(with: objectID)) as? DicomImage
                                                if let path = image?.completePath() { counts[path, default: 0] += 1 }
                                            }
                                        }) {
                                            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase _threadCompressDecompress]_block_invoke")
                                        }
                                        return counts
                                    })
                                if !verdict.isEmpty {
                                    NSLog("---- conversion fallback: %@", verdict)
                                    Thread.current.status = verdict
                                }
                            }
                        }
                    }
                }
            }

            DicomDatabaseObjC.synchronized(horos_compressQueue) {
                DicomDatabaseObjC.synchronized(horos_decompressQueue) {
                    if (horos_compressQueue?.count ?? 0) == 0 && (horos_decompressQueue?.count ?? 0) == 0 {
                        conversionDatabase.horos_compressDecompressThread = nil
                        finished = true
                    }
                }
            }
        }
    }
}
