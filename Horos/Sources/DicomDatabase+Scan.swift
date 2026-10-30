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

// DicomDatabase (Scan): reading a medium, a disc or a folder mounted as one.
// Its DICOMDIR is read first (DicomDatabase+DicomDir.swift); then, as the
// preferences say, the medium itself; the files found are indexed, and copied
// into the database or browsed where they are, as the user chooses. What the
// scan decides without reading a file is IsiXDatabase's MediaScanRules.


/// The scan's questions to the user, asked on the main thread while the scan
/// waits for the answer.
private final class MediaScanQuestions: NSObject {

    /// [archive, destination]: the password of a ZIP archive.
    @objc(_requestZipPassword:)
    func requestZipPassword(_ args: NSArray) {
        let archive = args.object(at: 0) as? String, destination = args.object(at: 1) as? String
        MainActor.assumeIsolated {
            _ = BrowserController.currentBrowser()?.askForZIPPassword(archive, destination: destination)
        }
    }

    /// [medium, count, answer]: copy the disc's images, browse them or ignore
    /// them. The answer is written into `answer`, a MediaScanAnswer.
    @objc(_askUserDiscDataCopyOrBrowse:)
    func askUserDiscDataCopyOrBrowse(_ a: NSArray) {
        let path = a.object(at: 0) as? String
        let count = (a.object(at: 1) as? NSNumber)?.intValue ?? 0
        let answer = a.object(at: 2) as? MediaScanAnswer
        MainActor.assumeIsolated {
            let dialog = DiscMountedAskTheUserDialogController(mountedPath: path, dicomFilesCount: count)
            dialog.window?.center()

            if let window = dialog.window { NSApp.runModal(for: window) }

            answer?.mode = dialog.choice

            dialog.window?.close()
        }
    }
}

/// [[NSApp currentEvent] modifierFlags] & Command, read on the scan's thread as
/// the scan always read it: the event the main thread is handling.
private func currentEventHasCommand() -> Bool {
    let application = (NSApplication.self as AnyObject).perform(NSSelectorFromString("sharedApplication"))?
        .takeUnretainedValue() as? NSObject
    guard let event = application?.value(forKey: "currentEvent") as? NSEvent else { return false }
    return event.modifierFlags.contains(.command)
}

/// The files the copy of a medium is given, handed to its thread.
private struct CopyInput: @unchecked Sendable {
    let paths: NSMutableArray?
}

/// The MOUNT mode the user chose, written on the main thread and read by the
/// scan once performSelectorOnMainThread:waitUntilDone:YES has returned.
private final class MediaScanAnswer: NSObject, @unchecked Sendable {
    var mode: Int
    init(mode: Int) { self.mode = mode }
}

@objc(Scan) @implementation extension DicomDatabase {

    func scan(atPath path: String!) -> Bool {
        return scan(atPath: path, isVolume: true)
    }

    class func _findDicomdir(in allpaths: [Any]!) -> String! {
        return MediaScanRules.dicomdir(in: (allpaths ?? []).compactMap { $0 as? String })
    }

    private final func scan(atPath path: String!, isVolume: Bool) -> Bool {
        let thread = Thread.current
        thread.enterOperation()
        defer { thread.exitOperation() }

        var dicomImages: [Any] = []

        // "Minutes per image" is the report, and one elapsed time cannot say which
        // part of the import spent them. Listing the medium, reading its index,
        // opening every file to see whether it is DICOM, parsing and indexing the
        // ones that are, and copying them into the database are five different
        // things, slow for five different reasons. They are timed apart.
        let timing = MediaScanTiming(medium: (path as NSString).lastPathComponent)

        thread.status = NSLocalizedString("Scanning directories...", comment: "")
        timing.begin("listing")
        let listed = (FileManager.default.enumerator(atPath: path, filesOnly: true).allObjects as? [String]) ?? []
        let allpaths = NSMutableArray(array: (path as NSString).strings(byAppendingPaths: listed))
        timing.end("listing", count: allpaths.count, noun: "file")
        let pathsToScanAnyway = NSMutableArray()

        // first read the DICOMDIR file
        if UserDefaults.standard.bool(forKey: "UseDICOMDIRFileCD") {
            thread.status = NSLocalizedString("Looking for DICOMDIR...", comment: "")
            if let dicomdirPath = DicomDatabase._findDicomdir(in: allpaths as? [Any]) {
                NSLog("(scanAtPath): Scanning DICOMDIR at %@", dicomdirPath)
                thread.status = NSLocalizedString("Reading DICOMDIR...", comment: "")

                timing.begin("reading the index for")
                do {
                    try HorosObjCException.perform {
                        dicomImages = self.scanDicomdir(at: dicomdirPath, withPaths: allpaths, pathsToScanAnyway: pathsToScanAnyway)
                    }
                } catch {
                    if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                        _N2LogExceptionImpl(exception, true, "-[DicomDatabase(Scan) scanAtPath:isVolume:]")
                    }
                }
                timing.end("reading the index for", count: dicomImages.count, noun: "instance")
            }
        }

        // What the index accounted for. A DICOMDIR is supposed to name every
        // instance on the medium; some name fewer. Trusting it and stopping there
        // left eight of twelve instances on a disc that was then ejected, with
        // nothing said - so the disc is read as well, and only the files the index
        // already brought in are skipped.
        let indexedPaths = NSMutableSet()
        for indexed in ((dicomImages as NSArray).value(forKey: "completePath") as? NSArray) ?? [] {
            if let indexed = indexed as? String { indexedPaths.add(indexed) }
        }

        let usedDicomdir = !dicomImages.isEmpty
        let scanBeyondDicomdir = UserDefaults.standard.bool(forKey: "ScanDiskBeyondDICOMDIR")

        let doScan = !UserDefaults.standard.bool(forKey: "UseDICOMDIRFileCD")
            || (dicomImages.isEmpty && UserDefaults.standard.bool(forKey: "ScanDiskIfDICOMDIRZero"))
            || (usedDicomdir && scanBeyondDicomdir)

        let namedByIndex = dicomImages.count

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
                        do {
                            try HorosObjCException.perform {
                                let tempPath = FileManager.default.tmpDirectoryPath(inDir: self.tempDirPath())

                                if !BrowserController.unzipFile(path, withPassword: nil, destination: tempPath,
                                                                showGUI: true, terminationStatus: nil) { // needs password
                                    MediaScanQuestions().performSelector(onMainThread: #selector(MediaScanQuestions.requestZipPassword(_:)),
                                                                         with: [path, tempPath as Any] as NSArray, waitUntilDone: true)
                                }

                                _ = self.scan(atPath: tempPath, isVolume: false)
                            }
                        } catch {
                            let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
                            NSLog("(scanAtPath): %@ could not be expanded (%@); the rest of the medium is still read",
                                  (path as NSString).lastPathComponent, exception?.reason ?? "")
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
            let added = addFiles(atPaths: dicomFilePaths as? [Any], postNotifications: false, dicomOnly: false,
                                 rereadExistingItems: false, generatedByOsiriX: false, importedFiles: true, returnArray: true)
            dicomImages += objects(withIDs: added) ?? []
            timing.end("indexing", count: foundByScan, noun: "file")

            // What the medium holds, what its index named, and what is actually
            // going to be taken off it. A disc is ejected after this, so the three
            // numbers are the only record of what was left behind.
            NSLog("(scanAtPath): %@: %lu file(s) on the medium, %lu named by the index, %lu more found by reading it, %lu instance(s) to take",
                  (path as NSString).lastPathComponent, allpaths.count, namedByIndex, foundByScan, dicomImages.count)
        }

        if dicomImages.isEmpty {
            return false
        }

        let answer = MediaScanAnswer(mode: UserDefaults.standard.integer(forKey: "MOUNT"))

        if answer.mode == -1 || currentEventHasCommand() {
            MediaScanQuestions().performSelector(onMainThread: #selector(MediaScanQuestions.askUserDiscDataCopyOrBrowse(_:)),
                                                 with: [path as Any, NSNumber(value: dicomImages.count), answer] as NSArray,
                                                 waitUntilDone: true)
        }
        let mode = answer.mode

        if mode == 1 {
            // copy into database on mount

            var paths: NSMutableArray? = nil
            do {
                try HorosObjCException.perform {
                    paths = ((dicomImages as NSArray).value(forKey: "completePath") as? NSArray)?.mutableCopy() as? NSMutableArray
                }
            } catch {
                if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    _N2LogExceptionImpl(exception, false, "-[DicomDatabase(Scan) scanAtPath:isVolume:]")
                }
            }

            paths?.removeDuplicatedStrings()

            thread.supportsCancel = true
            timing.begin("copying")

            // Handed to the copy's thread, which only reads it.
            let filesInput = CopyInput(paths: paths)
            let copyFilesThread = Thread.performBlock(inBackground: {
                let cft = Thread.current
                cft.name = NSLocalizedString("Importing images from media...", comment: "")

                // -copyFilesThread: indexes on a private-queue context of its own.
                let options = NSMutableDictionary()
                if let files = filesInput.paths { options["filesInput"] = files }
                options["mountedVolume"] = NSNumber(value: true)
                options["copyFiles"] = NSNumber(value: true)
                options["addToAlbum"] = NSNumber(value: true)
                options["selectStudy"] = NSNumber(value: true)
                _ = DicomDatabase.activeLocal()?.perform(NSSelectorFromString("copyFilesThread:"), with: options)
            })

            let sleepInterval = 0.1

            // A thread that has not started yet is not a thread that is stuck. This
            // waited one second for isExecuting and then gave up - and what follows
            // the loop ejects the disc, so on a busy machine the medium could be
            // ejected before the copy had begun. It waits for the thread to start,
            // and then for it to finish, which is what "the copy is done" means:
            // progress reaching 1.0 is the copy's own report, not its end.
            var waitedForStart = 0.0

            while !copyFilesThread.isFinished {
                if !copyFilesThread.isExecuting {
                    waitedForStart += sleepInterval
                    if waitedForStart > 60.0 {
                        NSLog("(scanAtPath): the copy did not start within a minute")
                        break
                    }
                }

                if thread.isCancelled && !copyFilesThread.isCancelled {
                    copyFilesThread.cancel()
                } else {
                    if !BrowserObjCLiterallyEqual(thread.status, copyFilesThread.status) {
                        thread.status = copyFilesThread.status
                    }

                    if !BrowserObjCLiterallyEqual(thread.name, copyFilesThread.name) {
                        thread.name = copyFilesThread.name
                    }

                    if thread.progress != copyFilesThread.progress {
                        thread.progress = copyFilesThread.progress
                    }
                }

                Thread.sleep(forTimeInterval: sleepInterval)
            }

            thread.supportsCancel = false // why now?

            // A copy that was stopped part way did not copy the files it was given,
            // and saying "copying 1200 files" of it would be a claim. How many did
            // arrive is copyFilesThread's to report, and it does.
            if copyFilesThread.isCancelled {
                timing.end("copying")
                NSLog("(scanAtPath): %@: the copy was stopped before it finished; what had already been copied was indexed",
                      (path as NSString).lastPathComponent)
            } else {
                timing.end("copying", count: paths?.count ?? 0, noun: "file")
            }

            // Where the import spent its time, and what one instance of this medium
            // cost. Written before the eject, like the tally above it.
            NSLog("(scanAtPath): %@ (%@)", timing.summary, timing.perInstance(dicomImages.count))

            // Only a copy that finished is a copy that can be ejected after.
            if isVolume && UserDefaults.standard.bool(forKey: "CDDVDEjectAfterAutoCopy")
                && !copyFilesThread.isCancelled && copyFilesThread.isFinished {
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

                return false
            }
        } else {
            // Nothing is copied when the medium is only being browsed, so the
            // report is written here instead.
            NSLog("(scanAtPath): %@ (%@)", timing.summary, timing.perInstance(dicomImages.count))
        }

        if !thread.isCancelled {
            thread.status = NSLocalizedString("Generating series thumbnails...", comment: "")
            let dicomSeries = NSMutableArray()

            do {
                try HorosObjCException.perform {
                    for case let di as DicomImage in dicomImages {
                        if let series = di.series, !dicomSeries.contains(series) {
                            dicomSeries.add(series)
                        }
                    }
                }
            } catch {
                if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    _N2LogExceptionImpl(exception, false, "-[DicomDatabase(Scan) scanAtPath:isVolume:]")
                }
            }

            for i in 0..<dicomSeries.count {
                do {
                    try HorosObjCException.perform {
                        thread.progress = CGFloat(1.0 * Double(i) / Double(dicomSeries.count))
                        _ = (dicomSeries.object(at: i) as? DicomSeries)?.thumbnail
                    }
                } catch {
                    if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                        _N2LogExceptionImpl(exception, true, "-[DicomDatabase(Scan) scanAtPath:isVolume:]")
                    }
                }
            }
        }

        if mode == 2 { // ignore
            return false
        }

        return true
    }
}

/// `[a isEqualToString: b]`: code unit by code unit, and never for nil.
private func BrowserObjCLiterallyEqual(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return a.utf16.elementsEqual(b.utf16)
}
