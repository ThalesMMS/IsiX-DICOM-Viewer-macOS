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
import CoreData
import IsiXDatabase
import IsiXDICOMFile

// DicomDatabase (Import): adding files to the index. -addFilesAtPaths: reads
// each file (DicomFile) into a dictionary of its attributes, in chunks of 20000,
// refuses and disposes of what it cannot read, and hands the dictionaries to
// -addFilesDescribedInDictionaries:, which finds or makes the study, the series
// and the image of each, saves the context, and posts what was added: at once,
// or after the save of a context that defers its saves.
//
// Every message to a dictionary's value is sent as Objective-C sent it: a nil
// value compares as the message to nil answered, and a value is stored by key
// as it was read. The methods run on the queue of the database's context, as
// before; the work of each file is an @try (DicomDatabaseObjC.attempt), so that
// a file that raises is logged and the next one is read.

/// The save of -addFilesDescribedInDictionaries: is not entered twice at once;
/// the second import's rows are written by the first one's save.
nonisolated(unsafe) private var protectionAgainstReentry = false

/// `[object isEqualToString:string]`: NO for nil, and for an object that is not a string.
private func isEqualString(_ object: Any?, _ string: String?) -> Bool {
    guard let object = object as? NSString, let string else { return false }
    return object.isEqual(to: string)
}

/// `[receiver compare:other options:case, diacritic and width insensitive] == NSOrderedSame`:
/// YES for a nil receiver (a message to nil answers 0, NSOrderedSame), NO against nil.
private func isSamePatientUID(_ receiver: Any?, _ other: Any?) -> Bool {
    guard let receiver = receiver as? NSString else { return true }
    guard let other = other as? String else { return false }
    return receiver.compare(other, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
}

/// `[object length]`: 0 for nil.
private func objcLength(_ object: Any?) -> Int {
    if let string = object as? NSString { return string.length }
    if let data = object as? NSData { return data.length }
    return 0
}

/// `[object count]`: 0 for nil.
private func objcCount(_ object: Any?) -> Int {
    return (object as? NSArray)?.count ?? 0
}

/// `[object intValue]`: 0 for nil.
private func objcIntValue(_ object: Any?) -> Int32 {
    if let number = object as? NSNumber { return number.int32Value }
    if let string = object as? NSString { return string.intValue }
    return 0
}

/// `[array indexOfObject:object]`: NSNotFound for nil.
private func indexOfObject(_ object: Any?, in array: NSArray?) -> Int {
    guard let object, let array else { return NSNotFound }
    return array.index(of: object)
}

/// `[set addObject:object]`, which raised on nil.
private func addObject(_ object: Any?, to set: NSMutableSet) {
    if let object { set.add(object) } else { _ = set.perform(#selector(NSMutableSet.add(_:)), with: nil) }
}

/// Which study owns each referenced SOP Instance. There is no index on the SOP
/// column, so this is one SQL scan; faulting every image instead took minutes per
/// import batch on a database of millions of images.
private func studyUIDs(forSOPInstanceUIDs uids: [String], in context: NSManagedObjectContext?) -> [String: String] {
    var encoded: [Data] = []
    for uid in uids where (uid as NSString).length != 0 {
        guard let data = DicomImage.sopInstanceUIDEncode(uid) else { continue }
        encoded.append(data)
        // isEqualToSopInstanceUID: also accepts a stored trailing zero byte.
        var padded = data
        padded.append(0)
        encoded.append(padded)
    }
    guard !encoded.isEmpty, let context else { return [:] }

    let request = NSFetchRequest<NSManagedObject>(entityName: "Image")
    request.predicate = NSPredicate(format: "compressedSopInstanceUID IN %@", encoded as NSArray)
    var images: [NSManagedObject] = []
    do {
        images = try context.fetch(request)
    } catch {
        DicomDatabaseObjC.logError(String(format: "Cloud report SOP lookup failed: %@", error as NSError), "HorosStudyUIDsForSOPInstanceUIDs")
    }

    var owners: [String: String] = [:]
    for case let image as DicomImage in images {
        let sop = image.sopInstanceUID()
        let study = image.value(forKeyPath: "series.study.studyInstanceUID") as? String
        if let sop, (sop as NSString).length != 0, let study, (study as NSString).length != 0 {
            owners[sop] = study
        }
    }
    return owners
}

/// Whether a described file may be a report from the cloud: what its SOP
/// class, modality, series description and manufacturer say (IsiXDatabase's
/// CloudReportCandidate). Missing metadata must not trigger the full study/SOP scan.
private func incomingLooksLikeCloudReport(_ dict: NSDictionary) -> Bool {
    let sop = dict.object(forKey: "SOPClassUID") as? String
    return CloudReportCandidate.looksLikeReport(isPDFOrStructuredReport: DICOMSOPClass.isPDF(sop) || DICOMSOPClass.isStructuredReport(sop),
                                                modality: dict.object(forKey: "modality") as? String,
                                                seriesDescription: dict.object(forKey: "seriesDescription") as? String,
                                                manufacturer: dict.object(forKey: "manufacturer") as? String)
}

/// Groups a Cloud/PDF report with the study it references. Name alone does not
/// join patients or studies. The file keeps its original Study Instance UID.
private func associateCloudReports(_ dicomFilesArray: NSArray, _ studiesArray: NSArray, _ context: NSManagedObjectContext?) {
    var maybeReport = false
    for case let item as NSDictionary in dicomFilesArray where incomingLooksLikeCloudReport(item) {
        maybeReport = true
        break
    }
    if !maybeReport { return }

    // Study identity only. SOP Instances are looked up on demand, for the few
    // reports that match neither by Study UID nor by referenced study.
    var known: [Any] = []
    for case let study as DicomStudy in studiesArray {
        let entry = NSMutableDictionary()
        if let uid = study.studyInstanceUID { entry.setObject(uid, forKey: "studyID" as NSString) }
        if let uid = study.patientUID { entry.setObject(uid, forKey: "patientUID" as NSString) }
        if let name = study.name { entry.setObject(name, forKey: "patientName" as NSString) }
        if let id = study.patientID { entry.setObject(id, forKey: "patientID" as NSString) }
        known.append(entry)
    }
    CloudReportAssociation.associateReports(inFiles: dicomFilesArray, existingStudies: known,
                                            studyUIDsForSOPInstanceUIDs: { uids in studyUIDs(forSOPInstanceUIDs: uids, in: context) })
}

@objc(Import) @implementation extension DicomDatabase {

    // MARK: - Add files

    func addFiles(atPaths paths: [Any]!) -> [Any]! {
        return self.addFiles(atPaths: paths, postNotifications: true)
    }

    func addFiles(atPaths paths: [Any]!, postNotifications: Bool) -> [Any]! {
        return self.addFiles(atPaths: paths, postNotifications: postNotifications, dicomOnly: UserDefaults.standard.bool(forKey: "onlyDICOM"), rereadExistingItems: false)
    }

    func addFiles(atPaths paths: [Any]!, postNotifications: Bool, dicomOnly: Bool, rereadExistingItems: Bool) -> [Any]! {
        return self.addFiles(atPaths: paths, postNotifications: postNotifications, dicomOnly: dicomOnly, rereadExistingItems: rereadExistingItems, generatedByOsiriX: false)
    }

    func addFiles(atPaths paths: [Any]!, postNotifications: Bool, dicomOnly: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool) -> [Any]! {
        return self.addFiles(atPaths: paths, postNotifications: postNotifications, dicomOnly: dicomOnly, rereadExistingItems: rereadExistingItems, generatedByOsiriX: generatedByOsiriX, returnArray: true)
    }

    func addFiles(atPaths paths: [Any]!, postNotifications: Bool, dicomOnly: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool, returnArray: Bool) -> [Any]! {
        return self.addFiles(atPaths: paths, postNotifications: postNotifications, dicomOnly: dicomOnly, rereadExistingItems: rereadExistingItems, generatedByOsiriX: generatedByOsiriX, importedFiles: false, returnArray: returnArray)
    }

    func addFiles(atPaths paths: [Any]!, postNotifications: Bool, dicomOnly: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool, importedFiles: Bool, returnArray: Bool) -> [Any]! {
        return self.addFiles(atPaths: paths as NSArray?, postNotifications: postNotifications, dicomOnly: dicomOnly, rereadExistingItems: rereadExistingItems,
                             generatedByOsiriX: generatedByOsiriX, importedFiles: importedFiles, returnArray: returnArray, unindexedPaths: nil) as? [Any]
    }

    /// Says, in a Debug build, that the context is used on the thread it
    /// belongs to; a Release build's check does nothing.
    private final func checkForCorrectContextThreadIfDeclared() {
        self.checkForCorrectContextThread()
    }

    // A cancelled pass indexes nothing from the chunk it was in, nor from those after
    // it. unindexedPaths, when given, receives those files - what was read under the
    // name it was read from - so that a caller who moved them into the database
    // folder can take them out again.
    final func addFiles(atPaths paths: NSArray?, postNotifications: Bool, dicomOnly: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool,
                        importedFiles: Bool, returnArray: Bool, unindexedPaths: NSMutableArray?) -> NSArray? {
        let thread = Thread.current
        var stopped = false

        checkForCorrectContextThreadIfDeclared()

        let retArray: NSMutableArray? = returnArray ? NSMutableArray() : nil // This array can be HUGE when rebuild a DB with millions of images

        let errorsDirPath = self.errorsDirPath()
        let dataDirPath = self.dataDirPath()
        let reportsDirPath = self.reportsDirPath()
        let total = paths?.count ?? 0

        thread.enterOperation()
        thread.status = String(format: NSLocalizedString("Scanning %@", comment: ""), DicomDatabaseObjC.localizedFileCount(total))

        let chunkRanges = paths?.splitArrayIntoChunks(ofMinSize: 20000, maxChunks: 0) ?? NSArray()
        var chunkIndex = 0
        while chunkIndex < chunkRanges.count {
            let chunkRange = (chunkRanges.object(at: chunkIndex) as! NSValue).rangeValue
            let endOfPass: Bool = autoreleasepool {
                let deleteFileListener = UserDefaults.standard.bool(forKey: "DELETEFILELISTENER")
                let dicomFilesArray = NSMutableArray(capacity: chunkRange.length)

                // A file that cannot be turned into an instance was dropped in silence
                // unless it was already inside the database folder. On a medium that means
                // a study quietly missing images, with nothing to say which.
                let refusals = ImportRefusals(considered: chunkRange.length)

                // What the previous import refused stops being current the moment another
                // one has files of its own. An idle scan - the usual case, several times a
                // minute - leaves the line alone, so a refusal stays readable.
                if chunkIndex == 0 && chunkRange.length != 0 {
                    self.setLastImportRefusalSummary(nil)
                }

                if let dataDirPath, !FileManager.default.fileExists(atPath: dataDirPath) {
                    try? FileManager.default.createDirectory(atPath: dataDirPath, withIntermediateDirectories: true, attributes: nil)
                }

                if let reportsDirPath, !FileManager.default.fileExists(atPath: reportsDirPath) {
                    try? FileManager.default.createDirectory(atPath: reportsDirPath, withIntermediateDirectories: true, attributes: nil)
                }

                if chunkRange.length == 0 {
                    return true
                }

                var start = Date.timeIntervalSinceReferenceDate

                let end = chunkRange.location + chunkRange.length
                var i = chunkRange.location
                while i < end {
                    if Date.timeIntervalSinceReferenceDate - start > 0.5 || i == end - 1 {
                        thread.progress = CGFloat(1.0 * Double(i) / Double(total))
                        ActivityProgressCount.set(done: ImportShortfall.progressDone(index: i, total: total), total: total, on: thread)
                        start = Date.timeIntervalSinceReferenceDate
                    }

                    autoreleasepool {
                        if let exception = DicomDatabaseObjC.attempt({
                            self.readFile(paths?.object(at: i) as? String, dicomOnly: dicomOnly, dataDirPath: dataDirPath, errorsDirPath: errorsDirPath,
                                          deleteFileListener: deleteFileListener, refusals: refusals, into: dicomFilesArray)
                        }) {
                            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase addFilesAtPaths:postNotifications:dicomOnly:rereadExistingItems:generatedByOsiriX:importedFiles:returnArray:unindexedPaths:]")
                        }
                    }

                    stopped = thread.isCancelled
                    for operation in OperationQueue.current?.operations ?? [] where operation.isCancelled {
                        stopped = true
                    }
                    if stopped {
                        for case let read as NSDictionary in dicomFilesArray {
                            if let readPath = read.object(forKey: "filePath") {
                                unindexedPaths?.add(readPath)
                            }
                        }
                        if let paths {
                            unindexedPaths?.addObjects(from: paths.subarray(with: NSRange(location: i + 1, length: paths.count - (i + 1))))
                        }
                        dicomFilesArray.removeAllObjects()
                        break
                    }
                    i += 1
                }

                if refusals.count != 0 {
                    NSLog("(addFilesAtPaths): %@", refusals.summary)
                    // The incoming scanner calls this once per batch, so a refusal in one
                    // batch must not be erased by the next batch being clean. The scan
                    // clears the line when it starts.
                    self.addImportRefusalSummary(refusals.summary)
                }

                thread.enterOperationIgnoringLowerLevels()
                thread.status = String(format: NSLocalizedString("Adding %@", comment: ""), DicomDatabaseObjC.localizedFileCount(dicomFilesArray.count))

                let objectIDs = self.addFilesDescribed(inDictionaries: dicomFilesArray as? [Any], postNotifications: postNotifications,
                                                      rereadExistingItems: rereadExistingItems, generatedByOsiriX: generatedByOsiriX,
                                                      importedFiles: importedFiles, returnArray: returnArray)

                thread.exitOperation()

                if let retArray {
                    retArray.addObjects(from: objectIDs ?? [])
                } else {
                    try? self.managedObjectContext.save()
                    self.managedObjectContext.reset()

                    NSLog("%d / %d", Int32(truncatingIfNeeded: chunkIndex), Int32(truncatingIfNeeded: chunkRanges.count))
                }

                return stopped
            }
            if endOfPass { break }
            chunkIndex += 1
        }

        thread.exitOperation()

        return retArray
    }

    /// Reads one file of -addFilesAtPaths: into `dicomFilesArray`, or refuses it
    /// and disposes of it.
    private final func readFile(_ path: String?, dicomOnly: Bool, dataDirPath: String?, errorsDirPath: String?, deleteFileListener: Bool,
                          refusals: ImportRefusals, into dicomFilesArray: NSMutableArray) {
        var newFile = path
        var curFile: DicomFile? = nil

        if let exception = DicomDatabaseObjC.attempt({ curFile = DicomFile(newFile) }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase addFilesAtPaths:postNotifications:dicomOnly:rereadExistingItems:generatedByOsiriX:importedFiles:returnArray:unindexedPaths:]")
        }

        // Bytes after the dataset's Pixel Data that do not parse - zeros,
        // or part of another file written past the image - made the whole
        // file unreadable. Its intact part is written into the
        // database folder and indexed if it reads; a file imported in place
        // is left as it is, the database's own copy is replaced.
        if curFile == nil, let dataDirPath, let source = newFile, DICOMTrailingDataRepair.intactLength(ofFileAt: source) != nil {
            let intact = self.uniquePathForNewDataFile(withExtension: "dcm")
            let dropped: Int64 = intact.map { DICOMTrailingDataRepair.writeIntactCopy(ofFileAt: source, to: $0) } ?? -1
            if dropped > 0, let intact {
                if let exception = DicomDatabaseObjC.attempt({ curFile = DicomFile(intact) }) {
                    DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase addFilesAtPaths:postNotifications:dicomOnly:rereadExistingItems:generatedByOsiriX:importedFiles:returnArray:unindexedPaths:]")
                }

                if curFile != nil {
                    NSLog("---- import: %@ has %lld bytes after its Pixel Data that do not parse; imported without them as %@",
                          (source as NSString).lastPathComponent, dropped, (intact as NSString).lastPathComponent)
                    if source.hasPrefix(dataDirPath) {
                        try? FileManager.default.removeItem(atPath: source)
                    }
                    newFile = intact
                } else {
                    try? FileManager.default.removeItem(atPath: intact)
                }
            }
        }

        guard let curFile else {
            refusals.refuse(newFile ?? "")
            if let newFile { disposeOfUnreadable(newFile, dataDirPath: dataDirPath, errorsDirPath: errorsDirPath, deleteFileListener: deleteFileListener) }
            return
        }

        var curDict: NSMutableDictionary? = curFile.dicomElements()
        // A file the reader understood, refused because this database
        // indexes only DICOM. Saying it could not be read would send
        // someone looking for a fault in a file that has none.
        var refusedByPolicy: String? = nil
        if dicomOnly {
            let kind = curDict?.object(forKey: "fileType") as? String
            if !(kind?.hasPrefix("DICOM") ?? false) {
                refusedByPolicy = String(format: NSLocalizedString("is %@, and this database indexes only DICOM (see the onlyDICOM preference)", comment: ""),
                                         objcLength(kind) != 0 ? kind! : NSLocalizedString("not DICOM", comment: ""))
                curDict = nil
            }
        }

        if let curDict {
            dicomFilesArray.add(curDict)
        } else {
            if let refusedByPolicy {
                refusals.refuse(newFile ?? "", reason: refusedByPolicy)
            } else {
                refusals.refuse(newFile ?? "")
            }
            if let newFile { disposeOfUnreadable(newFile, dataDirPath: dataDirPath, errorsDirPath: errorsDirPath, deleteFileListener: deleteFileListener) }
        }
    }

    // MARK: - Add files described in dictionaries

    /*
     Keys in (MUTABLE) dictionaries:

     filePath, SOPClassUID, seriesDescription, seriesID, fileType, studyID,
     patientUID, modality, accessionNumber, patientBirthDate, patientSex,
     patientName, patientID, studyNumber, studyDescription,
     referringPhysiciansName, performingPhysiciansName, institutionName, hasDICOM,
     studyDate, date, seriesDICOMUID, seriesNumber, protocolName, numberOfFrames,
     SOPUID* (), imageID* (), sliceLocation, height, width, numberOfSeries,
     numberOfROIs, referencedSOPInstanceUID, commentsAutoFill, seriesComments,
     studyComments, stateText, keyFrames, album
     */

    func addFilesDescribed(inDictionaries dicomFilesArray: [Any]!, postNotifications: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool) -> [Any]! {
        return self.addFilesDescribed(inDictionaries: dicomFilesArray, postNotifications: postNotifications, rereadExistingItems: rereadExistingItems, generatedByOsiriX: generatedByOsiriX, returnArray: true)
    }

    func addFilesDescribed(inDictionaries dicomFilesArray: [Any]!, postNotifications: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool, returnArray: Bool) -> [Any]! {
        return self.addFilesDescribed(inDictionaries: dicomFilesArray, postNotifications: postNotifications, rereadExistingItems: rereadExistingItems, generatedByOsiriX: generatedByOsiriX, importedFiles: false, returnArray: returnArray)
    }

    func addFilesDescribed(inDictionaries dicomFilesArray: [Any]!, postNotifications: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool, importedFiles: Bool, returnArray: Bool) -> [Any]! {
        checkForCorrectContextThreadIfDeclared()

        let files = (dicomFilesArray as NSArray?) ?? NSArray()
        let thread = Thread.current
        thread.status = String(format: NSLocalizedString("Adding %@", comment: ""), DicomDatabaseObjC.localizedFileCount(files.count))

        let added = DicomDatabaseImportBatch(returnArray: returnArray, capacity: files.count)

        autoreleasepool {
            self.cleanForFreeSpace()

            if let exception = DicomDatabaseObjC.attempt({
                self.indexDescribedFiles(files, into: added, rereadExistingItems: rereadExistingItems, generatedByOsiriX: generatedByOsiriX, importedFiles: importedFiles)
            }) {
                DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase addFilesDescribedInDictionaries:postNotifications:rereadExistingItems:generatedByOsiriX:importedFiles:returnArray:]")
            }

            // A report the app archived itself - after an edit that may have come from a client of the shared database -
            // is no reason to stop the computer serving it with a modal alert: it is logged.
            if added.rejectedReports != 0 && generatedByOsiriX {
                NSLog("---- import: %lu report archive(s) written by Horos could not be read back; existing reports were preserved", UInt(added.rejectedReports))
            } else if added.rejectedReports != 0 && !((self.managedObjectContext as? N2ManagedObjectContext)?.defersSaves ?? false) {
                self.alertRejectedReports(added.rejectedReports)
            }

            let publishImportChanges = {
                self.publish(added, postNotifications: postNotifications, rereadExistingItems: rereadExistingItems,
                             generatedByOsiriX: generatedByOsiriX, returnArray: returnArray)
            }
            if let importContext = self.managedObjectContext as? N2ManagedObjectContext, importContext.defersSaves {
                importContext.perform(afterNextSuccessfulSave: publishImportChanges)
            } else {
                publishImportChanges()
            }
        }

        return added.addedImageObjects?.value(forKey: "objectID") as? [Any]
    }

    /// Finds or makes the study, the series and the images of each described
    /// file, then saves: the body of the former @try.
    private final func indexDescribedFiles(_ dicomFilesArray: NSArray, into added: DicomDatabaseImportBatch, rereadExistingItems: Bool, generatedByOsiriX: Bool, importedFiles: Bool) {
        let thread = Thread.current
        let context = self.managedObjectContext
        let studiesArray = ((self.objects(forEntity: self.studyEntity()) as NSArray?)?.mutableCopy() as? NSMutableArray) ?? NSMutableArray()
        let modifiedStudiesArray = NSMutableArray()

        let defaultDate = DicomDatabaseUndefinedStudyDate()

        let studiesArrayStudyInstanceUID = ((studiesArray.value(forKey: "studyInstanceUID") as? NSArray)?.mutableCopy() as? NSMutableArray) ?? NSMutableArray()
        let cursor = DicomDatabaseImportCursor()

        let today = Date()
        let dataDirPath = self.dataDirPath()
        let reportsDirPath = self.reportsDirPath()
        let errorsDirPath = self.errorsDirPath()
        let defaults = UserDefaults.standard
        let settings = DicomDatabaseImportSettings(
            combineProjectionSeries: defaults.bool(forKey: "combineProjectionSeries"),
            combineProjectionSeriesMode: defaults.bool(forKey: "combineProjectionSeriesMode") ? 1 : 0,
            commentsAutoFill: defaults.bool(forKey: "COMMENTSAUTOFILL"),
            deleteFileListener: defaults.bool(forKey: "DELETEFILELISTENER"),
            commentField: defaults.string(forKey: "commentFieldForAutoFill"),
            commentsAutoFillSeriesLevel: defaults.bool(forKey: "COMMENTSAUTOFILLSeriesLevel"),
            commentsAutoFillStudyLevel: defaults.bool(forKey: "COMMENTSAUTOFILLStudyLevel"))

        associateCloudReports(dicomFilesArray, studiesArray, context)

        var start = Date.timeIntervalSinceReferenceDate
        // Add the new files
        for i in 0..<dicomFilesArray.count {
            if Date.timeIntervalSinceReferenceDate - start > 0.5 || i == dicomFilesArray.count - 1 {
                thread.progress = CGFloat(1.0 * Double(i) / Double(dicomFilesArray.count))
                ActivityProgressCount.set(done: ImportShortfall.progressDone(index: i, total: dicomFilesArray.count), total: dicomFilesArray.count, on: thread)
                start = Date.timeIntervalSinceReferenceDate
            }

            autoreleasepool {
                var preparedReportPath: String? = nil
                if let exception = DicomDatabaseObjC.attempt({
                    self.indexFile(dicomFilesArray.object(at: i) as? NSMutableDictionary, cursor: cursor, added: added,
                                   studiesArray: studiesArray, studiesArrayStudyInstanceUID: studiesArrayStudyInstanceUID,
                                   modifiedStudiesArray: modifiedStudiesArray, defaultDate: defaultDate, today: today,
                                   dataDirPath: dataDirPath, reportsDirPath: reportsDirPath, errorsDirPath: errorsDirPath,
                                   settings: settings, rereadExistingItems: rereadExistingItems, generatedByOsiriX: generatedByOsiriX,
                                   importedFiles: importedFiles, preparedReportPath: &preparedReportPath)
                }) {
                    DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase addFilesDescribedInDictionaries:postNotifications:rereadExistingItems:generatedByOsiriX:importedFiles:returnArray:]")
                }
                // @finally
                if let preparedReportPath, (preparedReportPath as NSString).length != 0,
                   !preparedReportPath.hasPrefix("http://"), !preparedReportPath.hasPrefix("https://") {
                    try? FileManager.default.removeItem(atPath: preparedReportPath)
                    DicomDatabaseCleanReportExtractionParent(preparedReportPath)
                }
            }
        }

        for case let study as DicomStudy in modifiedStudiesArray {
            // Compute no of images in studies/series
            _ = study.noFiles()
            // Reapply annotations from DICOMSR file
            study.reapplyAnnotationsFromDICOMSR()
        }

        thread.status = NSLocalizedString("Synchronizing database...", comment: "")
        thread.progress = -1

        // This is the step the progress panel stops on when an import goes wrong,
        // and it used to be the one step that could not say anything: the error
        // was thrown away with save:NULL, and a save that raised left
        // protectionAgainstReentry set, so every later import in the session
        // skipped its save in silence - the images were in the context and never
        // written. The flag is cleared whatever happens, and the outcome is
        // named.
        if protectionAgainstReentry == false {
            protectionAgainstReentry = true
            let raised = DicomDatabaseObjC.attempt {
                do {
                    try context?.save()
                } catch {
                    let saveError = error as NSError
                    // The files are already in the database folder and their rows
                    // are not written, so say what state that leaves: they are not
                    // lost, and rebuilding the index finds them.
                    NSLog("(addFilesDescribedInDictionaries): the database could not be saved: %@; %lu file(s) are in the database folder and not in the index, and rebuilding the database index will bring them in",
                          saveError.localizedDescription, UInt(dicomFilesArray.count))
                    thread.status = String(format: NSLocalizedString("The database could not be saved: %@", comment: ""), saveError.localizedDescription)
                }
            }
            protectionAgainstReentry = false
            if let raised { raised.raise() }
        } else {
            NSLog("(addFilesDescribedInDictionaries): another import is saving; these %lu file(s) are written with it", UInt(dicomFilesArray.count))
        }
    }

    /// One described file: the body of the former loop's @try. `preparedReportPath`
    /// is the report extracted from it, which the caller removes afterwards.
    private final func indexFile(_ curDict: NSMutableDictionary?, cursor: DicomDatabaseImportCursor, added: DicomDatabaseImportBatch,
                           studiesArray: NSMutableArray, studiesArrayStudyInstanceUID: NSMutableArray, modifiedStudiesArray: NSMutableArray,
                           defaultDate: Date, today: Date, dataDirPath: String?, reportsDirPath: String?, errorsDirPath: String?,
                           settings: DicomDatabaseImportSettings, rereadExistingItems: Bool, generatedByOsiriX: Bool, importedFiles: Bool,
                           preparedReportPath: inout String?) {
        let context = self.managedObjectContext
        var importedDate = curDict?.object(forKey: "studyDate") as? Date
        if importedDate == defaultDate { importedDate = nil }

        let newFile = curDict?.object(forKey: "filePath") as? String
        cursor.newFile = newFile

        var DICOMSR = false
        var inParseExistingObject = rereadExistingItems

        let SOPClassUID = curDict?.object(forKey: "SOPClassUID") as? String

        if DICOMSOPClass.isStructuredReport(SOPClassUID) {
            // Check if it is an OsiriX Annotations SR
            if isEqualString(curDict?.value(forKey: "seriesDescription"), "OsiriX Annotations SR") {
                curDict?.setValue("OsiriX Annotations SR", forKey: "seriesID")
                inParseExistingObject = true
                DICOMSR = true
            }

            // Check if it is an OsiriX ROI SR
            if isEqualString(curDict?.value(forKey: "seriesDescription"), "OsiriX ROI SR") {
                curDict?.setValue("OsiriX ROI SR", forKey: "seriesID")

                inParseExistingObject = true
                DICOMSR = true
            }

            // Check if it is an OsiriX Report SR
            if isEqualString(curDict?.value(forKey: "seriesDescription"), "OsiriX Report SR") {
                var extractionError: NSError? = nil
                preparedReportPath = DicomDatabase.extractReportSR(newFile, contentDate: curDict?.object(forKey: "studyDate") as? Date, error: &extractionError)
                if let extractionError {
                    added.rejectedReports += 1
                    _ = DicomDatabaseQuarantineUnindexedImport(context, newFile, dataDirPath, errorsDirPath)
                    NSLog("Report import rejected before indexing: %@", extractionError.localizedDescription)
                    return
                }
                curDict?.setValue("OsiriX Report SR", forKey: "seriesID")

                inParseExistingObject = true
                DICOMSR = true
            }

            // Check if it is an OsiriX WindowsState SR
            if isEqualString(curDict?.value(forKey: "seriesDescription"), "OsiriX WindowsState SR") {
                curDict?.setValue("OsiriX WindowsState SR", forKey: "seriesID")

                inParseExistingObject = true
                DICOMSR = true
            }
        }

        if UserDefaults.standard.bool(forKey: "acceptUnsupportedSOPClassUID") == false {
            if let SOPClassUID {
                var supportedSOPClass = false
                for s in DICOMSOPClass.allSupportedSyntaxes() where SOPClassUID.hasPrefix(s) {
                    supportedSOPClass = true
                    break
                }

                if supportedSOPClass == false {
                    NSLog("unsupported DICOM SOP CLASS (%@)-> for the file : %@", SOPClassUID, DicomDatabaseObjC.arg(newFile))
                }
            }
        }

        if curDict?.object(forKey: "SOPClassUID") == nil && ((curDict?.object(forKey: "fileType") as? String)?.hasPrefix("DICOM") ?? false) {
            NSLog("no DICOM SOP CLASS -> for the file: %@", DicomDatabaseObjC.arg(newFile))
        }

        guard let curDict else {
            // This file was not readable -> If it is located in the DATABASE folder, we have to delete it or to move it to the 'NOT READABLE' folder
            removeUnreadableDescribedFile(newFile, dataDirPath: dataDirPath, errorsDirPath: errorsDirPath, deleteFileListener: settings.deleteFileListener)
            return
        }

        if isEqualString(curDict.object(forKey: "studyID"), cursor.studyID) &&
            isSamePatientUID(curDict.object(forKey: "patientUID"), cursor.patientUID) {
            if isEqualString(cursor.study?.value(forKey: "modality"), "SR") || isEqualString(cursor.study?.value(forKey: "modality"), "OT") {
                cursor.study?.setValue(curDict.object(forKey: "modality"), forKey: "modality")
            }
        } else {
            findStudy(curDict, cursor: cursor, added: added, studiesArray: studiesArray, studiesArrayStudyInstanceUID: studiesArrayStudyInstanceUID,
                      modifiedStudiesArray: modifiedStudiesArray, defaultDate: defaultDate, today: today, SOPClassUID: SOPClassUID,
                      inParseExistingObject: inParseExistingObject)
        }

        let noOfSeries = objcIntValue(curDict.object(forKey: "numberOfSeries"))
        var seriesIndex: Int32 = 0
        while seriesIndex < noOfSeries {
            let seriesNum = seriesIndex != 0 ? String(format: "%d", seriesIndex) : ""
            let curDictSeriesID = curDict.object(forKey: "seriesID" + seriesNum) as? String

            if !isEqualString(curDictSeriesID, cursor.seriesID) {
                /********************************************/
                /*********** Find series object *************/

                let seriesArray = (cursor.study?.value(forKey: "series") as? NSSet)?.allObjects as NSArray?

                let index = indexOfObject(curDict.object(forKey: "seriesID" + seriesNum), in: seriesArray?.value(forKey: "seriesInstanceUID") as? NSArray)
                if index == NSNotFound {
                    // Fields
                    cursor.series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context!)
                    cursor.series?.setValue(today, forKey: "dateAdded")

                    cursor.newObject = true
                } else {
                    cursor.series = seriesArray?.object(at: index) as? NSManagedObject
                    cursor.newObject = false
                }

                if cursor.newObject || inParseExistingObject {
                    let seriesTable = cursor.series
                    if let uid = curDict.object(forKey: "seriesDICOMUID") { seriesTable?.setValue(uid, forKey: "seriesDICOMUID") }
                    if let uid = curDict.object(forKey: "SOPClassUID") { seriesTable?.setValue(uid, forKey: "seriesSOPClassUID") }
                    seriesTable?.setValue(curDict.object(forKey: "seriesID" + seriesNum), forKey: "seriesInstanceUID")
                    seriesTable?.setValue(curDict.object(forKey: "seriesDescription" + seriesNum), forKey: "name")
                    seriesTable?.setValue(curDict.object(forKey: "modality"), forKey: "modality")
                    seriesTable?.setValue(curDict.object(forKey: "seriesNumber" + seriesNum), forKey: "id")
                    seriesTable?.setValue(importedDate, forKey: "date")
                    seriesTable?.setValue(curDict.object(forKey: "protocolName"), forKey: "seriesDescription")

                    // Relations
                    seriesTable?.setValue(cursor.study, forKey: "study")
                    // If a study has an SC or other non primary image  series. May need to change modality to true modality
                    let studyModality = cursor.study?.value(forKey: "modality")
                    let fileModality = curDict.object(forKey: "modality")
                    if (isEqualString(studyModality, "OT") || isEqualString(studyModality, "SC"))
                        && !(isEqualString(fileModality, "OT") || isEqualString(fileModality, "SC")) {
                        cursor.study?.setValue(fileModality, forKey: "modality")
                    }
                }

                cursor.seriesID = curDictSeriesID
            }

            indexImages(curDict, seriesNum: seriesNum, cursor: cursor, added: added, importedDate: importedDate, today: today,
                        dataDirPath: dataDirPath, reportsDirPath: reportsDirPath, settings: settings, DICOMSR: DICOMSR,
                        inParseExistingObject: inParseExistingObject, generatedByOsiriX: generatedByOsiriX, importedFiles: importedFiles,
                        preparedReportPath: preparedReportPath)
            seriesIndex += 1
        }
    }

    /// Finds the study of a described file: same Study Instance UID and same
    /// patient UID (see patientUID function in DicomFile, based on patientName,
    /// patientID and patientBirthDate), or makes it; then fills it.
    private final func findStudy(_ curDict: NSMutableDictionary, cursor: DicomDatabaseImportCursor, added: DicomDatabaseImportBatch,
                           studiesArray: NSMutableArray, studiesArrayStudyInstanceUID: NSMutableArray, modifiedStudiesArray: NSMutableArray,
                           defaultDate: Date, today: Date, SOPClassUID: String?, inParseExistingObject: Bool) {
        /*******************************************/
        /*********** Find study object *************/
        // match: StudyInstanceUID and patientUID (see patientUID function in dicomFile.m, based on patientName, patientID and patientBirthDate)
        var study: DicomStudy? = nil
        cursor.seriesID = nil

        let index = indexOfObject(curDict.object(forKey: "studyID"), in: studiesArrayStudyInstanceUID)

        cursor.newObject = false

        if index != NSNotFound {
            if ((curDict.object(forKey: "fileType") as? String)?.hasPrefix("DICOM") ?? false) == false { // We do this double check only for DICOM files.
                study = studiesArray.object(at: index) as? DicomStudy
            } else {
                let tstudy = studiesArray.object(at: index) as? DicomStudy

                // is this actually an empty study? if so, treat it as a newObject
                let series = tstudy?.series
                if series?.count == 1, let only = series?.anyObject() as? NSManagedObject,
                   objcIntValue(only.value(forKey: "id")) == 5005, isEqualString(only.value(forKey: "name"), "OsiriX No Autodeletion") {
                    cursor.newObject = true
                    tstudy?.dateAdded = today
                    tstudy?.patientUID = curDict.object(forKey: "patientUID") as? String
                }

                if tstudy?.patientUID == nil {
                    tstudy?.patientUID = curDict.object(forKey: "patientUID") as? String
                }

                if isSamePatientUID(curDict.object(forKey: "patientUID"), tstudy?.patientUID) {
                    study = tstudy
                } else {
                    // Are there multiple studies with same studyInstanceUID ???
                    let curUID = curDict.object(forKey: "studyID") as? String
                    for i in 0..<studiesArrayStudyInstanceUID.count {
                        let uid = studiesArrayStudyInstanceUID.object(at: i)

                        if isEqualString(uid, curUID) {
                            if isSamePatientUID(curDict.object(forKey: "patientUID"), (studiesArray.object(at: i) as? DicomStudy)?.patientUID) {
                                study = studiesArray.object(at: i) as? DicomStudy
                            }
                        }
                    }

                    if study == nil {
                        // Two identifiers side by side leave the reader to
                        // spot the difference and then work out which tag
                        // produced it. A differing key can be a genuinely
                        // different person, so name what differs.
                        let existingUID = (studiesArray.object(at: index) as AnyObject).value(forKey: "patientUID") as? String
                        let arrivingUID = curDict.object(forKey: "patientUID") as? String
                        NSLog("-*-*-*-*-* same studyUID (%@), but not same patientUID: %@", DicomDatabaseObjC.arg(curDict.object(forKey: "studyID")),
                              PatientIdentity.difference(betweenUID: arrivingUID ?? "", andUID: existingUID ?? ""))

                        if self.hasPotentiallySlowDataAccess { //It's a CD... be less restrictive !
                            study = tstudy
                        }
                    }
                }
            }
        }

        if study == nil {
            // Fields
            study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: self.managedObjectContext) as? DicomStudy

            cursor.newObject = true
            added.newStudy = true

            study?.dateAdded = today

            if let study {
                added.newStudies.add(study)
                studiesArray.add(study)
            }
            if let studyID = curDict.object(forKey: "studyID") {
                studiesArrayStudyInstanceUID.add(studyID)
            } else {
                DicomDatabaseObjC.logStackTrace("no studyID !")
                studiesArrayStudyInstanceUID.add("noStudyID")
            }

            cursor.seriesID = nil
        }
        cursor.study = study

        if cursor.newObject || inParseExistingObject {
            study?.studyInstanceUID = curDict.object(forKey: "studyID") as? String
            study?.accessionNumber = curDict.object(forKey: "accessionNumber") as? String
            study?.modality = study?.modalities()
            study?.dateOfBirth = curDict.object(forKey: "patientBirthDate") as? Date
            study?.patientSex = curDict.object(forKey: "patientSex") as? String
            study?.patientID = curDict.object(forKey: "patientID") as? String
            study?.name = curDict.object(forKey: "patientName") as? String
            study?.patientUID = curDict.object(forKey: "patientUID") as? String
            study?.id = curDict.object(forKey: "studyNumber") as? String

            if (DICOMSOPClass.isStructuredReport(SOPClassUID) || DICOMSOPClass.isPDF(SOPClassUID)) && inParseExistingObject {
                if objcLength(curDict.object(forKey: "studyDescription")) != 0 && !isEqualString(curDict.object(forKey: "studyDescription"), "unnamed") {
                    study?.studyName = curDict.object(forKey: "studyDescription") as? String
                }
                if objcLength(curDict.object(forKey: "referringPhysiciansName")) != 0 {
                    study?.referringPhysician = curDict.object(forKey: "referringPhysiciansName") as? String
                }
                if objcLength(curDict.object(forKey: "performingPhysiciansName")) != 0 {
                    study?.performingPhysician = curDict.object(forKey: "performingPhysiciansName") as? String
                }
                if objcLength(curDict.object(forKey: "institutionName")) != 0 {
                    study?.institutionName = curDict.object(forKey: "institutionName") as? String
                }
            } else {
                study?.studyName = curDict.object(forKey: "studyDescription") as? String
                study?.referringPhysician = curDict.object(forKey: "referringPhysiciansName") as? String
                study?.performingPhysician = curDict.object(forKey: "performingPhysiciansName") as? String
                study?.institutionName = curDict.object(forKey: "institutionName") as? String
            }

            if objcLength(study?.studyName) == 0 || isEqualString(study?.studyName, "unnamed") {
                study?.studyName = curDict.object(forKey: "seriesDescription") as? String
            }

            //need to know if is DICOM so only DICOM is queried for Q/R
            if let hasDICOM = curDict.object(forKey: "hasDICOM") {
                study?.hasDICOM = hasDICOM as? NSNumber
            }

            if cursor.newObject {
                self.checkForExistingReport(forStudy: study)
            }
        } else {
            if isEqualString(study?.value(forKey: "modality"), "SR") || isEqualString(study?.value(forKey: "modality"), "OT") {
                study?.modality = curDict.object(forKey: "modality") as? String
            }

            if study?.value(forKey: "studyName") == nil || isEqualString(study?.value(forKey: "studyName"), "unnamed") || isEqualString(study?.value(forKey: "studyName"), "") {
                study?.studyName = curDict.object(forKey: "studyDescription") as? String
            }
            if objcLength(study?.studyName) == 0 || isEqualString(study?.studyName, "unnamed") {
                study?.studyName = curDict.object(forKey: "seriesDescription") as? String
            }
        }

        if let studyDate = curDict.object(forKey: "studyDate") as? Date, studyDate != defaultDate {
            let date = study?.value(forKey: "date") as? Date
            if date == nil || date == defaultDate || date!.timeIntervalSince(studyDate) >= 0 {
                study?.setValue(studyDate, forKey: "date")
            }
        }

        cursor.studyID = curDict.object(forKey: "studyID") as? String
        cursor.patientUID = curDict.object(forKey: "patientUID") as? String

        DicomDatabaseObjC.add(study, to: modifiedStudiesArray)
    }

    /// The images of one series of a described file, one per frame.
    private final func indexImages(_ curDict: NSMutableDictionary, seriesNum: String, cursor: DicomDatabaseImportCursor, added: DicomDatabaseImportBatch,
                             importedDate: Date?, today: Date, dataDirPath: String?, reportsDirPath: String?,
                             settings: DicomDatabaseImportSettings, DICOMSR: Bool, inParseExistingObject: Bool, generatedByOsiriX: Bool,
                             importedFiles: Bool, preparedReportPath: String?) {
        /*******************************************/
        /*********** Find image object *************/

        let study = cursor.study
        let seriesTable = cursor.series
        let newFile = cursor.newFile
        let local = dataDirPath != nil && newFile != nil && newFile!.hasPrefix(dataDirPath!)

        let imagesArray = (seriesTable?.value(forKey: "images") as? NSSet)?.allObjects ?? []
        var numberOfFrames = objcIntValue(curDict.object(forKey: "numberOfFrames"))
        if numberOfFrames == 0 {
            numberOfFrames = 1
        }

        var f: Int32 = 0
        while f < numberOfFrames {
            defer { f += 1 }
            var image: DicomImage? = nil

            let SOPUID = curDict.object(forKey: "SOPUID" + seriesNum) as? String

            autoreleasepool {
                for case let ii as DicomImage in imagesArray {
                    if isEqualString(ii.sopInstanceUID() as NSString?, SOPUID) && objcIntValue(ii.frameID) == f {
                        image = ii
                        break
                    }
                }
            }

            if let existing = image {
                // Does this image contain a valid image path? If not replace it, with the new one
                if DicomDatabaseObjC.fileExists(DicomImage.completePath(forLocalPath: existing.value(forKey: "path") as? String, directory: self.dataBaseDirPath)) &&
                    inParseExistingObject == false &&
                    !UserDefaults.standard.bool(forKey: "REPLACE_WITH_NEW_INCOMING_FILE") {
                    if local { // Delete this file, it's already in the DB folder
                        if !isEqualString(existing.value(forKey: "path"), (newFile! as NSString).lastPathComponent) {
                            try? FileManager.default.removeItem(atPath: newFile!)
                        }
                    }

                    cursor.newObject = false
                } else {
                    cursor.newObject = true

                    let imPath = DicomImage.completePath(forLocalPath: existing.value(forKey: "path") as? String, directory: self.dataBaseDirPath)

                    if (existing.value(forKey: "inDatabaseFolder") as? NSNumber)?.boolValue == true && !isEqualString(imPath as NSString?, newFile) {
                        DicomDatabaseRetireImportedFileAfterSave(self.managedObjectContext, imPath, newFile)
                    }
                }
            } else {
                image = self.newObject(forEntity: self.imageEntity()) as? DicomImage
                cursor.newObject = true
            }

            DicomDatabaseObjC.add(image, to: added.completeAddedImageObjects)

            var imagePrivateInformationCreatorUID = curDict.object(forKey: "PrivateInformationCreatorUID") as? String
            if objcLength(imagePrivateInformationCreatorUID) == 0 {
                imagePrivateInformationCreatorUID = UserDefaults.standard.string(forKey: "AETITLE")
            }

            added.addImage(image, forCreator: imagePrivateInformationCreatorUID, complete: true)

            if cursor.newObject || inParseExistingObject {
                if DICOMSR == false {
                    seriesTable?.setValue(today, forKey: "dateAdded")
                    study?.dateAdded = today
                }

                if numberOfFrames > 1 {
                    image?.setValue(NSNumber(value: f), forKey: "frameID")

                    let modality = study?.value(forKey: "modality")
                    if settings.combineProjectionSeries && settings.combineProjectionSeriesMode == 0 &&
                        (isEqualString(modality, "MG") || isEqualString(modality, "CR") || isEqualString(modality, "DR") || isEqualString(modality, "DX") || isEqualString(modality, "RF")) {
                        // *******Combine all CR and DR Modality series in a study into one series
                        var imageInstance = Int(objcIntValue(curDict.object(forKey: "imageID" + seriesNum)))
                        imageInstance *= 10000
                        imageInstance += Int(f)
                        image?.setValue(NSNumber(value: imageInstance), forKey: "instanceNumber")
                    } else if objcCount(curDict.object(forKey: "instanceNumberArray")) > Int(f) {
                        // The acquisition numbered its own frames.
                        // Adding the file's instance number to the
                        // frame index numbers them by where they
                        // happen to be stored instead.
                        image?.setValue((curDict.object(forKey: "instanceNumberArray") as? NSArray)?.object(at: Int(f)), forKey: "instanceNumber")
                    } else {
                        let instanceNumber = objcIntValue(curDict.object(forKey: "imageID" + seriesNum))
                        image?.setValue(NSNumber(value: instanceNumber &+ f), forKey: "instanceNumber")
                    }
                } else {
                    image?.setValue(curDict.object(forKey: "imageID" + seriesNum), forKey: "instanceNumber")
                }

                if local {
                    image?.setValue((newFile! as NSString).lastPathComponent, forKey: "path")
                } else {
                    image?.setValue(newFile, forKey: "path")
                }

                image?.setValue(NSNumber(value: local), forKey: "inDatabaseFolder")

                image?.setValue(importedDate, forKey: "date")

                image?.setValue(SOPUID, forKey: "sopInstanceUID")

                if let originalUID = curDict.object(forKey: "cloudReportOriginalStudyUID") {
                    if objcLength(originalUID) != 0 {
                        let provenance = String(format: "Horos Cloud report originally StudyInstanceUID %@", DicomDatabaseObjC.arg(originalUID))
                        if image?.value(forKey: "comment") == nil {
                            image?.setValue(provenance, forKey: "comment")
                        }
                        if seriesTable?.value(forKey: "comment") == nil {
                            seriesTable?.setValue(provenance, forKey: "comment")
                        }
                    }
                }

                if objcCount(curDict.object(forKey: "sliceLocationArray")) > Int(f) {
                    image?.setValue((curDict.object(forKey: "sliceLocationArray") as? NSArray)?.object(at: Int(f)), forKey: "sliceLocation")
                } else {
                    image?.setValue(curDict.object(forKey: "sliceLocation"), forKey: "sliceLocation")
                }

                if objcCount(curDict.object(forKey: "imageCommentPerFrame")) > Int(f) {
                    image?.setValue((curDict.object(forKey: "imageCommentPerFrame") as? NSArray)?.object(at: Int(f)), forKey: "comment")
                }

                image?.setValue((((newFile as NSString?)?.pathExtension) as NSString?)?.lowercased, forKey: "extension")
                image?.setValue(curDict.object(forKey: "fileType"), forKey: "fileType")

                image?.setValue(curDict.object(forKey: "height"), forKey: "height")
                image?.setValue(curDict.object(forKey: "width"), forKey: "width")
                image?.setValue(curDict.object(forKey: "numberOfFrames"), forKey: "numberOfFrames")
                image?.setValue(curDict.object(forKey: "numberOfSeries"), forKey: "numberOfSeries")

                image?.setThumbnail(curDict.object(forKey: "NSImageThumbnail") as? NSImage)

                if importedFiles {
                    image?.importedFile = NSNumber(value: true)
                } else {
                    image?.importedFile = nil
                }

                if generatedByOsiriX {
                    image?.setValue(NSNumber(value: generatedByOsiriX), forKey: "generatedByOsiriX")
                } else {
                    image?.setValue(nil, forKey: "generatedByOsiriX")
                }

                if cursor.newObject {
                    seriesTable?.setValue(nil, forKey: "windowWidth")
                    seriesTable?.setValue(nil, forKey: "windowLevel")
                }

                image?.setValue(curDict.object(forKey: "modality"), forKey: "modality")
                study?.setValue(study?.value(forKey: "modalities"), forKey: "modality")
                seriesTable?.setValue(nil, forKey: "thumbnail")

                if DICOMSR && curDict.object(forKey: "numberOfROIs") != nil && curDict.object(forKey: "referencedSOPInstanceUID") != nil { // OsiriX ROI SR
                    let s = curDict.object(forKey: "referencedSOPInstanceUID")
                    image?.setValue(s, forKey: "comment")
                    image?.setValue(curDict.object(forKey: "numberOfROIs"), forKey: "scale")
                }

                // Relations
                image?.setValue(seriesTable, forKey: "series")

                if DICOMSR == false {
                    fillComments(curDict, image: image, seriesTable: seriesTable, study: study, frame: f, settings: settings, generatedByOsiriX: generatedByOsiriX)
                }

                if DICOMSR && isEqualString(curDict.value(forKey: "seriesDescription"), "OsiriX WindowsState SR") {
                    let reportSR = study?.windowsStateImage() // return the most recent sr

                    if let reportSR, reportSR === image { // Because we can have multiple sr -> only the most recent one is valid
                        if let exception = DicomDatabaseObjC.attempt({
                            let r = SRAnnotation(contentsOfFile: newFile)
                            let viewers = r?.dataEncapsulated().flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) } as? NSArray

                            if (viewers?.count ?? 0) > 0 {
                                study?.willChangeValue(forKey: "windowsState")
                                study?.setPrimitiveValue(r?.dataEncapsulated(), forKey: "windowsState")
                                study?.didChangeValue(forKey: "windowsState")
                            }
                        }) {
                            DicomDatabaseObjC.log(exception, stack: false, "-[DicomDatabase addFilesDescribedInDictionaries:postNotifications:rereadExistingItems:generatedByOsiriX:importedFiles:returnArray:]")
                        }
                    }
                }

                if DICOMSR && isEqualString(curDict.value(forKey: "seriesDescription"), "OsiriX Report SR") {
                    // The study's own archive of its attached report is a
                    // copy of that file. If they differ, the editor saved
                    // during the archive: keep the file the editor has open,
                    // and the next synchronization archives it again.
                    let reportUpToDate = ReportArchiveIndexing.isIndexingOwnArchive(atPath: newFile) ||
                        DicomDatabaseReportsHaveSameContents(study?.reportURL, preparedReportPath)

                    if reportUpToDate == false {
                        let reportSR = study?.reportImage()

                        if let reportSR, reportSR === image { // Because we can have multiple reports -> only the most recent one is valid
                            var reportURL: String? = nil
                            let reportPath = preparedReportPath

                            if let reportPath {
                                if (reportPath as NSString).length > 8 && (reportPath.hasPrefix("http://") || reportPath.hasPrefix("https://")) {
                                    reportURL = reportPath
                                } else { // It's a file!
                                    var reportError: NSError? = nil
                                    reportURL = DicomDatabasePrepareImportedReport(self.managedObjectContext, reportPath, reportsDirPath, &reportError)
                                    if reportURL == nil {
                                        NSException(name: NSExceptionName("ReportImport"),
                                                    reason: String(format: "Could not prepare the extracted report: %@", DicomDatabaseObjC.arg(reportError?.localizedDescription)),
                                                    userInfo: nil).raise()
                                    }
                                }

                                NSLog("--- DICOM SR -> Report : %@", DicomDatabaseObjC.arg(curDict.value(forKey: "patientName")))
                            }

                            study?.willChangeValue(forKey: "reportURL")
                            if objcLength(reportURL) > 0 {
                                study?.setPrimitiveValue(reportURL, forKey: "reportURL")
                            } else {
                                study?.setPrimitiveValue(nil, forKey: "reportURL")
                            }
                            study?.didChangeValue(forKey: "reportURL")
                        }
                    }
                }

                DicomDatabaseObjC.add(image, to: added.addedImageObjects)

                added.addImage(image, forCreator: imagePrivateInformationCreatorUID, complete: false)

                if DICOMSR == false && curDict.value(forKey: "album") != nil {
                    addToAlbum(curDict.value(forKey: "album"), image: image)
                }
            } else {
                if DICOMSR == false {
                    seriesTable?.setValue(today, forKey: "dateAdded")
                    study?.dateAdded = today
                }
            }
        }
    }

    /// The comments, the state and the key frames a described file brings.
    private final func fillComments(_ curDict: NSMutableDictionary, image: DicomImage?, seriesTable: NSManagedObject?, study: DicomStudy?, frame f: Int32,
                              settings: DicomDatabaseImportSettings, generatedByOsiriX: Bool) {
        if settings.commentsAutoFill, let commentsAutoFill = curDict.object(forKey: "commentsAutoFill"), let commentField = settings.commentField {
            seriesTable?.willChangeValue(forKey: commentField)
            study?.willChangeValue(forKey: commentField)

            if settings.commentsAutoFillSeriesLevel {
                seriesTable?.setPrimitiveValue(commentsAutoFill, forKey: commentField)
            }

            if settings.commentsAutoFillStudyLevel {
                if objcLength(commentsAutoFill) > objcLength(study?.value(forKey: commentField)) {
                    study?.setPrimitiveValue(commentsAutoFill, forKey: commentField)
                }
            }

            seriesTable?.didChangeValue(forKey: commentField)
            study?.didChangeValue(forKey: commentField)
        }

        if generatedByOsiriX == false && objcLength(curDict.object(forKey: "seriesComments")) > 0 {
            seriesTable?.willChangeValue(forKey: "comment")
            seriesTable?.setPrimitiveValue(curDict.object(forKey: "seriesComments"), forKey: "comment")
            seriesTable?.didChangeValue(forKey: "comment")
        }

        if generatedByOsiriX == false && objcLength(curDict.object(forKey: "studyComments")) > 0 {
            study?.willChangeValue(forKey: "comment")
            study?.setPrimitiveValue(curDict.object(forKey: "studyComments"), forKey: "comment")
            study?.didChangeValue(forKey: "comment")
        }

        if generatedByOsiriX == false && objcIntValue(study?.value(forKey: "stateText")) == 0 && objcIntValue(curDict.object(forKey: "stateText")) != 0 {
            study?.willChangeValue(forKey: "stateText")
            study?.setPrimitiveValue(curDict.object(forKey: "stateText"), forKey: "stateText")
            study?.didChangeValue(forKey: "stateText")
        }

        if generatedByOsiriX == false, let keyFrames = curDict.object(forKey: "keyFrames") {
            if let exception = DicomDatabaseObjC.attempt({
                for k in (keyFrames as? NSArray) ?? [] {
                    if objcIntValue(k) == f { // corresponding frame
                        image?.willChangeValue(forKey: "storedIsKeyImage")
                        image?.setPrimitiveValue(NSNumber(value: true), forKey: "storedIsKeyImage")
                        image?.didChangeValue(forKey: "storedIsKeyImage")
                        break
                    }
                }
            }) {
                DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase addFilesDescribedInDictionaries:postNotifications:rereadExistingItems:generatedByOsiriX:importedFiles:returnArray:]")
            }
        }
    }

    /// Adds the study of an image to the album a described file names, or to
    /// "other", made when there is none.
    private final func addToAlbum(_ albumName: Any?, image: DicomImage?) {
        let albumArray = (self.albums() as NSArray?) ?? NSArray()

        var album: NSManagedObject? = nil
        for case let candidate as NSManagedObject in albumArray where isEqualString(candidate.value(forKey: "name"), albumName as? String) {
            album = candidate
            break
        }

        if album == nil {
            for case let candidate as NSManagedObject in albumArray where isEqualString(candidate.value(forKey: "name"), "other") {
                album = candidate
                break
            }

            if album == nil {
                album = NSEntityDescription.insertNewObject(forEntityName: "Album", into: self.managedObjectContext)
                album?.setValue("other", forKey: "name")

                NotificationCenter.default.post(name: .O2DatabaseInvalidateAlbumsCache, object: self, userInfo: nil)
            }
        }

        // add the file to the album
        if let album, (album.value(forKey: "smartAlbum") as? NSNumber)?.boolValue != true {
            let studies = album.mutableSetValue(forKey: "studies")
            addObject(image?.value(forKeyPath: "series.study"), to: studies)
            (image?.value(forKeyPath: "series.study") as? DicomStudy)?.archiveAnnotationsAsDICOMSR()
        }
    }

    /// The notifications of what an import added, the auto-routing, and the
    /// notice of new images: publishImportChanges of the former method.
    private final func publish(_ added: DicomDatabaseImportBatch, postNotifications: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool, returnArray: Bool) {
        let thread = Thread.current
        let addedImageObjects = added.addedImageObjects
        if let exception = DicomDatabaseObjC.attempt({
            thread.progress = -1

            var notificationString: String? = nil
            var notificationStringNewStudy: String? = nil

            if let exception = DicomDatabaseObjC.attempt({
                autoreleasepool {
                    if let exception = DicomDatabaseObjC.attempt({
                        let center = NotificationCenter.default
                        if returnArray {
                            center.post(name: ._O2AddToDBAnyway, object: self,
                                        userInfo: DicomDatabaseObjC.dictionary([(addedImageObjects, OsirixAddToDBNotificationImagesArray), (added.addedImagesPerCreatorUID, OsirixAddToDBNotificationImagesPerAETDictionary)]) as? [AnyHashable: Any])

                            center.post(name: ._O2AddToDBAnywayComplete, object: self,
                                        userInfo: DicomDatabaseObjC.dictionary([(added.completeAddedImageObjects, OsirixAddToDBNotificationImagesArray), (added.completeAddedImagesPerCreatorUID, OsirixAddToDBNotificationImagesPerAETDictionary)]) as? [AnyHashable: Any])
                        }

                        if postNotifications {
                            if added.newStudy {
                                center.postNotificationOnMainThread(name: NSNotification.Name.OsirixAddNewStudiesDB.rawValue as NSString, object: self, userInfo: [OsirixAddToDBNotificationImagesArray: added.newStudies] as NSDictionary)
                            }

                            center.postNotificationOnMainThread(name: NSNotification.Name.OsirixAddToDB.rawValue as NSString, object: self,
                                                                    userInfo: DicomDatabaseObjC.dictionary([(addedImageObjects, OsirixAddToDBNotificationImagesArray), (added.addedImagesPerCreatorUID, OsirixAddToDBNotificationImagesPerAETDictionary)]))

                            center.postNotificationOnMainThread(name: NSNotification.Name.OsirixAddToDBComplete.rawValue as NSString, object: self,
                                                                    userInfo: DicomDatabaseObjC.dictionary([(added.completeAddedImageObjects, OsirixAddToDBNotificationImagesArray), (added.completeAddedImagesPerCreatorUID, OsirixAddToDBNotificationImagesPerAETDictionary)]))
                        }
                    }) {
                        DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase addFilesDescribedInDictionaries:postNotifications:rereadExistingItems:generatedByOsiriX:importedFiles:returnArray:]_block_invoke")
                    }
                }

                if postNotifications {
                    if let addedImageObjects, addedImageObjects.count > 0 && generatedByOsiriX == false {
                        let first = addedImageObjects.object(at: 0) as AnyObject
                        notificationString = String(format: NSLocalizedString("Patient: %@\r%@ to the database", comment: ""), DicomDatabaseObjC.arg(first.value(forKeyPath: "series.study.name")),
                                                    DicomDatabaseObjC.localizedCount(addedImageObjects.count, NSLocalizedString("image added", comment: ""), NSLocalizedString("images added", comment: "")))
                        notificationStringNewStudy = String(format: NSLocalizedString("%@\r%@", comment: ""), DicomDatabaseObjC.arg(first.value(forKeyPath: "series.study.name")),
                                                            DicomDatabaseObjC.arg(first.value(forKeyPath: "series.study.studyName")))
                    }
                }
                // No auto-routing in Protected Mode; the rules stay as they are saved.
                if self.isLocal() && returnArray && UserDefaults.standard.bool(forKey: "AUTOROUTINGACTIVATED") && !ProtectedMode.isActive &&
                    self.allowAutorouting(withPostNotifications: postNotifications, rereadExistingItems: rereadExistingItems) {
                    // What set the routing going. Without it a send that repeats
                    // cannot be told from one the rules asked for.
                    NSLog(" Autorouting trigger: %d image(s) %@", Int32(truncatingIfNeeded: addedImageObjects?.count ?? 0),
                          rereadExistingItems ? "re-read from disk" : "added to the database")
                    self.alertToApplyRoutingRules(nil, toImages: addedImageObjects as? [Any])
                }
            }) {
                DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase addFilesDescribedInDictionaries:postNotifications:rereadExistingItems:generatedByOsiriX:importedFiles:returnArray:]_block_invoke")
            }

            self.timeOfLastModification = Date.timeIntervalSinceReferenceDate
            if postNotifications {
                self.notifyImport(imagesAdded: notificationString, newStudy: added.newStudy ? notificationStringNewStudy : nil)
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase addFilesDescribedInDictionaries:postNotifications:rereadExistingItems:generatedByOsiriX:importedFiles:returnArray:]_block_invoke")
        }
    }
}

/// What one -addFilesDescribedInDictionaries: added: the images, by the AE
/// title that made them, those it added or re-read (complete) and those it
/// filled; the new studies; the reports it could not read. The arrays exist
/// only when the caller wants them returned, as before.
final class DicomDatabaseImportBatch {
    var rejectedReports = 0
    let newStudies = NSMutableArray()
    var newStudy = false
    let addedImageObjects: NSMutableArray?
    let completeAddedImageObjects: NSMutableArray?
    let addedImagesPerCreatorUID: NSMutableDictionary?
    let completeAddedImagesPerCreatorUID: NSMutableDictionary?

    init(returnArray: Bool, capacity: Int) {
        addedImageObjects = returnArray ? NSMutableArray(capacity: capacity) : nil
        completeAddedImageObjects = returnArray ? NSMutableArray(capacity: capacity) : nil
        addedImagesPerCreatorUID = returnArray ? NSMutableDictionary() : nil
        completeAddedImagesPerCreatorUID = returnArray ? NSMutableDictionary() : nil
    }

    /// Adds the image to the list of its creator, made on first use.
    func addImage(_ image: DicomImage?, forCreator creator: String?, complete: Bool) {
        let dictionary = complete ? completeAddedImagesPerCreatorUID : addedImagesPerCreatorUID
        var images = creator.flatMap { dictionary?.object(forKey: $0) } as? NSMutableArray
        if images == nil {
            let made = NSMutableArray()
            images = made
            if let dictionary {
                if let creator {
                    dictionary.setObject(made, forKey: creator as NSString)
                } else { // -setObject:forKey: raised on a nil key
                    _ = dictionary.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: made, with: nil)
                }
            }
        }
        DicomDatabaseObjC.add(image, to: images)
    }
}

/// The study, the series and the identifiers of the file read last, which the
/// next file of the same study and series reuses.
final class DicomDatabaseImportCursor {
    var study: DicomStudy?
    var series: NSManagedObject?
    var studyID: String?
    var patientUID: String?
    var seriesID: String?
    var newObject = false
    var newFile: String?
}

/// The preferences an import reads once.
struct DicomDatabaseImportSettings {
    let combineProjectionSeries: Bool
    let combineProjectionSeriesMode: Int
    let commentsAutoFill: Bool
    let deleteFileListener: Bool
    let commentField: String?
    let commentsAutoFillSeriesLevel: Bool
    let commentsAutoFillStudyLevel: Bool
}
