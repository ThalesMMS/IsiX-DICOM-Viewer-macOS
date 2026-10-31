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

// The scan of a medium, a disc or a folder mounted as one. Its DICOMDIR is read
// first (DicomdirReader.swift); then, as the preferences say, the medium itself;
// the files found are indexed, and copied into the database or browsed where
// they are, as the user chooses. What the scan decides without reading a file is
// IsiXDatabase's MediaScanRules.

/// The scan's questions to the user. Each waits for the answer, so a scan asks
/// with nothing held: the main thread may be waiting for its database's queue.
/// They come from the main run loop, since a modal inside the main queue would
/// stop that queue until someone answers.
struct MediaScanQuestions: Sendable {
    let ingest: DatabaseIngest

    /// Whether Command is down in the event the main thread has at hand.
    func commandIsDown() -> Bool {
        onMainRunLoopSync { NSApp.currentEvent?.modifierFlags.contains(.command) ?? false }
    }

    /// Copy the disc's images, browse them or ignore them: a MOUNT mode.
    func whatToDo(withMedium path: String, instances: Int) -> Int {
        onMainRunLoopSync {
            let dialog = DiscMountedAskTheUserDialogController(mountedPath: path, dicomFilesCount: instances)
            dialog.window?.center()

            if let window = dialog.window { NSApp.runModal(for: window) }

            let choice = dialog.choice

            dialog.window?.close()
            return choice
        }
    }

    /// Asks for the password of a ZIP archive until it opens or the user cancels.
    func expand(protectedArchive archive: String, into destination: String) {
        let ingest = ingest
        onMainRunLoopSync {
            _ = ingest.browser?.askForZIPPassword(archive, destination: destination)
        }
    }
}

/// One scan of a medium, on the calling thread: a volume, or a folder an archive
/// on it expanded into. `database` holds what the scan indexes, and only the
/// indexing and the reading of its objects enter its queue: nothing that waits
/// for a person or for the main thread runs there.
struct MediaVolumeScan {
    let database: DicomDatabase
    let path: String
    let isVolume: Bool
    let ingest: DatabaseIngest
    let questions: MediaScanQuestions

    /// Whether the medium's source should be selected: it holds images that
    /// were not ignored or ejected. False when quitting refuses the scan.
    func run() -> Bool {
        ingest.whileAdmitted { scanned() } ?? false
    }

    private func scanned() -> Bool {
        let thread = Thread.current
        thread.enterOperation()
        defer { thread.exitOperation() }

        let preferences = PreferencesSource.process.preferences
        var images: [NSManagedObjectID] = []

        // "Minutes per image" is the report, and one elapsed time cannot say which
        // part of the import spent them. Listing the medium, reading its index,
        // opening every file to see whether it is DICOM, parsing and indexing the
        // ones that are, and copying them into the database are five different
        // things, slow for five different reasons. They are timed apart.
        let timing = MediaScanTiming(medium: (path as NSString).lastPathComponent)

        thread.status = NSLocalizedString("Scanning directories...", comment: "")
        timing.begin("listing")
        let listed = FileManager.default.enumerator(atPath: path, filesOnly: true).allObjects.compactMap { $0 as? String }
        let allpaths = NSMutableArray(array: (path as NSString).strings(byAppendingPaths: listed))
        timing.end("listing", count: allpaths.count, noun: "file")
        let pathsToScanAnyway = NSMutableArray()

        // first read the DICOMDIR file
        let usesDicomdir = preferences[DatabasePreferences.usesDICOMDIRFile]
        if usesDicomdir {
            thread.status = NSLocalizedString("Looking for DICOMDIR...", comment: "")
            let listedPaths = allpaths.compactMap { $0 as? String }
            if let dicomdirPath = MediaScanRules.dicomdir(in: listedPaths) {
                NSLog("(scanAtPath): Scanning DICOMDIR at %@", dicomdirPath)
                thread.status = NSLocalizedString("Reading DICOMDIR...", comment: "")

                timing.begin("reading the index for")
                // The reader has DCMTK's refusals as errors and raises nothing;
                // the index is written by Core Data, which raises.
                let index = DicomdirReader().read(at: dicomdirPath, withPaths: listedPaths)
                pathsToScanAnyway.addObjects(from: index.pathsToScanAnyway)
                HorosObjCException.logged("-[DicomDatabase(Scan) scanAtPath:isVolume:]", stack: true) {
                    images = self.indexing(entries: index.entries)
                }
                timing.end("reading the index for", count: images.count, noun: "instance")
            }
        }

        // What the index accounted for. A DICOMDIR is supposed to name every
        // instance on the medium; some name fewer. Trusting it and stopping there
        // left eight of twelve instances on a disc that was then ejected, with
        // nothing said - so the disc is read as well, and only the files the index
        // already brought in are skipped.
        let indexedPaths = NSMutableSet()
        for indexed in filesOf(images) {
            if let indexed = indexed as? String { indexedPaths.add(indexed) }
        }

        let namedByIndex = images.count

        let doScan = MediaScanRules.readsMedium(usesDicomdir: usesDicomdir, namedByIndex: namedByIndex,
                                                readIfIndexIsEmpty: preferences[DatabasePreferences.scanDiskIfDICOMDIRZero],
                                                readBeyondIndex: preferences[DatabasePreferences.scanDiskBeyondDICOMDIR])

        if pathsToScanAnyway.count != 0 || doScan {
            let dicomFilePaths = NSMutableArray(array: pathsToScanAnyway)
            // Files the loop below actually opened. Saying it read everything on the
            // medium would be wrong on a disc whose index already named most of it,
            // and that is exactly the disc whose timing is in question.
            var examined = 0

            // And the ones it opened and would not take. This is where a damaged
            // medium loses its files: they never reach addFilesAtPaths:, because
            // isDICOMFile: has already said no. Measured on a disc carrying five
            // broken files, four were dropped here without a word.
            let refusals = ImportRefusals(considered: 0)

            if doScan {
                thread.status = NSLocalizedString("Looking for DICOM files...", comment: "")
                thread.supportsCancel = true
                timing.begin("reading")

                var start = Date.timeIntervalSinceReferenceDate
                for i in 0..<allpaths.count {
                    if Date.timeIntervalSinceReferenceDate - start > 0.5 || i == allpaths.count - 1 {
                        thread.progress = CGFloat(1.0 * Double(i) / Double(allpaths.count))
                        start = Date.timeIntervalSinceReferenceDate
                    }

                    let path = allpaths.object(at: i) as! String

                    if dicomFilePaths.contains(path) { continue }
                    if indexedPaths.contains(path) { continue }
                    if MediaScanRules.skipsWhenScanning(path) { continue }

                    examined += 1

                    if DicomFile.isDICOMFile(path) {
                        // avoid DICOMDIR files
                        if !MediaScanRules.isDicomdirName(path) {
                            dicomFilePaths.add(path)
                        }
                    } else if ArchiveImportLedger.isArchiveName(path) {
                        thread.enterOperation()
                        thread.status = NSLocalizedString("Processing ZIP file...", comment: "")

                        // One archive must not be able to take the medium down with
                        // it. This asked tmpFilePathInDir: for a place to expand
                        // into and then made a directory there - and mkstemp creates
                        // the file, so confirmDirectoryAtPath: found a file in its
                        // way and raised. The exception left scanAtPath: through its
                        // @throw, so a disc carrying any ZIP imported nothing at all:
                        //   NSGenericException (in -[MountedDatabaseNodeIdentifier
                        //   volumeScanThread]): Cannot create directory: an existing
                        //   file occupies /private/var/folders/...
                        // A temporary directory is asked for now, and whatever else
                        // an archive manages to raise is caught here.
                        if let exception = HorosObjCException.caught({
                            let tempPath = FileManager.default.tmpDirectoryPath(inDir: self.database.tempDirPath())

                            if !BrowserController.unzipFile(path, withPassword: nil, destination: tempPath,
                                                            showGUI: true, terminationStatus: nil) { // needs password
                                self.questions.expand(protectedArchive: path, into: tempPath)
                            }

                            _ = MediaVolumeScan(database: self.database, path: tempPath, isVolume: false,
                                                ingest: self.ingest, questions: self.questions).run()
                        }) {
                            NSLog("(scanAtPath): %@ could not be expanded (%@); the rest of the medium is still read",
                                  (path as NSString).lastPathComponent, exception.reason ?? "")
                        }
                        thread.exitOperation()
                    } else {
                        refusals.refuse(path)
                    }

                    if thread.isCancelled {
                        return false
                    }
                }
            }

            let foundByScan = dicomFilePaths.count
            timing.end("reading", count: examined, noun: "file")

            refusals.considered = examined
            if refusals.count != 0 {
                NSLog("(scanAtPath): %@: %@", (path as NSString).lastPathComponent, refusals.summary)
            }

            timing.begin("indexing")
            images += indexing(files: dicomFilePaths.map { $0 })
            timing.end("indexing", count: foundByScan, noun: "file")

            // What the medium holds, what its index named, and what is actually
            // going to be taken off it. A disc is ejected after this, so the three
            // numbers are the only record of what was left behind.
            NSLog("(scanAtPath): %@: %lu file(s) on the medium, %lu named by the index, %lu more found by reading it, %lu instance(s) to take",
                  (path as NSString).lastPathComponent, allpaths.count, namedByIndex, foundByScan, images.count)
        }

        if images.isEmpty {
            return false
        }

        var mode = preferences[DatabasePreferences.mountAction]

        if MediaScanRules.asksWhatToDo(mountMode: mode, commandDown: !thread.isCancelled && questions.commandIsDown()) {
            mode = questions.whatToDo(withMedium: path, instances: images.count)
        }

        if mode == MediaScanRules.copyMode {
            // copy into database on mount
            let paths = pathsToCopy(images)

            thread.supportsCancel = true
            timing.begin("copying")

            // On this thread, so that cancelling it stops the copy, and what the
            // copy reports shows on it. The copy indexes on a private-queue
            // context of its own.
            let copy = copying(paths)

            thread.supportsCancel = false // why now?

            // A copy that was stopped part way did not copy the files it was given,
            // and saying "copying 1200 files" of it would be a claim. How many did
            // arrive is the copy's to report, and it does.
            if copy.stopped {
                timing.end("copying")
                NSLog("(scanAtPath): %@: the copy was stopped before it finished",
                      (path as NSString).lastPathComponent)
            } else {
                timing.end("copying", count: paths.count, noun: "file")
            }

            // Where the import spent its time, and what one instance of this medium
            // cost. Written before the eject, like the tally above it.
            NSLog("(scanAtPath): %@ (%@)", timing.summary, timing.perInstance(images.count))

            // Only a copy that finished is a copy that can be ejected after: it
            // has returned here, whatever it took.
            if MediaScanRules.ejectsAfterCopy(isVolume: isVolume, ejectPreference: preferences[DatabasePreferences.ejectsMediaAfterAutoCopy],
                                              copyStopped: copy.stopped) {
                eject(thread)
                return false
            }
        } else {
            // Nothing is copied when the medium is only being browsed, so the
            // report is written here instead.
            NSLog("(scanAtPath): %@ (%@)", timing.summary, timing.perInstance(images.count))
        }

        if !thread.isCancelled {
            generateThumbnails(of: images, on: thread)
        }

        return mode != MediaScanRules.ignoreMode
    }

    /// Runs `body` on the queue of the scan's database. An exception comes back
    /// here, once the queue is released.
    private func onDatabaseQueue(_ body: () -> Void) {
        N2ManagedObjectContextPerformAndWait(database.managedObjectContext, body)
    }

    /// The identifiers of the images `identifiers` names that exist.
    private func existing(_ identifiers: [Any]?) -> [NSManagedObjectID] {
        (database.objects(withIDs: identifiers) ?? []).compactMap { ($0 as? NSManagedObject)?.objectID }
    }

    /// Indexes the entries of a DICOMDIR: the files they describe are not read.
    private func indexing(entries: [Any]) -> [NSManagedObjectID] {
        guard !entries.isEmpty else { return [] }
        Thread.current.status = String(format: NSLocalizedString("Importing %@...", comment: ""),
                                       singularPluralCount(entries.count, NSLocalizedString("file", comment: ""),
                                                           NSLocalizedString("files", comment: "")))
        var images: [NSManagedObjectID] = []
        onDatabaseQueue {
            images = existing(ingest.index(described: entries, preset: .mediaDicomdir, in: database))
        }
        return images
    }

    /// Indexes the files the reading of the medium found, where they are.
    private func indexing(files: [Any]) -> [NSManagedObjectID] {
        var images: [NSManagedObjectID] = []
        onDatabaseQueue {
            images = existing(ingest.indexReturningIDs(files, preset: .mediaScan, in: database).objectIDs)
        }
        return images
    }

    /// The file of each image, as the images answer.
    private func filesOf(_ images: [NSManagedObjectID]) -> [Any] {
        var files: [Any] = []
        onDatabaseQueue {
            files = ((database.objects(withIDs: images) as NSArray?)?.value(forKey: "completePath") as? [Any]) ?? []
        }
        return files
    }

    /// The files to copy off the medium, each once.
    private func pathsToCopy(_ images: [NSManagedObjectID]) -> [String] {
        let paths = NSMutableArray()
        // The images answer their files by KVC, in Core Data, which raises.
        HorosObjCException.logged("-[DicomDatabase(Scan) scanAtPath:isVolume:]") {
            paths.addObjects(from: self.filesOf(images))
        }
        paths.removeDuplicatedStrings()
        return paths.compactMap { $0 as? String }
    }

    /// Copies `paths` into the active local database and indexes them there.
    private func copying(_ paths: [String]) -> MediaImportOutcome {
        Thread.current.name = NSLocalizedString("Importing images from media...", comment: "")
        guard let destination = DicomDatabase.activeLocal() else { return MediaImportOutcome(stopped: false) }
        let request = MediaImportRequest(files: paths, copyFiles: true, mountedVolume: true, addToAlbum: true, selectStudy: true)
        return MediaImportJob(database: destination, request: request, ingest: ingest).run()
    }

    private func eject(_ thread: Thread) {
        NSLog("(scanAtPath): Ejecting...")
        thread.status = NSLocalizedString("Ejecting...", comment: "")
        thread.progress = -1

        DCMPix.purgeCachedDictionaries() // <- This is very important to 'unlink' all opened files, otherwise MacOS will display the famous 'The disk is in use and could not be ejected'

        var attempts = 0
        var success = false
        while !success {
            success = NSWorkspace.shared.unmountAndEjectDevice(atPath: path)
            if !success {
                attempts += 1
                if attempts < 5 {
                    Thread.sleep(forTimeInterval: 1.0)
                } else {
                    success = true
                }
            }
        }
    }

    private func generateThumbnails(of images: [NSManagedObjectID], on thread: Thread) {
        thread.status = NSLocalizedString("Generating series thumbnails...", comment: "")
        onDatabaseQueue {
            let dicomSeries = NSMutableArray()

            // Core Data finds the series, and their thumbnails are drawn from the
            // images by DCMPix: both raise.
            HorosObjCException.logged("-[DicomDatabase(Scan) scanAtPath:isVolume:]") {
                for case let di as DicomImage in self.database.objects(withIDs: images) ?? [] {
                    if let series = di.series, !dicomSeries.contains(series) {
                        dicomSeries.add(series)
                    }
                }
            }

            for i in 0..<dicomSeries.count {
                HorosObjCException.logged("-[DicomDatabase(Scan) scanAtPath:isVolume:]", stack: true) {
                    thread.progress = CGFloat(1.0 * Double(i) / Double(dicomSeries.count))
                    _ = (dicomSeries.object(at: i) as? DicomSeries)?.thumbnail
                }
            }
        }
    }
}

/// N2LocalizedSingularPluralCount(c, s, p) of N2Stuff.h.
private func singularPluralCount(_ count: Int, _ singular: String, _ plural: String) -> String {
    return String(format: "%@ %@", NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal),
                  count == 1 ? singular : plural)
}

@objc(Scan) @implementation extension DicomDatabase {

    func scan(atPath path: String!) -> Bool {
        let ingest = DatabaseIngest.process
        return MediaVolumeScan(database: self, path: path, isVolume: true, ingest: ingest,
                               questions: MediaScanQuestions(ingest: ingest)).run()
    }

    class func _findDicomdir(in allpaths: [Any]!) -> String! {
        return MediaScanRules.dicomdir(in: (allpaths ?? []).compactMap { $0 as? String })
    }
}
