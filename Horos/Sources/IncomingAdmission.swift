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
import IsiXContracts
import IsiXDatabase
import IsiXPreferences
import IsiXStorage
import Synchronization

// The incoming folder the DICOM listener fills, and its scan. DatabaseIngest asks
// every local main database to import, which happens on a thread of its own, on a
// private-queue context, under the lock the main database shares with its
// independent databases. The scan moves what the database indexes into its data
// folder, archives and files to convert into the decompression folder, and keeps
// or deletes the rest, then indexes what it took through the single entry. Every
// import passes the gate quitting closes.

/// The archives that could not be moved to the decompression folder, said once each.
private let reportedUnmovableArchives = Mutex<Set<String>>([])

/// Whether an incoming file is DICOM in the Deflated Explicit VR Little Endian
/// transfer syntax, which the decompression helper inflates.
private func isDeflatedDICOM(_ file: DICOMTriageFile) -> Bool {
    #if !OSIRIX_LIGHT
    return file.isDeflated
    #else
    return false
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

/// The scan of the incoming folder of one database: what comes in through it,
/// file by file, on the calling thread and in the context of `database`.
///
/// Made by `DatabaseIngest.admission(of:)` for each use: what lasts between
/// scans is the database's own lock and folders, and the conversion queue. It
/// reads the application only through what it is given.
struct IncomingAdmission {
    private let database: DicomDatabase
    private let ingest: DatabaseIngest
    private let conversion: DatabaseFileConversion
    private let preferences: UserDefaults
    /// Shows on the Dock that files are arriving, or stops showing it. Any thread.
    private let showReceiving: (Bool) -> Void

    init(database: DicomDatabase, ingest: DatabaseIngest, conversion: DatabaseFileConversion, preferences: UserDefaults,
         showReceiving: @escaping (Bool) -> Void) {
        self.database = database
        self.ingest = ingest
        self.conversion = conversion
        self.preferences = preferences
        self.showReceiving = showReceiving
    }

    /// Where what the scan cannot keep goes: a name of its own in a folder,
    /// and the incoming folder again for what was not indexed.
    private var disposal: ImportDisposal {
        ImportDisposal(database: database)
    }

    func isVolumeFull() -> Bool {
        let currentTime = Date.timeIntervalSinceReferenceDate
        if currentTime - database.timeOfLastFreeSizeVerification > StorageFreeSpace.verificationInterval {
            // refresh freeSizeLimitReached
            let dataBasePathAttrs = database.dataBaseDirPath.flatMap { try? FileManager.default.attributesOfFileSystem(forPath: $0) }
            let dataBasePathSize = dataBasePathAttrs?[.systemSize] as? NSNumber
            let dataBasePathFreeSize = dataBasePathAttrs?[.systemFreeSize] as? NSNumber
            if let dataBasePathFreeSize, let dataBasePathSize {
                database.freeSizeLimitReached = StorageFreeSpace.isBelowLimit(sizeBytes: dataBasePathSize.uint64Value, freeBytes: dataBasePathFreeSize.uint64Value)
                database.timeOfLastFreeSizeVerification = currentTime

                if database.freeSizeLimitReached {
                    NSLog("Warning: the volume used to store data for %@ is full; queued incoming files are preserved and new DICOM transfers will be rejected", DicomDatabaseObjC.arg(database.name))
                }
            } else {
                return true
            }
        }

        return database.freeSizeLimitReached
    }

    func hasFilesToImport() -> Bool {
        let enumer = FileManager.default.enumerator(atPath: database.incomingDirPath(), limitTo: -1)
        return enumer.nextObject() != nil
    }

    /// Whether files are being imported or converted now, for a retrieve that
    /// must remain cancellable during a long import: this looks and never waits.
    /// What is waiting for the conversion counts from the moment the scan queued
    /// it, and what is being converted to the end of its batch, the import of
    /// what could not be converted included.
    var isInProgress: Bool {
        // Shared with the independent databases that do the work.
        if ingest.isPassRunning(over: database) {
            return true
        }
        // A synchronous import or a rebuild holds the lock without a pass.
        guard let importLock = database.importFilesFromIncomingDirLock, importLock.try() else { return true }
        importLock.unlock()
        guard let processLock = database.processFilesLock, processLock.try() else { return true }
        processLock.unlock()
        return conversion.isConverting
    }

    /// The compression the listener asks for now: none while a retrieval
    /// that needs its images at once is running.
    var listenerCompressionSettings: Int32 {
        Int32(truncatingIfNeeded: ListenerCompressionSuspension.shared.value(in: preferences))
    }

    // Every import of the folder passes the gate quitting closes: the process's
    // exit destroys DCMTK's dictionary and loggers, and an import still reading a
    // file then reads freed memory. ThreadsManager lists an import too late for
    // quitting to rely on it.
    func importFolder(showGUI: NSNumber!, listenerCompressionSettings: Int32) -> Int {
        // A closed index cannot take what arrives: moved to the data folder, a file
        // would be in no index. INCOMING stays the queue, as with the storage full.
        if database.managedObjectContext?.persistentStoreCoordinator?.persistentStores.isEmpty != false {
            return 0
        }
        guard let admission = IncomingImportGate.shared.admit(cancelling: Thread.current) else {
            return 0
        }
        var imported = 0
        let raised = HorosObjCException.caught {
            imported = importAdmittedFilesFromIncomingDir(showGUI, listenerCompressionSettings: listenerCompressionSettings)
        }
        IncomingImportGate.shared.leave(admission)
        if let raised { raised.raise() }
        return imported
    }

    // A scan reports for itself: whatever the last one refused stops being current
    // the moment a new one starts.
    private func importAdmittedFilesFromIncomingDir(_ showGUI: NSNumber?, listenerCompressionSettings: Int32) -> Int {
        var compressedPathArray: [String] = []
        var deflatedPathArray: [String] = []
        let thread = Thread.current
        var addedFilesCount = 0
        var activityFeedbackShown = false
        var listenerCompressionSettings = listenerCompressionSettings

        FileManager.default.confirmNoIndexDirectory(atPath: database.decompressionDirPath())

        let enumer = FileManager.default.enumerator(atPath: database.incomingDirPath(), limitTo: -1)

        var storageFull = false
        var scanFailed = false
        let lock = database.importFilesFromIncomingDirLock
        lock?.lock()
        if let exception = HorosObjCException.caught({
            if isVolumeFull() {
                database.cleanForFreeSpace()
                // Cleanup may have just freed space; do not reuse the pre-cleanup
                // capacity result cached for up to twenty seconds.
                database.timeOfLastFreeSizeVerification = 0
                if isVolumeFull() {
                    NSLog("Incoming import paused: database storage is full or unavailable; queued files are preserved")
                    storageFull = true
                    return
                }
            }

            let filesArray = NSMutableArray()
            #if OSIRIX_LIGHT
            listenerCompressionSettings = 0
            #endif

            FileManager.default.confirmNoIndexDirectory(atPath: database.dataDirPath())

            let maxNumberOfFiles = IncomingScanRules.maximumFiles(preference: preferences[DatabasePreferences.maxNumberOfFilesForCheckIncoming])

            let startTime = Date.timeIntervalSinceReferenceDate
            var start = startTime

            while filesArray.count < maxNumberOfFiles &&
                    Date.timeIntervalSinceReferenceDate - startTime < IncomingScanRules.scanDuration(checkInterval: preferences[NetworkPreferences.listenerCheckInterval]),
                  let pathname = enumer.nextObject() as? String {
                // Stopping here still returns what this pass already moved.
                if thread.isCancelled {
                    break
                }

                var srcPath = DicomDatabaseObjC.appending(database.incomingDirPath(), pathname) ?? pathname
                let originalPath = srcPath
                let lastPathComponent = (srcPath as NSString).lastPathComponent

                // An archive is expanded into a directory of its own name inside this
                // folder, and its entries are then imported one by one - here, and
                // possibly over several scans. Each entry says what became of it; the
                // running tally is what lets the archive itself say so too.
                let enclosingArchiveComponent = ArchiveImportLedger.archiveComponent(ofRelativePath: pathname)
                let enclosingArchive = enclosingArchiveComponent.flatMap { DicomDatabaseObjC.appending(database.incomingDirPath(), $0) }

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
                    showReceiving(true)
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
                                NSLog("---- import: %@", ArchiveImportLedger.shared.verdictForArchive(srcPath, keptDirectoryName: ((database.errorsDirPath() ?? "") as NSString).lastPathComponent))
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
                    if unpackWADORSMultipart(srcPath, enclosingArchive: enclosingArchive) {
                        continue
                    }

                    let triageFile = DICOMTriageFile(path: srcPath)
                    if ArchiveImportLedger.isArchiveName(srcPath) {
                        // A name of its own there: files of the same name come from
                        // different folders of INCOMING.
                        let compressedPath = disposal.availablePath(inDirectory: database.decompressionDirPath(), name: lastPathComponent)
                        if let moveError = moveItem(srcPath, compressedPath) {
                            // It stays here and is retried on every scan - which
                            // is what makes it recoverable once the cause is
                            // fixed - so say it once per file rather than once
                            // per scan, and once rather than not at all.
                            if reportedUnmovableArchives.withLock({ $0.insert(srcPath).inserted }) {
                                NSLog("---- import: %@ could not be moved to the decompression folder (%@); it stays here and is tried again on the next scan", lastPathComponent, moveError.localizedDescription)
                            }
                        } else if let compressedPath {
                            compressedPathArray.append(compressedPath)
                            if let enclosingArchive {
                                ArchiveImportLedger.shared.recordNestedArchive(inArchive: enclosingArchive)
                            }
                        }
                    } else if isDeflatedDICOM(triageFile) {
                        // Deflated Explicit VR Little Endian: nothing on this side
                        // reads the dataset, and it used to be refused as "not
                        // DICOM" - and deleted with DELETEFILELISTENER.
                        // The decompression helper inflates it to Explicit VR Little
                        // Endian and puts it back here, whatever the listener's
                        // compression setting, as it does for an archive.
                        let compressedPath = disposal.availablePath(inDirectory: database.decompressionDirPath(), name: lastPathComponent)
                        if let moveError = moveItem(srcPath, compressedPath) {
                            NSLog("---- import: %@ is deflated and could not be moved to the decompression folder (%@); it stays here and is tried again on the next scan", lastPathComponent, moveError.localizedDescription)
                        } else if let compressedPath {
                            deflatedPathArray.append(compressedPath)
                            if let enclosingArchive {
                                ArchiveImportLedger.shared.recordQueuedEntry(inArchive: enclosingArchive)
                            }
                        }
                    } else {
                        takeIncomingFile(srcPath, triageFile: triageFile, originalPath: originalPath, lastPathComponent: lastPathComponent, isAlias: isAlias,
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
                        if let exception = HorosObjCException.caught({
                            PluginManager.startProtectForCrash(withFilter: filter)
                            _ = (filter as AnyObject).perform(NSSelectorFromString("processFiles:"), with: filesArray)
                            PluginManager.endProtectForCrash()
                        }) {
                            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase importAdmittedFilesFromIncomingDir:listenerCompressionSettings:]")
                        }
                    }
                }

                thread.status = String(format: NSLocalizedString("Processing %@...", comment: ""), DicomDatabaseObjC.localizedFileCount(filesArray.count))

                var addedFiles: [Any]? = nil
                var unindexedFiles: [String] = []
                if thread.isCancelled == false {
                    (addedFiles, unindexedFiles) = ingest.indexReturningIDs(Array(filesArray), preset: .incoming, in: database) // these are IDs!
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
                    disposal.returnFilesToIncomingDir((filesArray as? [String]) ?? [])
                } else if unindexedFiles.count != 0 { // cancelled part way
                    disposal.returnFilesToIncomingDir(unindexedFiles)
                }
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase importAdmittedFilesFromIncomingDir:listenerCompressionSettings:]")
            scanFailed = true
        }
        // @finally, but for the lock: what the scan moved aside is queued while the
        // lock is held, so nobody finds this folder at rest with files on their way
        // to the conversion.
        if activityFeedbackShown {
            showReceiving(false)
        }
        let finishing = HorosObjCException.caught {
            guard !storageFull else { return }

            // A cancelled pass starts no decompression: quitting is what cancels it,
            // and it empties the decompression folder.
            if thread.isCancelled {
                disposal.returnFilesToIncomingDir(deflatedPathArray)
                disposal.returnFilesToIncomingDir(compressedPathArray)
                return
            }

            // A scan that raised stopped where the same file will stop the next one:
            // what is left waits for the timer, or the passes would follow each other
            // without end.
            if !scanFailed, enumer.nextObject() != nil { // there is more data
                ingest.requestImport(of: database)
            }

            #if !OSIRIX_LIGHT
            if !deflatedPathArray.isEmpty { // deflated files are inflated whatever the compression setting
                conversion.convertScanned(deflatedPathArray, mode: .decompress)
            }

            // Files to compress or decompress in the decompression dir;
            // listenerCompressionSettings == 0 decompresses, for zip support.
            if !compressedPathArray.isEmpty, let mode = IncomingScanRules.conversion(forListenerCompressionSettings: Int(listenerCompressionSettings)) {
                conversion.convertScanned(compressedPathArray, mode: mode)
            }
            #endif
        }
        lock?.unlock()
        finishing?.raise()

        return storageFull ? 0 : addedFilesCount
    }

    /// A WADO-RS response saved whole into the incoming folder: its DICOM parts
    /// are written as files of their own beside it, and it goes. Whether it was one.
    private func unpackWADORSMultipart(_ srcPath: String, enclosingArchive: String?) -> Bool {
        //if file not available for reading, do nothing
        guard let file = FileHandle(forReadingAtPath: srcPath) else { return false }
        defer { file.closeFile() }

        var data = file.readData(ofLength: WADORSMultipart.probeLength)
        guard WADORSMultipart.announcesDICOMParts(data) else { return false }
        //read the rest of file
        data.append(file.readDataToEndOfFile())

        let name = (srcPath as NSString).lastPathComponent
        let unpacked = WADORSMultipart.unpack(data, keepAside: {
            moveItem(srcPath, disposal.availablePath(inDirectory: database.errorsDirPath(), name: name)) == nil
        }, write: { part in
            DicomDatabaseObjC.appending(database.incomingDirPath(), UUID().uuidString).map { (part as NSData).write(toFile: $0, atomically: false) } ?? false
        })
        switch unpacked {
        case .notSplit:
            return false
        case .split:
            // This file no longer exists: continuing would test a missing path
            // and report it as unreadable.
            removeItem(srcPath)
            if let enclosingArchive { ArchiveImportLedger.shared.recordIndexedEntry(inArchive: enclosingArchive) }
        case .keptAside:
            database.addImportRefusalSummary(String(format: NSLocalizedString("%@ is not a DICOM file this database can index", comment: ""), name))
            if let enclosingArchive { ArchiveImportLedger.shared.recordKeptEntry(inArchive: enclosingArchive) }
        case .stays:
            NSLog("---- import: %@ is a multipart that could not be read whole nor kept aside; it stays here", name)
        }
        return true
    }

    /// A file of the incoming folder that is neither an archive nor deflated:
    /// moved into the database folder if the database indexes it, to the
    /// decompression folder if the listener converts it, kept aside or deleted
    /// otherwise.
    private func takeIncomingFile(_ srcPath: String, triageFile: DICOMTriageFile, originalPath: String, lastPathComponent: String, isAlias: Bool, enclosingArchive: String?,
                                  listenerCompressionSettings: Int32, filesArray: NSMutableArray, compressedPathArray: inout [String]) {
        var isJPEGCompressed: ObjCBool = false, isImage: ObjCBool = false, mayTranscode: ObjCBool = false
        var dstPath = DicomDatabaseObjC.appending(database.dataDirPath(), lastPathComponent)

        let isDicomFile = DicomFile.isDICOMFile(srcPath, compressed: &isJPEGCompressed, image: &isImage, mayTranscode: &mayTranscode)

        // Detection, enhanced reading and the thumbnail stack are
        // decided before a file leaves INCOMING. A zero-size or
        // unloadable image still crashes series icons; keep it
        // out of the indexed store and say why. The manufacturer
        // is not consulted - the same gate applies to any vendor.
        if isDicomFile {
            let stack = EnhancedImportTriage.assess(triageFile)
            let ivus = IVUSImportTriage.assess(triageFile)
            // IVUS/US objects decide for themselves: Implicit VR
            // Volcano-shaped cines that the Enhanced parser does
            // not read still have a size and a diagnosis here.
            // The manufacturer is not consulted.
            if let why = IncomingScanRules.triageRefusal(stackMayMerge: stack.mayMergeIntoIncoming, stackError: stack.recordedError,
                                                         ivusApplies: ivus.appliesToFile, ivusMayMerge: ivus.mayMergeIntoIncoming, ivusError: ivus.recordedError) {
                database.addImportRefusalSummary(String(format: "%@: %@", lastPathComponent, why))
                NSLog("---- import: %@ not merged into the incoming index (%@)", lastPathComponent, why)
                let kept = disposal.availablePath(inDirectory: database.errorsDirPath(), name: lastPathComponent)
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
            database.addImportRefusalSummary(String(format: NSLocalizedString("%@ is not a DICOM file this database can index", comment: ""), lastPathComponent))
            let kept = disposal.availablePath(inDirectory: database.errorsDirPath(), name: lastPathComponent)
            if let moveError = moveItem(srcPath, kept) {
                NSLog("---- import: %@ is NRRD, which this application does not read, and could not be kept aside (%@); it stays in incoming",
                      lastPathComponent, moveError.localizedDescription)
            } else {
                NSLog("---- import: %@ is NRRD, which this application does not read; kept in %@", lastPathComponent, ((database.errorsDirPath() ?? "") as NSString).lastPathComponent)
            }
            return
        }

        // A database that indexes anything readable takes the
        // formats the raster reader handles as well: -getImageFile
        // reads png, jpg, jp2, pdf, pct and gif beside tiff, and
        // refusing them at the door meant a valid PNG or PDF never
        // reached it. When only DICOM is indexed they are left
        // alone, rather than moved in and thrown away.
        let indexesAnything = !preferences[DatabasePreferences.onlyDICOM]

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
                                                         needsCompression: { DatabaseFileConversion.isWorthCompressing(srcPath) }) {
                    // A name of its own in the decompression folder, and
                    // queued only once it is there: the second 1.dcm of
                    // a scan used to stay behind for the next scan while
                    // its path went to the helper, which then found
                    // nothing to read.
                    let compressedPath = disposal.availablePath(inDirectory: database.decompressionDirPath(), name: lastPathComponent)
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

                dstPath = database.uniquePathForNewDataFile(withExtension: "dcm")
            } else {
                dstPath = database.uniquePathForNewDataFile(withExtension: ((srcPath as NSString).pathExtension as NSString).lowercased)
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
            if IncomingScanRules.isUnexpandedArchive(named: lastPathComponent) {
                NSLog("---- import: %@ could not be expanded as an archive", (lastPathComponent as NSString).deletingPathExtension)
            }

            // The scan refuses a file before it ever reaches
            // -addFilesAtPaths:, so it has to report for itself, or
            // the window says nothing about the file that was
            // dropped - which is what "rejected with no visible
            // error" means to the person who sent it.
            database.addImportRefusalSummary(String(format: NSLocalizedString("%@ is not a DICOM file this database can index", comment: ""), lastPathComponent))

            if preferences[DatabasePreferences.deletesListenerFiles] {
                NSLog("---- import: %@ is not a DICOM file this database can index; deleted (DELETEFILELISTENER)", lastPathComponent)
                removeItem(srcPath)
                if let enclosingArchive {
                    ArchiveImportLedger.shared.recordDeletedEntry(inArchive: enclosingArchive)
                }
            } else {
                let kept = disposal.availablePath(inDirectory: database.errorsDirPath(), name: lastPathComponent)
                if let moveError = moveItem(srcPath, kept) {
                    NSLog("---- import: %@ is not a DICOM file this database can index, and could not be kept (%@); deleted", lastPathComponent, moveError.localizedDescription)
                    removeItem(srcPath)
                    if let enclosingArchive {
                        ArchiveImportLedger.shared.recordDeletedEntry(inArchive: enclosingArchive)
                    }
                } else {
                    NSLog("---- import: %@ is not a DICOM file this database can index; kept in %@", lastPathComponent, ((database.errorsDirPath() ?? "") as NSString).lastPathComponent)
                    if let enclosingArchive {
                        ArchiveImportLedger.shared.recordKeptEntry(inArchive: enclosingArchive)
                    }
                }
            }
        }
    }

}

extension DatabaseIngest {
    /// The scan of the incoming folder of `database`.
    func admission(of database: DicomDatabase) -> IncomingAdmission {
        let processGraph = processGraph
        return IncomingAdmission(database: database, ingest: self, conversion: fileConversion(of: database),
                                 preferences: processGraph.preferences,
                                 showReceiving: { processGraph.showReceiving($0) })
    }
}

// The selectors of the contract and the methods a remote database overrides.
@objc(IncomingImport) @implementation extension DicomDatabase {

    func isFileSystemFreeSizeLimitReached() -> Bool {
        return DatabaseIngest.process.admission(of: self).isVolumeFull()
    }

    func hasFilesToImport() -> Bool {
        return DatabaseIngest.process.admission(of: self).hasFilesToImport()
    }

    var incomingImportInProgress: Bool {
        return DatabaseIngest.process.admission(of: self).isInProgress
    }

    func importFilesFromIncomingDir() -> Int {
        return self.importFiles(fromIncomingDir: NSNumber(value: false))
    }

    func importFiles(fromIncomingDir showGUI: NSNumber!) -> Int {
        return self.importFiles(fromIncomingDir: showGUI, listenerCompressionSettings: DatabaseIngest.process.admission(of: self).listenerCompressionSettings)
    }

    func importFiles(fromIncomingDir showGUI: NSNumber!, listenerCompressionSettings: Int32) -> Int {
        return DatabaseIngest.process.admission(of: self).importFolder(showGUI: showGUI, listenerCompressionSettings: listenerCompressionSettings)
    }

    func importFilesFromIncomingDirThread() {
        DatabaseIngest.process.runPass(over: self)
    }

    func initiateImportFilesFromIncomingDirUnlessAlreadyImporting() {
        DatabaseIngest.process.schedulePass(over: self)
    }

    class func syncImportFilesFromIncomingDirTimerWithUserDefaults() {
        DatabaseIngest.process.syncTimerWithPreferences()
    }
}
