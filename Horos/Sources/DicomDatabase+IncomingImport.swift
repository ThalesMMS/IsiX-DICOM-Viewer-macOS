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
import IsiXStorage

// DicomDatabase (IncomingImport): the incoming folder the DICOM listener fills,
// and its scan. A timer on the main run loop asks every local main database to
// import, which happens on a thread of its own, on a private-queue context, under
// the lock the main database shares with its independent databases. The scan
// moves what the database indexes into its data folder, archives and files to
// convert into the decompression folder, and keeps or deletes the rest, then
// indexes what it took (DicomDatabase+Import.swift). Every import passes the
// gate quitting closes.

/// The NSTimer of +syncImportFilesFromIncomingDirTimerWithUserDefaults.
nonisolated(unsafe) private var importFilesFromIncomingDirTimer: Timer? = nil
/// The archives that could not be moved to the decompression folder, said once each.
nonisolated(unsafe) private let reportedUnmovableArchives = NSMutableSet()

/// Whether an incoming file is DICOM in the Deflated Explicit VR Little Endian
/// transfer syntax, which the decompression helper inflates.
private func isDeflatedDICOM(_ path: String) -> Bool {
    #if !OSIRIX_LIGHT
    return EnhancedImportTriage.isDeflatedDICOM(atPath: path)
    #else
    return false
    #endif
}

/// Whether compressing an uncompressed incoming file is worth it.
private func needsCompression(_ path: String) -> Bool {
    #if !OSIRIX_LIGHT
    return DicomDatabase.fileNeedsDecompression(path)
    #else
    return true
    #endif
}

/// `[[NSFileManager defaultManager] moveItemAtPath:from toPath:to error:]`.
private func moveItem(_ from: String?, _ to: String?) -> NSError? {
    guard let from, let to else { return NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError) }
    do {
        try FileManager.default.moveItem(atPath: from, toPath: to)
        return nil
    } catch {
        return error as NSError
    }
}

/// `[[NSFileManager defaultManager] removeItemAtPath:path error:]`.
private func removeItem(_ path: String?) {
    if let path { try? FileManager.default.removeItem(atPath: path) }
}

@objc(IncomingImport) @implementation extension DicomDatabase {

    func isFileSystemFreeSizeLimitReached() -> Bool {
        let currentTime = Date.timeIntervalSinceReferenceDate
        if currentTime - timeOfLastFreeSizeVerification > StorageFreeSpace.verificationInterval {
            // refresh freeSizeLimitReached
            let dataBasePathAttrs = self.dataBaseDirPath.flatMap { try? FileManager.default.attributesOfFileSystem(forPath: $0) }
            let dataBasePathSize = dataBasePathAttrs?[.systemSize] as? NSNumber
            let dataBasePathFreeSize = dataBasePathAttrs?[.systemFreeSize] as? NSNumber
            if let dataBasePathFreeSize, let dataBasePathSize {
                freeSizeLimitReached = StorageFreeSpace.isBelowLimit(sizeBytes: dataBasePathSize.uint64Value, freeBytes: dataBasePathFreeSize.uint64Value)
                timeOfLastFreeSizeVerification = currentTime

                if freeSizeLimitReached {
                    NSLog("Warning: the volume used to store data for %@ is full; queued incoming files are preserved and new DICOM transfers will be rejected", DicomDatabaseObjC.arg(self.name))
                }
            } else {
                return true
            }
        }

        return freeSizeLimitReached
    }

    func hasFilesToImport() -> Bool {
        let enumer = FileManager.default.enumerator(atPath: self.incomingDirPath(), limitTo: -1)
        return enumer.nextObject() != nil
    }

    var incomingImportInProgress: Bool {
        // Shared with the independent databases that do the work. Observe without
        // waiting: the retrieve must remain cancellable during a long import.
        guard let importLock = importFilesFromIncomingDirLock, importLock.try() else { return true }
        importLock.unlock()
        guard let processLock = processFilesLock, processLock.try() else { return true }
        processLock.unlock()
        return DicomDatabaseObjC.synchronized(horos_compressQueue) {
            DicomDatabaseObjC.synchronized(horos_decompressQueue) {
                // The worker also covers the fallback import after conversion.
                (horos_compressQueue?.count ?? 0) != 0 || (horos_decompressQueue?.count ?? 0) != 0 ||
                    conversionDatabase.horos_compressDecompressThread?.isExecuting == true
            }
        }
    }

    func importFilesFromIncomingDir() -> Int {
        return self.importFiles(fromIncomingDir: NSNumber(value: false))
    }

    func importFiles(fromIncomingDir showGUI: NSNumber!) -> Int {
        return self.importFiles(fromIncomingDir: showGUI, listenerCompressionSettings: Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "ListenerCompressionSettings")))
    }

    // Every import of the folder passes the gate quitting closes: the process's
    // exit destroys DCMTK's dictionary and loggers, and an import still reading a
    // file then reads freed memory. ThreadsManager lists an import too late for
    // quitting to rely on it.
    func importFiles(fromIncomingDir showGUI: NSNumber!, listenerCompressionSettings: Int32) -> Int {
        if !IncomingImportGate.shared.enter() {
            return 0
        }
        var imported = 0
        let raised = DicomDatabaseObjC.attempt {
            imported = self.importAdmittedFilesFromIncomingDir(showGUI, listenerCompressionSettings: listenerCompressionSettings)
        }
        IncomingImportGate.shared.leave()
        if let raised { raised.raise() }
        return imported
    }

    // A scan reports for itself: whatever the last one refused stops being current
    // the moment a new one starts.
    private final func importAdmittedFilesFromIncomingDir(_ showGUI: NSNumber?, listenerCompressionSettings: Int32) -> Int {
        var compressedPathArray: [String] = []
        var deflatedPathArray: [String] = []
        let thread = Thread.current
        var addedFilesCount = 0
        var activityFeedbackShown = false
        var listenerCompressionSettings = listenerCompressionSettings
        let defaults = UserDefaults.standard

        FileManager.default.confirmNoIndexDirectory(atPath: self.decompressionDirPath())

        let enumer = FileManager.default.enumerator(atPath: self.incomingDirPath(), limitTo: -1)

        var storageFull = false
        let lock = importFilesFromIncomingDirLock
        lock?.lock()
        if let exception = DicomDatabaseObjC.attempt({
            if self.isFileSystemFreeSizeLimitReached() {
                self.cleanForFreeSpace()
                // Cleanup may have just freed space; do not reuse the pre-cleanup
                // capacity result cached for up to twenty seconds.
                self.timeOfLastFreeSizeVerification = 0
                if self.isFileSystemFreeSizeLimitReached() {
                    NSLog("Incoming import paused: database storage is full or unavailable; queued files are preserved")
                    storageFull = true
                    return
                }
            }

            let filesArray = NSMutableArray()
            #if OSIRIX_LIGHT
            listenerCompressionSettings = 0
            #endif

            FileManager.default.confirmNoIndexDirectory(atPath: self.dataDirPath())

            let maxNumberOfFiles = IncomingScanRules.maximumFiles(preference: defaults.integer(forKey: "maxNumberOfFilesForCheckIncoming"))

            let startTime = Date.timeIntervalSinceReferenceDate
            var start = startTime

            while filesArray.count < maxNumberOfFiles &&
                    (Date.timeIntervalSinceReferenceDate - startTime < TimeInterval(defaults.integer(forKey: "LISTENERCHECKINTERVAL") * 3)), // don't let them wait more than (incomingdelay*3) seconds
                  let pathname = enumer.nextObject() as? String {
                // Stopping here still returns what this pass already moved.
                if thread.isCancelled {
                    break
                }

                var srcPath = DicomDatabaseObjC.appending(self.incomingDirPath(), pathname) ?? pathname
                let originalPath = srcPath
                let lastPathComponent = (srcPath as NSString).lastPathComponent

                // An archive is expanded into a directory of its own name inside this
                // folder, and its entries are then imported one by one - here, and
                // possibly over several scans. Each entry says what became of it; the
                // running tally is what lets the archive itself say so too.
                let enclosingArchiveComponent = ArchiveImportLedger.archiveComponent(ofRelativePath: pathname)
                let enclosingArchive = enclosingArchiveComponent.flatMap { DicomDatabaseObjC.appending(self.incomingDirPath(), $0) }

                switch IncomingScanRules.entry(named: lastPathComponent) {
                case .systemLitter:
                    removeItem(srcPath)
                    continue
                case .hidden:
                    // The enumerator has already opened a hidden folder by the time it
                    // is returned. Its contents are not ours to take: the Decompress
                    // helper expands archives in .horos-extract-<UUID>/contents here,
                    // and its files were imported while unzip was still writing them,
                    // leaving the emptied staging folder behind.
                    enumer.skipDescendents()

                    // delete old files starting with '.'
                    var st = Darwin.stat()
                    if enumer.stat(&st) == 0 {
                        let date = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                        if date.timeIntervalSinceNow < -IncomingScanRules.hiddenEntryLifetime {
                            NSLog("deleting old incoming file %@ (date modified: %@)", srcPath, date as NSDate)
                            removeItem(srcPath)
                        }
                    }

                    continue // don't handle this file, it's probably a busy file
                case .candidate:
                    break
                }

                let originalSrcPath = srcPath
                srcPath = (srcPath as NSString).resolvingSymlinksAndAliases() ?? srcPath
                let isAlias = !DicomDatabaseObjC.isEqual(srcPath, originalSrcPath)

                // The image of an Analyze or NIfTI pair goes into the database with its header, under the
                // header's new name. Taken on its own it was not a file this database indexes and,
                // with DELETEFILELISTENER, it was deleted. One already taken along is no longer here.
                if ((srcPath as NSString).pathExtension as NSString).lowercased == "img" &&
                    (HeaderImagePair.headerPath(forImage: srcPath) != nil || !FileManager.default.fileExists(atPath: srcPath)) {
                    continue
                }

                if filesArray.count != 0 && !activityFeedbackShown && (showGUI?.boolValue ?? false) {
                    ThreadsManager.default()?.addThreadAndStart(thread)
                    OsiriX?.setReceivingIcon()
                    activityFeedbackShown = true
                }

                // Imported files may be read-only (for example, on a CD); do not require writability.
                let fattrs = enumer.fileAttributes

                if (fattrs?[.busy] as? NSNumber)?.boolValue == true {
                    continue
                }

                let size = (fattrs?[.size] as? NSNumber)?.int64Value ?? 0
                if DicomDatabaseObjC.isEqual(fattrs?[.type] as? String, FileAttributeType.typeDirectory.rawValue) {
                    // if alias assume nested folders should stay
                    if !isAlias { // Is this directory empty?? If yes, delete it!
                        let dirContainsStuff = FileManager.default.enumerator(atPath: srcPath, filesOnly: false).nextObject() != nil

                        if !dirContainsStuff {
                            // The expansion has run out: this is the last moment
                            // at which anything can still say what the archive
                            // held. Without it an archive containing no DICOM at
                            // all left no trace whatsoever.
                            if enclosingArchive == nil && ArchiveImportLedger.isArchiveName(lastPathComponent) {
                                NSLog("---- import: %@", ArchiveImportLedger.shared.verdictForArchive(srcPath, keptDirectoryName: ((self.errorsDirPath() ?? "") as NSString).lastPathComponent))
                            }

                            removeItem(srcPath)
                        }
                    }
                } else if size == 0 {
                    // An empty file matched neither branch and stayed in the
                    // incoming folder for ever, re-enumerated on every scan. A
                    // transfer that has written nothing for five minutes has
                    // stopped writing.
                    let modified = fattrs?[.modificationDate] as? Date
                    if modified == nil || modified!.timeIntervalSinceNow < -IncomingScanRules.stalledEmptyFileAge {
                        NSLog("---- import: %@ is empty; removed from the incoming folder", lastPathComponent)
                        removeItem(srcPath)
                    }
                } else if size > 0 {
                    if self.unpackWADORSMultipart(srcPath, enclosingArchive: enclosingArchive) {
                        continue
                    }

                    if ArchiveImportLedger.isArchiveName(srcPath) {
                        // A name of its own there: files of the same name come from
                        // different folders of INCOMING.
                        let compressedPath = availablePath(inDirectory: self.decompressionDirPath(), name: lastPathComponent)
                        if let moveError = moveItem(srcPath, compressedPath) {
                            // It stays here and is retried on every scan - which
                            // is what makes it recoverable once the cause is
                            // fixed - so say it once per file rather than once
                            // per scan, and once rather than not at all.
                            DicomDatabaseObjC.synchronized(reportedUnmovableArchives) {
                                if !reportedUnmovableArchives.contains(srcPath) {
                                    reportedUnmovableArchives.add(srcPath)
                                    NSLog("---- import: %@ could not be moved to the decompression folder (%@); it stays here and is tried again on the next scan", lastPathComponent, moveError.localizedDescription)
                                }
                            }
                        } else if let compressedPath {
                            compressedPathArray.append(compressedPath)
                            if let enclosingArchive {
                                ArchiveImportLedger.shared.recordNestedArchive(inArchive: enclosingArchive)
                            }
                        }
                    } else if isDeflatedDICOM(srcPath) {
                        // Deflated Explicit VR Little Endian: nothing on this side
                        // reads the dataset, and it used to be refused as "not
                        // DICOM" - and deleted with DELETEFILELISTENER.
                        // The decompression helper inflates it to Explicit VR Little
                        // Endian and puts it back here, whatever the listener's
                        // compression setting, as it does for an archive.
                        let compressedPath = availablePath(inDirectory: self.decompressionDirPath(), name: lastPathComponent)
                        if let moveError = moveItem(srcPath, compressedPath) {
                            NSLog("---- import: %@ is deflated and could not be moved to the decompression folder (%@); it stays here and is tried again on the next scan", lastPathComponent, moveError.localizedDescription)
                        } else if let compressedPath {
                            deflatedPathArray.append(compressedPath)
                            if let enclosingArchive {
                                ArchiveImportLedger.shared.recordQueuedEntry(inArchive: enclosingArchive)
                            }
                        }
                    } else {
                        self.takeIncomingFile(srcPath, originalPath: originalPath, lastPathComponent: lastPathComponent, isAlias: isAlias,
                                              enclosingArchive: enclosingArchive, listenerCompressionSettings: listenerCompressionSettings,
                                              filesArray: filesArray, compressedPathArray: &compressedPathArray)
                    }
                }

                if Date.timeIntervalSinceReferenceDate - start > 0.5 {
                    thread.status = DicomDatabaseObjC.localizedFileCount(filesArray.count)
                    start = Date.timeIntervalSinceReferenceDate
                }
            }

            if filesArray.count != 0 {
                thread.status = DicomDatabaseObjC.localizedFileCount(filesArray.count)
            }

            if filesArray.count > 0 {
                let plugins = PluginManager.preProcessPlugins() ?? NSArray()
                if plugins.count != 0 && thread.isCancelled == false {
                    thread.status = String(format: NSLocalizedString("Preprocessing %d files with %d plugins...", comment: ""), Int32(truncatingIfNeeded: filesArray.count), Int32(truncatingIfNeeded: plugins.count))
                    for filter in plugins {
                        if let exception = DicomDatabaseObjC.attempt({
                            PluginManager.startProtectForCrash(withFilter: filter)
                            _ = (filter as AnyObject).perform(NSSelectorFromString("processFiles:"), with: filesArray)
                            PluginManager.endProtectForCrash()
                        }) {
                            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase importAdmittedFilesFromIncomingDir:listenerCompressionSettings:]")
                        }
                    }
                }

                thread.status = String(format: NSLocalizedString("Processing %@...", comment: ""), DicomDatabaseObjC.localizedFileCount(filesArray.count))

                var addedFiles: NSArray? = nil
                let unindexedFiles = NSMutableArray()
                if thread.isCancelled == false {
                    addedFiles = self.addFiles(atPaths: filesArray,
                                               postNotifications: true,
                                               dicomOnly: defaults.bool(forKey: "onlyDICOM"),
                                               rereadExistingItems: false,
                                               generatedByOsiriX: false,
                                               importedFiles: false,
                                               returnArray: true,
                                               unindexedPaths: unindexedFiles) // these are IDs!
                }

                addedFilesCount = addedFiles?.count ?? 0

                // What this pass took and what it indexed. The incoming folder is the
                // local half of the same question the medium scan answers for a
                // mounted volume, and comparing the two needs the same three numbers
                // from both.
                if filesArray.count != 0 {
                    NSLog("(importFilesFromIncomingDir): %lu file(s) taken from the incoming folder, %lu indexed, in %.1f s (%.1f ms per file)",
                          UInt(filesArray.count), UInt(addedFilesCount),
                          Date.timeIntervalSinceReferenceDate - startTime,
                          1000.0 * (Date.timeIntervalSinceReferenceDate - startTime) / Double(filesArray.count))
                }

                if addedFiles == nil { // Add failed or cancelled.... Keep these files: move them back to the INCOMING folder and try again later....
                    self.returnFilesToIncomingDir((filesArray as? [String]) ?? [])
                } else if unindexedFiles.count != 0 { // cancelled part way
                    self.returnFilesToIncomingDir((unindexedFiles as? [String]) ?? [])
                }
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase importAdmittedFilesFromIncomingDir:listenerCompressionSettings:]")
        }
        // @finally
        lock?.unlock()
        if activityFeedbackShown {
            OsiriX?.unsetReceivingIcon()
        }
        if storageFull {
            return 0
        }

        // A cancelled pass starts no decompression: quitting is what cancels it,
        // and it empties the decompression folder.
        if thread.isCancelled {
            self.returnFilesToIncomingDir(deflatedPathArray)
            self.returnFilesToIncomingDir(compressedPathArray)
            return addedFilesCount
        }

        if enumer.nextObject() != nil { // there is more data
            self.perform(#selector(DicomDatabase.initiateImportFilesFromIncomingDirUnlessAlreadyImporting), with: nil, afterDelay: 0)
        }

        #if !OSIRIX_LIGHT
        if !deflatedPathArray.isEmpty { // deflated files are inflated whatever the compression setting
            self.queueForDecompression(deflatedPathArray)
        }

        if !compressedPathArray.isEmpty { // there are files to compress/decompress in the decompression dir
            switch IncomingScanRules.queue(forListenerCompressionSettings: Int(listenerCompressionSettings)) {
            case .decompress: // decompress, listenerCompressionSettings == 0 for zip support!
                self.queueForDecompression(compressedPathArray)
            case .compress:
                self.queueForCompression(compressedPathArray)
            case .none:
                break
            }
        }
        #endif

        return addedFilesCount
    }

    /// A WADO-RS response saved whole into the incoming folder: its DICOM parts
    /// are written as files of their own beside it, and it goes. Whether it was one.
    private final func unpackWADORSMultipart(_ srcPath: String, enclosingArchive: String?) -> Bool {
        //if file not available for reading, do nothing
        guard let file = FileHandle(forReadingAtPath: srcPath) else { return false }

        var dicomFileCreated = false
        var data = file.readData(ofLength: WADORSMultipart.probeLength)

        if WADORSMultipart.announcesDICOMParts(data) {
            //read the rest of file
            data.append(file.readDataToEndOfFile())

            let cut = WADORSMultipart.dicomParts(in: data)
            for part in cut.parts {
                //write dicom file
                let destination = DicomDatabaseObjC.appending(self.incomingDirPath(), UUID().uuidString)
                dicomFileCreated = destination.map { (data.subdata(in: part) as NSData).write(toFile: $0, atomically: false) } ?? false
            }
            if cut.malformed {
                // -subdataWithRange: raised for a part past the end of the body.
                file.closeFile()
                NSException(name: .rangeException, reason: "a multipart part of \((srcPath as NSString).lastPathComponent) exceeds its data length", userInfo: nil).raise()
            }
        }
        file.closeFile()

        if dicomFileCreated {
            // The parts were written out as separate files and
            // this one no longer exists: continuing would test a
            // missing path and report it as unreadable.
            removeItem(srcPath)
            if let enclosingArchive {
                ArchiveImportLedger.shared.recordIndexedEntry(inArchive: enclosingArchive)
            }
            return true
        }
        return false
    }

    /// A file of the incoming folder that is neither an archive nor deflated:
    /// moved into the database folder if the database indexes it, to the
    /// decompression folder if the listener converts it, kept aside or deleted
    /// otherwise.
    private final func takeIncomingFile(_ srcPath: String, originalPath: String, lastPathComponent: String, isAlias: Bool, enclosingArchive: String?,
                                  listenerCompressionSettings: Int32, filesArray: NSMutableArray, compressedPathArray: inout [String]) {
        var isJPEGCompressed: ObjCBool = false, isImage: ObjCBool = false, mayTranscode: ObjCBool = false
        var dstPath = DicomDatabaseObjC.appending(self.dataDirPath(), lastPathComponent)

        let isDicomFile = DicomFile.isDICOMFile(srcPath, compressed: &isJPEGCompressed, image: &isImage, mayTranscode: &mayTranscode)

        // Detection, enhanced reading and the thumbnail stack are
        // decided before a file leaves INCOMING. A zero-size or
        // unloadable image still crashes series icons; keep it
        // out of the indexed store and say why. The manufacturer
        // is not consulted - the same gate applies to any vendor.
        if isDicomFile {
            let stack = EnhancedImportTriage.assessPath(srcPath)
            let ivus = IVUSImportTriage.assessPath(srcPath)
            var mayMerge = stack.mayMergeIntoIncoming
            var why = (stack.recordedError as NSString?)?.length ?? 0 != 0 ? stack.recordedError! : "the pixel/thumbnail stack cannot load this object"
            // IVUS/US objects decide for themselves: Implicit VR
            // Volcano-shaped cines that the Enhanced parser does
            // not read still have a size and a diagnosis here.
            // A file this gate does not apply to keeps the
            // Enhanced answer. The manufacturer is not consulted.
            if ivus.appliesToFile {
                mayMerge = ivus.mayMergeIntoIncoming
                why = (ivus.recordedError as NSString?)?.length ?? 0 != 0 ? ivus.recordedError! : "the thumbnail stack cannot load this IVUS/US object"
            }
            if mayMerge == false {
                self.addImportRefusalSummary(String(format: "%@: %@", lastPathComponent, why))
                NSLog("---- import: %@ not merged into the incoming index (%@)", lastPathComponent, why)
                let kept = availablePath(inDirectory: self.errorsDirPath(), name: lastPathComponent)
                if let moveError = moveItem(srcPath, kept) {
                    NSLog("---- import: %@ could not be kept aside (%@); it stays in incoming", lastPathComponent, moveError.localizedDescription)
                }
                return
            }
        }

        // NRRD is recognised and not read: nothing fills a record
        // or pixels from it. Let through this door it was moved
        // in, found unreadable and deleted. It is kept aside
        // instead, whatever DELETEFILELISTENER says.
        if isDicomFile == false && DicomFile.isNRRDFile(srcPath) {
            self.addImportRefusalSummary(String(format: NSLocalizedString("%@ is not a DICOM file this database can index", comment: ""), lastPathComponent))
            let kept = availablePath(inDirectory: self.errorsDirPath(), name: lastPathComponent)
            if let moveError = moveItem(srcPath, kept) {
                NSLog("---- import: %@ is NRRD, which this application does not read, and could not be kept aside (%@); it stays in incoming",
                      lastPathComponent, moveError.localizedDescription)
            } else {
                NSLog("---- import: %@ is NRRD, which this application does not read; kept in %@", lastPathComponent, ((self.errorsDirPath() ?? "") as NSString).lastPathComponent)
            }
            return
        }

        // A database that indexes anything readable takes the
        // formats the raster reader handles as well: -getImageFile
        // reads png, jpg, jp2, pdf, pct and gif beside tiff, and
        // refusing them at the door meant a valid PNG or PDF never
        // reached it. When only DICOM is indexed they are left
        // alone, rather than moved in and thrown away.
        let indexesAnything = !UserDefaults.standard.bool(forKey: "onlyDICOM")

        // NIfTI belongs in this list because DCMPix reads it.
        // Leaving it out meant a valid .nii
        // dropped into the incoming folder was called "not a DICOM
        // file this database can index" and, with DELETEFILELISTENER,
        // deleted - a file the viewer can open, destroyed on arrival.
        // A header with its image beside it is a pair, NIfTI or Analyze 7.5
        // (which has no magic for -isNIfTIFile: to find); the reader decides.
        let pairedImage = HeaderImagePair.imagePath(forHeader: srcPath)

        let takesFile = IncomingScanRules.takesFile(
            isDICOM: isDicomFile,
            readableOtherwise: {
                DicomFile.isFVTiffFile(srcPath) || DicomFile.isTiffFile(srcPath) || DicomFile.isNIfTIFile(srcPath) ||
                    pairedImage != nil || (indexesAnything && DicomFile.isImageFile(srcPath))
            },
            destinationTaken: { DicomDatabaseObjC.fileExists(dstPath) })

        if takesFile {
            if isDicomFile && isImage.boolValue {
                if IncomingScanRules.queuesForConversion(mayTranscode: mayTranscode.boolValue, isCompressed: isJPEGCompressed.boolValue,
                                                         listenerCompressionSettings: Int(listenerCompressionSettings),
                                                         needsCompression: { needsCompression(srcPath) }) {
                    // A name of its own in the decompression folder, and
                    // queued only once it is there: the second 1.dcm of
                    // a scan used to stay behind for the next scan while
                    // its path went to the helper, which then found
                    // nothing to read.
                    let compressedPath = availablePath(inDirectory: self.decompressionDirPath(), name: lastPathComponent)
                    if let moveError = moveItem(srcPath, compressedPath) {
                        NSLog("---- import: %@ could not be moved to the decompression folder (%@); it stays here and is tried again on the next scan", lastPathComponent, moveError.localizedDescription)
                    } else if let compressedPath {
                        compressedPathArray.append(compressedPath)
                        if let enclosingArchive {
                            ArchiveImportLedger.shared.recordQueuedEntry(inArchive: enclosingArchive)
                        }
                    }
                    return
                }

                dstPath = self.uniquePathForNewDataFile(withExtension: "dcm")
            } else {
                dstPath = self.uniquePathForNewDataFile(withExtension: ((srcPath as NSString).pathExtension as NSString).lowercased)
            }

            var result: Bool

            if isAlias {
                result = (try? dstPath.map { try FileManager.default.copyItem(atPath: srcPath, toPath: $0) }) != nil && dstPath != nil
                removeItem(originalPath)
                if result, let pairedImage, let dstPath {
                    try? FileManager.default.copyItem(atPath: pairedImage, toPath: HeaderImagePair.imagePath(besideStoredHeader: dstPath))
                    removeItem(HeaderImagePair.imagePath(besideStoredHeader: originalPath))
                }
            } else {
                result = moveItem(srcPath, dstPath) == nil
                if result, let pairedImage, let dstPath {
                    _ = moveItem(pairedImage, HeaderImagePair.imagePath(besideStoredHeader: dstPath))
                }
            }

            if result, let dstPath {
                // A file that is not DICOM has no identity but
                // its name, and the copy above replaced it with
                // a number. -[DicomFile getImageFile] makes the
                // study and the series out of that name, so
                // every raster file came out with the same
                // empty stem and they all fell into one series.
                if isDicomFile == false {
                    ImportedFileNames.remember(lastPathComponent, forPath: dstPath)
                }

                filesArray.add(dstPath)
                if let enclosingArchive {
                    ArchiveImportLedger.shared.recordIndexedEntry(inArchive: enclosingArchive)
                }
            }
        } else { // DELETE or MOVE THIS UNKNOWN FILE ?
            // Every file that arrives ends either as a study or
            // as a refusal that says so. This branch used to be
            // silent, so a file that was accepted by whatever
            // put it here simply disappeared.
            // An archive the decompression helper could not expand
            // is handed back under this name, so that it is
            // reported here instead of being left in a folder
            // nothing reads. The helper's own diagnosis goes to
            // its stderr, which the application does not capture,
            // so say here what the file actually was.
            if (lastPathComponent as NSString).pathExtension == "horos-unexpanded" {
                NSLog("---- import: %@ could not be expanded as an archive", (lastPathComponent as NSString).deletingPathExtension)
            }

            // The scan refuses a file before it ever reaches
            // -addFilesAtPaths:, so it has to report for itself, or
            // the window says nothing about the file that was
            // dropped - which is what "rejected with no visible
            // error" means to the person who sent it.
            self.addImportRefusalSummary(String(format: NSLocalizedString("%@ is not a DICOM file this database can index", comment: ""), lastPathComponent))

            if UserDefaults.standard.bool(forKey: "DELETEFILELISTENER") {
                NSLog("---- import: %@ is not a DICOM file this database can index; deleted (DELETEFILELISTENER)", lastPathComponent)
                removeItem(srcPath)
                if let enclosingArchive {
                    ArchiveImportLedger.shared.recordDeletedEntry(inArchive: enclosingArchive)
                }
            } else {
                let kept = availablePath(inDirectory: self.errorsDirPath(), name: lastPathComponent)
                if let moveError = moveItem(srcPath, kept) {
                    NSLog("---- import: %@ is not a DICOM file this database can index, and could not be kept (%@); deleted", lastPathComponent, moveError.localizedDescription)
                    removeItem(srcPath)
                    if let enclosingArchive {
                        ArchiveImportLedger.shared.recordDeletedEntry(inArchive: enclosingArchive)
                    }
                } else {
                    NSLog("---- import: %@ is not a DICOM file this database can index; kept in %@", lastPathComponent, ((self.errorsDirPath() ?? "") as NSString).lastPathComponent)
                    if let enclosingArchive {
                        ArchiveImportLedger.shared.recordKeptEntry(inArchive: enclosingArchive)
                    }
                }
            }
        }
    }

    func importFilesFromIncomingDirThread() {
        autoreleasepool {
            let lock = importFilesFromIncomingDirLock
            lock?.lock()
            if let exception = DicomDatabaseObjC.attempt({
                var importCount = 0
                if self.hasFilesToImport() {
                    let thread = Thread.current
                    thread.name = NSLocalizedString("Adding incoming files...", comment: "")
                    thread.enterOperation()
                    // Indexed by a context on its own queue, on that queue.
                    let worker = self.privateQueueIndependentDatabase() as? DicomDatabase
                    var imported = 0
                    worker?.performBlockAndWait {
                        imported = worker?.importFiles(fromIncomingDir: NSNumber(value: true)) ?? 0
                    }
                    importCount = imported
                    thread.exitOperation()
                    thread.status = NSLocalizedString("Finishing...", comment: "")
                    thread.progress = -1
                }
                let theDatabase = self.isMainDatabase() ? self : (self.mainDatabase as? DicomDatabase)
                if theDatabase === DicomDatabase.activeLocal() {
                    let newBadge: String? = importCount != 0 ? NSNumber(value: importCount).stringValue : nil

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if !DicomDatabaseObjC.isEqual(newBadge, NSApp.dockTile.badgeLabel) {
                                AppController.shared()?.setBadgeLabel(newBadge)
                            }
                        }
                    }
                }
            }) {
                DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase importFilesFromIncomingDirThread]")
            }
            lock?.unlock()
        }
    }

    func initiateImportFilesFromIncomingDirUnlessAlreadyImporting() {
        //if ([[AppController sharedAppController] isSessionInactive])
        //	return;

        if Thread.isMainThread == false {
            self.performSelector(onMainThread: #selector(DicomDatabase.initiateImportFilesFromIncomingDirUnlessAlreadyImporting), with: nil, waitUntilDone: false)
            return
        }

        if IncomingImportGate.shared.isStopped {
            return
        }

        if ViewerController.areLoadingViewers() { //Don't try to do everything at the same time... we are not in a hurry for checking the incoming dir, preserve the user experience !
            return
        }

        if let lock = importFilesFromIncomingDirLock, lock.try() {
            if let exception = DicomDatabaseObjC.attempt({
                self.updateStorageAvailabilityWarning()
                self.performSelector(inBackground: #selector(DicomDatabase.importFilesFromIncomingDirThread), with: nil)
            }) {
                DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase initiateImportFilesFromIncomingDirUnlessAlreadyImporting]")
            }
            lock.unlock()
        }
    }

    @objc(importFilesFromIncomingDirTimerCallback:)
    private class func importFilesFromIncomingDirTimerCallback(_ timer: Timer) {
        for case let dbi as DicomDatabase in self.allDatabases() ?? [] where dbi.isLocal() {
            dbi.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
        }
    }

    class func syncImportFilesFromIncomingDirTimerWithUserDefaults() {
        let newInterval = UserDefaults.standard.integer(forKey: "LISTENERCHECKINTERVAL")
        if (importFilesFromIncomingDirTimer?.timeInterval ?? 0) == TimeInterval(newInterval) {
            return
        }

        importFilesFromIncomingDirTimer?.invalidate()
        importFilesFromIncomingDirTimer = nil
        if newInterval != 0 {
            let timer = Timer(timeInterval: TimeInterval(newInterval), target: self,
                              selector: #selector(DicomDatabase.importFilesFromIncomingDirTimerCallback(_:)), userInfo: nil, repeats: true)
            importFilesFromIncomingDirTimer = timer
            RunLoop.main.add(timer, forMode: .modalPanel)
            RunLoop.main.add(timer, forMode: .default)
        }
    }
}
