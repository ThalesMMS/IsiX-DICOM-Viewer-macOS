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
import IsiXDatabase
import IsiXDICOMDataset
import IsiXDICOMFile
import IsiXPreferences
import PDFKit

// The file promises of a database drag: a row or a thumbnail dragged to the
// Finder becomes a folder of DICOM files, of JPEG images and PDF reports, or
// a JPEG of the frame shown. Everything the drop needs is captured when the
// drag begins; the files are written on an activity thread to a staging
// folder beside the destination, and moved into place only when everything
// succeeded. The DICOM files are exported by DICOMFolderExport; the names and
// the rules are IsiXDatabase's BatchExportPlan and ExportStaging.

/// `[item isDistant]` of an `id`: NO for nil.
@MainActor private func isDistant(_ item: Any?) -> Bool {
    (item as AnyObject?)?.isDistant?() ?? false
}

/// `[item XID]` of an `id`: nil for nil.
@MainActor private func xid(_ item: Any?) -> String? {
    guard let xid = (item as AnyObject?)?.xid?() else { return nil }
    return xid
}

/// `[NSError errorWithDomain: NSCocoaErrorDomain code: NSUserCancelledError userInfo: nil]`.
nonisolated private func userCancelledError() -> NSError {
    NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
}

/// What a database drag captured when it began: the objects, the database
/// they belong to and the export settings of that moment. The objects are
/// read again on a private-queue database of their own, never through these
/// references; the database is only asked for that independent one.
private struct DatabaseFilePromiseSnapshot: @unchecked Sendable {
    let database: DicomDatabase?
    let jpeg: Bool
    let rootObjectIDs: [NSManagedObjectID]
    let folderTreeTag: Int
    let compressionTag: Int
    let addDICOMDIR: Bool
    let encrypt: Bool
    let password: String
}

/// A dragged report to render as a PDF once every image is written.
private struct ReportFileExport {
    let path: String
    let sopClassUID: String
    let destination: URL?
}

/// The activity thread of one drop: a Thread so that the Activity window
/// lists it, shows its progress and status, and can cancel it.
private final class DatabaseFilePromiseActivity: Thread {
    private let work: @Sendable () -> Void

    init(work: @escaping @Sendable () -> Void) {
        self.work = work
        super.init()
    }

    override func main() { work() }
}

/// The writers a database drag hands AppKit, made by the browser that drags.
@MainActor struct DatabaseFilePromiseWriter {

    let browser: BrowserController
    let preferences: any PreferenceStore

    // The writer a database drag hands AppKit. Everything the drop will need is
    // captured here: object identifiers, the database, the export settings. The
    // selection can change, the window can close, the drop reads none of it.
    func promise(forDatabaseObjects items: [Any]?, asJPEG jpeg: Bool) -> (any NSPasteboardWriting)? {
        var rootObjectIDs: [NSManagedObjectID] = []
        var xids: [String] = []
        var names: [String] = []
        for item in items ?? [] {
            if isDistant(item) || ((xid(item) as NSString?)?.length ?? 0) == 0 { return nil }
            guard let managedObject = item as? NSManagedObject, !managedObject.isDeleted else { return nil }
            if !(item is DicomStudy) && !(item is DicomSeries) && !(item is DicomImage) { return nil }
            rootObjectIDs.append(managedObject.objectID)
            xids.append(xid(item) ?? "")
            let name: String? = if let image = item as? DicomImage { image.series?.name }
                else if let series = item as? DicomSeries { series.name } else { (item as? DicomStudy)?.name }
            names.append(name ?? "")
        }
        if rootObjectIDs.isEmpty { return nil }

        let snapshot = DatabaseFilePromiseSnapshot(
            database: browser.database, jpeg: jpeg, rootObjectIDs: rootObjectIDs,
            folderTreeTag: browser.horos_folderTree?.selectedTag() ?? 0,
            compressionTag: browser.horos_compressionMatrix?.selectedTag() ?? 0,
            addDICOMDIR: preferences[ApplicationPreferences.addDICOMDIRForExport],
            encrypt: preferences[ApplicationPreferences.encryptsExport],
            password: browser.passwordForExportEncryption ?? "")

        let promise = DatabaseFilePromise.folderPromise()
        promise.exportName = BatchExportPlan.exportName(itemNames: names, asJPEG: jpeg)
        if !jpeg {
            promise.objectXIDs = try? PropertyListSerialization.data(fromPropertyList: xids, format: .binary, options: 0)
            promise.extraTypes = BrowserController.databaseObjectXIDsPasteboardTypes() ?? []
        }
        let browser = self.browser, preferences = self.preferences
        promise.setWriter { url, completion in
            // A thread cancelled before it starts never runs; the guard still answers the drop.
            let completionGuard = PromiseCompletionGuard(completion: completion)
            let thread = DatabaseFilePromiseActivity {
                Self.write(snapshot, to: url, browser: browser, preferences: preferences, completionGuard: completionGuard)
            }
            thread.name = NSLocalizedString("Exporting...", comment: "")
            thread.supportsCancel = true
            ThreadsManager.default().addThreadAndStart(thread)
            completionGuard.watch(thread: thread)
        }
        return promise
    }

    // A thumbnail's displayed frame, captured when the gesture began.
    static func promise(forJPEGData data: Data?, name: String?) -> (any NSPasteboardWriting)? {
        guard let data, data.count > 0 else { return nil }
        let promise = DatabaseFilePromise.jpegPromise()
        promise.exportName = name ?? ""
        promise.setWriter { url, completion in
            Task.detached(priority: .utility) {
                autoreleasepool {
                    var error: Error? = nil
                    do {
                        try data.write(to: url, options: .withoutOverwriting)
                    } catch let writeError {
                        error = writeError
                    }
                    completion(error)
                }
            }
        }
        return promise
    }

    // The promise's worker, on its activity thread. Object identifiers are
    // resolved on an independent context; pixels and reports are written to a
    // staging directory on the destination's volume and moved into place only
    // when everything succeeded.
    nonisolated private static func write(_ snapshot: DatabaseFilePromiseSnapshot, to destination: URL, browser: BrowserController,
                                          preferences: any PreferenceStore, completionGuard: PromiseCompletionGuard) {
        autoreleasepool {
            let activityThread = Thread.current
            var resultError: Error? = nil
            var staging: URL? = nil
            var reportExports: [ReportFileExport] = []
            if let exception = HorosObjCException.caught({
                // Resolved and read on a private-queue context, on its queue.
                let database = snapshot.database?.privateQueueIndependentDatabase() as? DicomDatabase
                N2ManagedObjectContextPerformAndWait(database?.managedObjectContext) {
                    let jpeg = snapshot.jpeg
                    var error: Error? = nil
                    let objects = database?.objects(withIDs: snapshot.rootObjectIDs) ?? []
                    if objects.count != snapshot.rootObjectIDs.count {
                        error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The dragged images are no longer available.", comment: "")])
                    }
                    // The images in the order they come, each once.
                    var images: [DicomImage] = []
                    var added = Set<ObjectIdentifier>()
                    func add(_ list: [Any]) {
                        for case let image as DicomImage in list where added.insert(ObjectIdentifier(image)).inserted {
                            images.append(image)
                        }
                    }
                    var wholeSeriesIDs = Set<NSManagedObjectID>()
                    for object in objects {
                        if error != nil { break }
                        let object = object as? NSManagedObject
                        if object?.isDeleted ?? false {
                            error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: nil)
                            break
                        }
                        if object is DicomStudy {
                            for series in browser.childrenArray(object, onlyImages: false) ?? [] {
                                let series = series as? DicomSeries
                                add(series?.sortedImages() ?? [])
                                if let seriesID = series?.objectID { wholeSeriesIDs.insert(seriesID) }
                            }
                        } else if let series = object as? DicomSeries {
                            add(series.sortedImages() ?? [])
                            wholeSeriesIDs.insert(series.objectID)
                        } else if let image = object as? DicomImage {
                            add([image])
                        }
                    }
                    if jpeg {
                        images = images.filter { image in
                            BatchExportPlan.includesInJPEGExport(imageStorage: image.isImageStorage()?.boolValue ?? false, reportSeries: BrowserController.isReportSeries(forFileExport: image.series))
                        }
                    }
                    var paths: [String] = []
                    paths.reserveCapacity(images.count)
                    if error == nil && images.isEmpty {
                        error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [NSLocalizedDescriptionKey:
                            jpeg ? NSLocalizedString("The dragged selection contains no images or reports that can be exported.", comment: "") : NSLocalizedString("The dragged images are no longer available.", comment: "")])
                    }
                    for image in images {
                        if error != nil { break }
                        if activityThread.isCancelled { error = userCancelledError(); break }
                        let path = (database?.isLocal() ?? false) ? image.completePath() : (database as? RemoteDicomDatabase)?.cacheData(for: image, maxFiles: 50 /* BONJOURPACKETS */)
                        guard let path, (path as NSString).length > 0, FileManager.default.fileExists(atPath: path) else {
                            error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("A dragged image could not be read.", comment: "")])
                            break
                        }
                        paths.append(path)
                    }
                    if error == nil && !jpeg && snapshot.encrypt && snapshot.password.isEmpty {
                        error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Use Export to DICOM Files to set an encryption password before exporting encrypted files.", comment: "")])
                    }
                    if error == nil {
                        do {
                            staging = try ExportStaging.stagingDirectory(for: destination)
                        } catch let stagingError {
                            error = stagingError
                        }
                    }
                    if let staging {
                        if jpeg {
                            error = writeJPEGImages(images, paths: paths, wholeSeriesIDs: wholeSeriesIDs, directory: staging, reportExports: &reportExports, activityThread: activityThread)
                        } else {
                            // The export core stays silent and reports its error in its result.
                            let request = DICOMFolderExportRequest(location: staging.path, files: paths, objects: images.map(\.objectID),
                                                                   addDICOMDIR: snapshot.addDICOMDIR, encrypt: snapshot.encrypt, password: snapshot.password,
                                                                   folderNaming: nil, folderTreeTag: snapshot.folderTreeTag, compressionTag: snapshot.compressionTag,
                                                                   quietErrors: true)
                            error = DICOMFolderExport(preferences: preferences).run(request, for: browser).error
                            if error == nil && activityThread.isCancelled {
                                error = userCancelledError()
                            }
                        }
                    }
                    resultError = error
                    if resultError == nil {
                        resultError = writeReportFileExports(reportExports, activityThread: activityThread)
                    }
                    if resultError == nil && activityThread.isCancelled {
                        resultError = userCancelledError()
                    }
                    if resultError == nil && !(staging.map { ExportStaging.stagingHasContent($0) } ?? false) {
                        resultError = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The export produced no files.", comment: "")])
                    }
                    if resultError == nil, let staging {
                        var commitError: Error? = nil
                        do {
                            try ExportStaging.commit(staging: staging, to: destination)
                        } catch let error {
                            commitError = error
                        }
                        resultError = commitError
                        if resultError == nil { activityThread.progress = 1.0 }
                    }
                }
            }) {
                resultError = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: exception.reason ?? "Image export failed."])
            }
            if let staging {
                ExportStaging.discard(staging: staging)
            }
            completionGuard.fire(error: resultError)
        }
    }

    // The JPEG images of the drop, a folder per series, every frame of a
    // whole series; the reports are left for their PDF.
    nonisolated private static func writeJPEGImages(_ images: [DicomImage], paths: [String], wholeSeriesIDs: Set<NSManagedObjectID>, directory: URL,
                                                    reportExports: inout [ReportFileExport], activityThread: Thread) -> Error? {
        var seriesDirectories: [NSManagedObjectID: URL] = [:]
        var reportPaths = Set<String>()
        var completedImages: UInt = 0
        activityThread.progress = 0
        for index in 0..<images.count {
            let image = images[index]
            let isReport = BrowserController.isReportSeries(forFileExport: image.series)
            if isReport && reportPaths.contains(paths[index]) {
                continue // some indexes hold one database image per PDF page
            }
            let seriesID = image.series?.objectID
            let frameCount = isReport ? 1 : BatchExportPlan.frameCount(numberOfFrames: image.numberOfFrames?.intValue ?? 0,
                seriesImageCount: image.series?.images?.count ?? 0, wholeSeries: seriesID.map { wholeSeriesIDs.contains($0) } ?? false)
            let expandFrames = frameCount > 1
            for frame in 0..<max(frameCount, 0) {
                if activityThread.isCancelled {
                    return userCancelledError()
                }
                var seriesDirectory = seriesID.flatMap { seriesDirectories[$0] }
                var error: Error? = nil
                if seriesDirectory == nil {
                    let newDirectory = directory.appendingPathComponent(BatchExportPlan.seriesDirectoryName(index: seriesDirectories.count + 1, seriesName: image.series?.name), isDirectory: true)
                    do {
                        try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: false, attributes: nil)
                    } catch let createError {
                        return createError
                    }
                    seriesDirectory = newDirectory
                    if let seriesID { seriesDirectories[seriesID] = newDirectory }
                }
                if isReport {
                    reportPaths.insert(paths[index])
                    reportExports.append(ReportFileExport(path: paths[index], sopClassUID: image.series?.seriesSOPClassUID ?? "",
                        destination: seriesDirectory?.appendingPathComponent(BatchExportPlan.reportFileName(index: index + 1))))
                    continue
                }
                error = autoreleasepool { () -> Error? in
                    var error: Error? = nil
                    let frameID = expandFrames ? frame : (image.frameID?.intValue ?? 0)
                    let pix = DCMPix(path: paths[index], 0, 1, nil, frameID, image.series?.id?.intValue ?? 0, isBonjour: false, imageObj: image)
                    // As Export to JPEG: the series' saved windowing, otherwise the DICOM defaults.
                    let ww = image.series?.windowWidth?.floatValue ?? 0, wl = image.series?.windowLevel?.floatValue ?? 0
                    if ww != 0 && ww != wl { pix?.checkImageAvailble(ww, wl) }
                    else if let pix { pix.checkImageAvailble(pix.savedWW, pix.savedWL) }
                    var jpeg: Data? = nil
                    if let pix, !pix.notAbleToLoadImage, let representations = pix.image()?.representations {
                        jpeg = NSBitmapImageRep.representationOfImageReps(in: representations, using: .jpeg, properties: [.compressionFactor: 0.9])
                    }
                    if (jpeg?.count ?? 0) == 0 {
                        error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("A dragged image could not be converted to JPEG.", comment: "")])
                    } else if let jpeg, let destination = seriesDirectory?.appendingPathComponent(BatchExportPlan.imageFileName(index: index + 1, frame: frameID)) {
                        do {
                            try jpeg.write(to: destination, options: .withoutOverwriting)
                        } catch let writeError {
                            error = writeError
                        }
                    }
                    return error
                }
                if let error { return error }
                activityThread.progress = CGFloat((Double(completedImages) + Double(frame + 1) / Double(frameCount)) / Double(images.count))
                activityThread.status = String(format: NSLocalizedString("JPEG %lu of %lu (frame %ld of %ld)", comment: ""), UInt(index + 1), UInt(images.count), frame + 1, frameCount)
            }
            if !isReport { completedImages += 1 }
        }
        return nil
    }

    // Reports leave the managed-object context before rendering: the SR renderer
    // runs external tools and the encapsulated PDF is read from the file.
    nonisolated private static func writeReportFileExports(_ reports: [ReportFileExport], activityThread: Thread) -> Error? {
        let startingProgress = Float(activityThread.progress)
        for index in 0..<reports.count {
            if activityThread.isCancelled {
                return userCancelledError()
            }
            activityThread.status = String(format: NSLocalizedString("PDF report %lu of %lu", comment: ""), UInt(index + 1), UInt(reports.count))
            let error = autoreleasepool { () -> Error? in
                var error: Error? = nil
                let report = reports[index]
                let destination = report.destination
                let path = report.path
                var data: Data? = nil
                if let destinationPath = destination?.path, FileManager.default.fileExists(atPath: destinationPath) {
                    error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: nil)
                } else if BatchExportPlan.isEncapsulatedPDF(sopClassUID: report.sopClassUID) {
                    data = DCMObject.object(contentsOfFile: path)?.attributeValue(withName: "EncapsulatedDocument") as? Data
                } else if BatchExportPlan.isStructuredReport(sopClassUID: report.sopClassUID) {
                    data = DicomFile(path)?.pdfImageRep()?.pdfRepresentation
                } else {
                    do {
                        data = try Data(contentsOf: URL(fileURLWithPath: path))
                    } catch let readError {
                        error = readError
                    }
                }
                if error == nil {
                    let document = (data?.count ?? 0) > 0 ? data.flatMap { PDFDocument(data: $0) } : nil
                    if (document?.pageCount ?? 0) > 0, let data {
                        do {
                            // A nil destination, which the JPEG writer never records, is refused as Foundation refuses it.
                            guard let destination else { throw CocoaError(.fileWriteInvalidFileName) }
                            try data.write(to: destination, options: .withoutOverwriting)
                        } catch let writeError {
                            error = writeError
                        }
                    } else {
                        error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("A dragged report could not be exported as PDF.", comment: "")])
                    }
                }
                return error
            }
            if let error { return error }
            activityThread.progress = CGFloat(Double(startingProgress) + (1.0 - Double(startingProgress)) * Double(index + 1) / Double(reports.count))
        }
        return nil
    }
}
