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
import PDFKit

// The "database drag export (#605)" block of BrowserController, from
// +isReportSeriesForFileExport: to -databaseOpenStudy:, is implemented in Swift
// since #831: a Swift extension of BrowserController, which stays Objective-C,
// with the same selectors. The instance variables it used are read through
// BrowserController (SwiftIvars); _database is self.database.
//
// Messages to nil: an `id` or a pointer that could be nil is an optional here,
// and a message to it answers nil, 0 or NO through `?.` and `??`. A message
// sent to an `id` of unknown class (-isDistant, -XID) goes through AnyObject
// lookup: an object that does not answer it answers NO or nil instead of
// raising. An @try is HorosObjCException.perform (objcTry), an @synchronized
// is objcSynchronized. The retain/release pairs of the former methods are
// Swift's own references; the autoreleased WaitRendering windows stay alive
// until the pool drains, as before (autoreleaseLater). A predicate argument
// that was nil is NSNull, which NSPredicate compares as nil.

/// `@synchronized (object) { … }`: the same recursive lock, taken on nothing
/// when the object is nil, and left before an exception raised inside goes on.
@inline(__always)
fileprivate func objcSynchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T {
    guard let object else { return body() }
    objc_sync_enter(object)
    var result: T?
    var raised: NSException?
    do {
        try HorosObjCException.perform { result = body() }
    } catch {
        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    objc_sync_exit(object)
    if let raised { raised.raise() }
    return result!
}

/// Runs `body` as an @try block: the NSException it raises is returned.
@inline(__always)
fileprivate func objcTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    return nil
}

/// `[object autorelease]`: released when the current pool drains.
@inline(__always)
fileprivate func autoreleaseLater(_ object: AnyObject?) {
    if let object {
        _ = Unmanaged.passUnretained(object).retain().autorelease()
    }
}

/// `[NSArray arrayWithObjects: a, b, …, nil]`: the list ends at the first nil.
fileprivate func objcArray(_ items: Any?...) -> NSArray {
    let array = NSMutableArray()
    for item in items {
        guard let item else { break }
        array.add(item)
    }
    return array
}

/// A `%@` argument: the object, or "(null)" as Objective-C printed nil.
fileprivate func objcFormatArgument(_ object: Any?) -> CVarArg {
    if let object = object as? NSObject { return object }
    if let object { return String(describing: object) as NSString }
    return "(null)" as NSString
}

/// `[object isEqualToString: string]`: NO when either is nil or not a string.
fileprivate func objcIsEqualToString(_ object: Any?, _ string: Any?) -> Bool {
    guard let object = object as? NSString, let string = string as? String else { return false }
    return object.isEqual(to: string)
}

/// `[object valueForKey: key]` of an `id`, nil for nil.
fileprivate func objcValue(_ object: Any?, _ key: String) -> Any? {
    return (object as? NSObject)?.value(forKey: key)
}

/// `[object intValue]` of an NSNumber or an NSString, 0 for nil.
fileprivate func objcIntValue(_ object: Any?) -> Int32 {
    if let number = object as? NSNumber { return number.int32Value }
    if let string = object as? NSString { return string.intValue }
    return 0
}

/// `[object integerValue]` of an NSNumber or an NSString, 0 for nil.
fileprivate func objcIntegerValue(_ object: Any?) -> Int {
    if let number = object as? NSNumber { return number.intValue }
    if let string = object as? NSString { return string.integerValue }
    return 0
}

/// `[object floatValue]` of an NSNumber or an NSString, 0 for nil.
fileprivate func objcFloatValue(_ object: Any?) -> Float {
    if let number = object as? NSNumber { return number.floatValue }
    if let string = object as? NSString { return string.floatValue }
    return 0
}

/// `[object boolValue]` of an NSNumber or an NSString, NO for nil.
fileprivate func objcBoolValue(_ object: Any?) -> Bool {
    if let number = object as? NSNumber { return number.boolValue }
    if let string = object as? NSString { return string.boolValue }
    return false
}

/// `[item isDistant]` of an `id`: NO for nil.
fileprivate func objcIsDistant(_ item: Any?) -> Bool {
    return (item as AnyObject?)?.isDistant?() ?? false
}

/// `[item XID]` of an `id`: nil for nil.
fileprivate func objcXID(_ item: Any?) -> NSString? {
    guard let xid = (item as AnyObject?)?.xid?() else { return nil }
    return xid as NSString?
}

/// `[NSPredicate predicateWithFormat: format, arguments…]`, a nil argument
/// being NSNull.
fileprivate func objcPredicate(_ format: String, _ arguments: Any?...) -> NSPredicate {
    return NSPredicate(format: format, argumentArray: arguments.map { $0 ?? NSNull() })
}

/// `[NSError errorWithDomain: NSCocoaErrorDomain code: NSUserCancelledError userInfo: nil]`.
fileprivate func userCancelledError() -> NSError {
    return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
}

/// `[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent: component]`.
fileprivate func resourcePath(_ component: String) -> String? {
    return (Bundle.main.resourcePath as NSString?)?.appendingPathComponent(component)
}

public extension BrowserController {

    // MARK: database drag export (#605)

    // A report a person would want as a PDF, as opposed to the application's own SRs.
    @objc(isReportSeriesForFileExport:)
    nonisolated class func isReportSeries(forFileExport series: DicomSeries!) -> Bool {
        return BatchExportPlan.isReportSeries(name: series?.name, sopClassUID: series?.seriesSOPClassUID, modality: series?.modality)
    }

    // Every database object identifier on the pasteboard: one item per dragged row.
    @objc(databaseObjectXIDsOnPasteboard:)
    class func databaseObjectXIDs(on pasteboard: NSPasteboard!) -> [Any]! {
        guard let pasteboard else { return [] }
        return PasteboardObjectIdentifiers.identifiers(on: pasteboard, types: BrowserController.databaseObjectXIDsPasteboardTypes() ?? [])
    }

    @objc(filePromiseForDatabaseObjects:)
    func filePromise(forDatabaseObjects items: [Any]!) -> (any NSPasteboardWriting)! {
        return self.filePromise(forDatabaseObjects: items, asJPEG: false)
    }

    // The writer a database drag hands AppKit. Everything the drop will need is
    // captured here: object identifiers, the database, the export settings. The
    // selection can change, the window can close, the drop reads none of it.
    @objc(filePromiseForDatabaseObjects:asJPEG:)
    func filePromise(forDatabaseObjects items: [Any]!, asJPEG jpeg: Bool) -> (any NSPasteboardWriting)! {
        let objects = NSMutableArray()
        let xids = NSMutableArray()
        var names: [String] = []
        for item in items ?? [] {
            if objcIsDistant(item) || (objcXID(item)?.length ?? 0) == 0 { return nil }
            guard let managedObject = item as? NSManagedObject, !managedObject.isDeleted else { return nil }
            if !(item is DicomStudy) && !(item is DicomSeries) && !(item is DicomImage) { return nil }
            objects.add(item)
            xids.add(objcXID(item) ?? "")
            let name: String? = (item is DicomImage) ? (item as? DicomImage)?.series?.name : managedObject.value(forKey: "name") as? String
            names.append(name ?? "")
        }
        if objects.count == 0 { return nil }

        let snapshot: NSDictionary = [
            "database": self.database as Any,
            "jpeg": NSNumber(value: jpeg),
            "rootObjectIDs": objects.value(forKey: "objectID") as Any,
            "folderTreeTag": NSNumber(value: self.horos_folderTree?.selectedTag() ?? 0),
            "compressionTag": NSNumber(value: self.horos_compressionMatrix?.selectedTag() ?? 0),
            "addDICOMDIR": NSNumber(value: UserDefaults.standard.bool(forKey: "AddDICOMDIRForExport")),
            "encrypt": NSNumber(value: UserDefaults.standard.bool(forKey: "encryptForExport")),
            "password": self.passwordForExportEncryption ?? ""]

        let promise = DatabaseFilePromise.folderPromise()
        promise.exportName = BatchExportPlan.exportName(itemNames: names, asJPEG: jpeg)
        if !jpeg {
            promise.objectXIDs = try? PropertyListSerialization.data(fromPropertyList: xids, format: .binary, options: 0)
            promise.extraTypes = BrowserController.databaseObjectXIDsPasteboardTypes() ?? []
        }
        promise.setWriter { url, completion in
            let parameters = NSMutableDictionary(dictionary: snapshot)
            parameters["destinationURL"] = url
            // A thread cancelled before it starts never runs; the guard still answers the drop.
            parameters["completionGuard"] = PromiseCompletionGuard(completion: completion)
            let thread = Thread(target: self, selector: #selector(BrowserController.writeDatabaseFilePromise(_:)), object: parameters)
            thread.name = NSLocalizedString("Exporting...", comment: "")
            thread.supportsCancel = true
            ThreadsManager.default().addThreadAndStart(thread)
            (parameters["completionGuard"] as? PromiseCompletionGuard)?.watch(thread: thread)
        }
        return promise
    }

    // A thumbnail's displayed frame, captured when the gesture began.
    @objc(filePromiseForJPEGData:name:)
    func filePromise(forJPEGData data: Data!, name: String!) -> (any NSPasteboardWriting)! {
        guard let data, data.count > 0 else { return nil }
        let promise = DatabaseFilePromise.jpegPromise()
        promise.exportName = name ?? ""
        promise.setWriter { url, completion in
            DispatchQueue.global(qos: .utility).async {
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

    @objc(writeJPEGImages:paths:wholeSeriesIDs:directory:reportExports:activityThread:)
    nonisolated func writeJPEGImages(_ images: [Any]!, paths: [Any]!, wholeSeriesIDs: Set<AnyHashable>!, directory: URL!, reportExports: NSMutableArray!, activityThread: Thread!) -> (any Error)! {
        let images = images ?? [], paths = paths ?? []
        let seriesDirectories = NSMutableDictionary()
        let reportPaths = NSMutableSet()
        var completedImages: UInt = 0
        activityThread?.progress = 0
        for index in 0..<images.count {
            let image = images[index] as? DicomImage
            let isReport = BrowserController.isReportSeries(forFileExport: image?.series)
            if isReport && reportPaths.contains(paths[index]) {
                continue // some indexes hold one database image per PDF page
            }
            let seriesID = image?.series?.objectID
            let frameCount = isReport ? 1 : BatchExportPlan.frameCount(numberOfFrames: image?.numberOfFrames?.intValue ?? 0,
                seriesImageCount: image?.series?.images?.count ?? 0, wholeSeries: seriesID.map { wholeSeriesIDs?.contains($0) ?? false } ?? false)
            let expandFrames = frameCount > 1
            for frame in 0..<max(frameCount, 0) {
                if activityThread?.isCancelled ?? false {
                    return userCancelledError()
                }
                var seriesDirectory = seriesID.flatMap { seriesDirectories[$0] } as? URL
                var error: Error? = nil
                if seriesDirectory == nil {
                    seriesDirectory = directory?.appendingPathComponent(BatchExportPlan.seriesDirectoryName(index: seriesDirectories.count + 1, seriesName: image?.series?.name), isDirectory: true)
                    do {
                        // A nil directory, which the worker never passes, is refused as Foundation refuses it.
                        guard let seriesDirectory else { throw CocoaError(.fileWriteInvalidFileName) }
                        try FileManager.default.createDirectory(at: seriesDirectory, withIntermediateDirectories: false, attributes: nil)
                    } catch let createError {
                        return createError
                    }
                    if let seriesID { seriesDirectories[seriesID] = seriesDirectory }
                }
                if isReport {
                    reportPaths.add(paths[index])
                    reportExports?.add(["path": paths[index], "sopClassUID": image?.series?.seriesSOPClassUID ?? "",
                        "destination": seriesDirectory?.appendingPathComponent(BatchExportPlan.reportFileName(index: index + 1)) as Any] as NSDictionary)
                    continue
                }
                error = autoreleasepool { () -> Error? in
                    var error: Error? = nil
                    let frameID = expandFrames ? frame : (image?.frameID?.intValue ?? 0)
                    let pix = DCMPix(path: paths[index] as? String, 0, 1, nil, frameID, image?.series?.id?.intValue ?? 0, isBonjour: false, imageObj: image)
                    // As Export to JPEG: the series' saved windowing, otherwise the DICOM defaults.
                    let ww = image?.series?.windowWidth?.floatValue ?? 0, wl = image?.series?.windowLevel?.floatValue ?? 0
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
                activityThread?.progress = CGFloat((Double(completedImages) + Double(frame + 1) / Double(frameCount)) / Double(images.count))
                activityThread?.status = String(format: NSLocalizedString("JPEG %lu of %lu (frame %ld of %ld)", comment: ""), UInt(index + 1), UInt(images.count), frame + 1, frameCount)
            }
            if !isReport { completedImages += 1 }
        }
        return nil
    }

    // Reports leave the managed-object context before rendering: the SR renderer
    // runs external tools and the encapsulated PDF is read from the file.
    @objc(writeReportFileExports:activityThread:)
    nonisolated func writeReportFileExports(_ reports: [Any]!, activityThread: Thread!) -> (any Error)! {
        let reports = reports ?? []
        let startingProgress = Float(activityThread?.progress ?? 0)
        for index in 0..<reports.count {
            if activityThread?.isCancelled ?? false {
                return userCancelledError()
            }
            activityThread?.status = String(format: NSLocalizedString("PDF report %lu of %lu", comment: ""), UInt(index + 1), UInt(reports.count))
            let error = autoreleasepool { () -> Error? in
                var error: Error? = nil
                let report = reports[index] as? NSDictionary
                let destination = report?["destination"] as? URL
                let path = report?["path"] as? String
                var data: Data? = nil
                if let destinationPath = destination?.path, FileManager.default.fileExists(atPath: destinationPath) {
                    error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: nil)
                } else if BatchExportPlan.isEncapsulatedPDF(sopClassUID: report?["sopClassUID"] as? String) {
                    data = path.flatMap { HorosDCMTKObject(contentsOfFile: $0) }?.attributeValue(withName: "EncapsulatedDocument") as? Data
                } else if BatchExportPlan.isStructuredReport(sopClassUID: report?["sopClassUID"] as? String) {
                    data = DicomFile(path)?.pdfImageRep()?.pdfRepresentation
                } else {
                    do {
                        data = try NSData(contentsOfFile: path ?? "", options: []) as Data
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
            activityThread?.progress = CGFloat(Double(startingProgress) + (1.0 - Double(startingProgress)) * Double(index + 1) / Double(reports.count))
        }
        return nil
    }

    // The promise's worker. Object identifiers are resolved on an independent
    // context; pixels and reports are written to a staging directory on the
    // destination's volume and moved into place only when everything succeeded.
    @objc(writeDatabaseFilePromise:)
    nonisolated func writeDatabaseFilePromise(_ parameters: NSMutableDictionary!) {
        autoreleasepool {
            let destination = parameters?["destinationURL"] as? URL
            let activityThread = Thread.current
            var resultError: Error? = nil
            var staging: URL? = nil
            let reportExports = NSMutableArray()
            if let exception = objcTry({
                // Resolved and read on a private-queue context, on its queue (#966).
                let database = (parameters?["database"] as? DicomDatabase)?.privateQueueIndependentDatabase() as? DicomDatabase
                N2ManagedObjectContextPerformAndWait(database?.managedObjectContext) {
                    let jpeg = objcBoolValue(parameters?["jpeg"])
                    var error: Error? = nil
                    let rootObjectIDs = parameters?["rootObjectIDs"] as? [Any]
                    let objects = database?.objects(withIDs: rootObjectIDs) ?? []
                    if objects.count != (rootObjectIDs?.count ?? 0) {
                        error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The dragged images are no longer available.", comment: "")])
                    }
                    let selectedImages = NSMutableOrderedSet()
                    let wholeSeriesIDs = NSMutableSet()
                    for object in objects {
                        if error != nil { break }
                        let object = object as? NSManagedObject
                        if object?.isDeleted ?? false {
                            error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: nil)
                            break
                        }
                        if object is DicomStudy {
                            for series in self.childrenArray(object, onlyImages: false) ?? [] {
                                let series = series as? DicomSeries
                                selectedImages.addObjects(from: series?.sortedImages() ?? [])
                                if let seriesID = series?.objectID { wholeSeriesIDs.add(seriesID) }
                            }
                        } else if let series = object as? DicomSeries {
                            selectedImages.addObjects(from: series.sortedImages() ?? [])
                            wholeSeriesIDs.add(series.objectID)
                        } else if let image = object as? DicomImage {
                            selectedImages.add(image)
                        }
                    }
                    var images = selectedImages.array
                    if jpeg {
                        images = images.filter { image in
                            let image = image as? DicomImage
                            return BatchExportPlan.includesInJPEGExport(imageStorage: image?.isImageStorage()?.boolValue ?? false, reportSeries: BrowserController.isReportSeries(forFileExport: image?.series))
                        }
                    }
                    let paths = NSMutableArray(capacity: images.count)
                    if error == nil && images.count == 0 {
                        error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [NSLocalizedDescriptionKey:
                            jpeg ? NSLocalizedString("The dragged selection contains no images or reports that can be exported.", comment: "") : NSLocalizedString("The dragged images are no longer available.", comment: "")])
                    }
                    for image in images {
                        if error != nil { break }
                        if activityThread.isCancelled { error = userCancelledError(); break }
                        let image = image as? DicomImage
                        let path = (database?.isLocal() ?? false) ? image?.completePath() : (database as? RemoteDicomDatabase)?.cacheData(for: image, maxFiles: 50 /* BONJOURPACKETS */)
                        guard let path, (path as NSString).length > 0, FileManager.default.fileExists(atPath: path) else {
                            error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("A dragged image could not be read.", comment: "")])
                            break
                        }
                        paths.add(path)
                    }
                    if error == nil && !jpeg && objcBoolValue(parameters?["encrypt"]) && ((parameters?["password"] as? NSString)?.length ?? 0) == 0 {
                        error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Use Export to DICOM Files to set an encryption password before exporting encrypted files.", comment: "")])
                    }
                    if error == nil, let destination {
                        do {
                            staging = try ExportStaging.stagingDirectory(for: destination)
                        } catch let stagingError {
                            error = stagingError
                        }
                    }
                    if let staging {
                        if jpeg {
                            error = self.writeJPEGImages(images, paths: paths as? [Any], wholeSeriesIDs: wholeSeriesIDs as? Set<AnyHashable>, directory: staging, reportExports: reportExports, activityThread: activityThread)
                        } else {
                            parameters?["location"] = staging.path
                            parameters?["filesToExport"] = paths
                            parameters?["dicomFiles2Export"] = (images as NSArray).value(forKey: "objectID")
                            parameters?["quietErrors"] = NSNumber(value: true)
                            // The export core writes "exportError" into this very dictionary: it is
                            // sent as it is, not as a bridged copy.
                            _ = self.perform(#selector(BrowserController.exportDICOMFileInt(_:)), with: parameters)
                            error = parameters?["exportError"] as? Error
                            if error == nil && activityThread.isCancelled {
                                error = userCancelledError()
                            }
                        }
                    }
                    resultError = error
                    if resultError == nil {
                        resultError = self.writeReportFileExports(reportExports as? [Any], activityThread: activityThread)
                    }
                    if resultError == nil && activityThread.isCancelled {
                        resultError = userCancelledError()
                    }
                    if resultError == nil && !(staging.map { ExportStaging.stagingHasContent($0) } ?? false) {
                        resultError = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The export produced no files.", comment: "")])
                    }
                    if resultError == nil, let staging, let destination {
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
            (parameters?["completionGuard"] as? PromiseCompletionGuard)?.fire(error: resultError)
        }
    }

    // A row is a promise for the folder it exports; a series under a selected
    // study is already inside that study's promise.
    @objc(outlineView:pasteboardWriterForItem:)
    func outlineView(_ outlineView: NSOutlineView!, pasteboardWriterForItem item: Any!) -> (any NSPasteboardWriting)! {
        guard let item, !objcIsDistant(item), (objcXID(item)?.length ?? 0) > 0 else { return nil }
        let parent = outlineView?.parent(forItem: item)
        let parentRow = parent != nil ? (outlineView?.row(forItem: parent) ?? 0) : -1
        if parentRow >= 0 && (outlineView?.isRowSelected(parentRow) ?? false) { return nil }
        return self.filePromise(forDatabaseObjects: [item], asJPEG: NSApp.currentEvent?.modifierFlags.contains(NSEvent.ModifierFlags.option) ?? false)
    }

    @objc(outlineViewItemWillCollapse:)
    func outlineViewItemWillCollapse(_ notification: Notification!) {
        //	[_database lock];

        let object = notification?.userInfo?["NSObject"]

        if objcIsDistant(object) == false {
            (object as? NSObject)?.setValue(NSNumber(value: false), forKey: "expanded")
        }

        var image: DicomImage? = nil

        if (self.horos_matrixViewArray?.count ?? 0) > 0 {
            image = (self.horos_matrixViewArray as NSArray?)?.object(at: 0) as? DicomImage
            if objcIsEqualToString(image?.value(forKey: "type"), "Image") { _ = self.findAndSelectFile(nil, image: image, shouldExpand: false) }
        }

        //	[_database unlock];
    }

    @objc(outlineViewItemWillExpand:)
    func outlineViewItemWillExpand(_ notification: Notification!) {
        //	[_database lock];

        let object = notification?.userInfo?["NSObject"]

        if objcIsDistant(object) == false {
            (object as? NSObject)?.setValue(NSNumber(value: true), forKey: "expanded")
        }

        //	[_database unlock];
    }

    @objc(isUsingExternalViewer:)
    func `is`(usingExternalViewer item: NSManagedObject!) -> Bool {
        var r = false

        N2ManagedObjectContextPerformAndWait(self.database?.managedObjectContext) {
        if objcIsEqualToString(item?.value(forKey: "type"), "Series") {

            // Preserve the existing exception propagation after the queue work.
            let raised = objcTry {
                let images = self.childrenArray(item, onlyImages: false) ?? []

                var im: DicomImage? = nil

                // An NSUInteger against an int: a negative slider value compares as a huge one.
                let sliderValue = Int(self.horos_animationSlider?.intValue ?? 0)
                if UInt(images.count) > UInt(bitPattern: sliderValue) {
                    im = images[sliderValue] as? DicomImage
                } else {
                    im = (item?.value(forKey: "images") as? NSSet)?.anyObject() as? DicomImage
                }

                if objcIsEqualToString(im?.value(forKey: "fileType"), "DICOMMPEG2") {
                    let filePath = im?.value(forKey: "completePath") as? String

                    let reportFailure: @Sendable (Bool) -> Void = { opened in
                        guard !opened else { return }
                        DispatchQueue.main.async {
                            HorosAlertPanel.run(title: NSLocalizedString("MPEG-2 File", comment: ""), message: NSLocalizedString("MPEG-2 DICOM files require the VLC application. Available for free here: http://www.videolan.org/vlc/", comment: ""), defaultButton: nil, alternateButton: nil, otherButton: nil)
                        }
                    }
                    if let filePath {
                        NSWorkspace.shared.openDocument(atPath: filePath, applicationIdentifiers: ["org.videolan.vlc"], completion: reportFailure)
                    } else { reportFailure(false) }
                    Thread.sleep(forTimeInterval: 1)

                    r = true
                }

                // #ifndef OSIRIX_LIGHT

                if (objcIsEqualToString((im?.value(forKey: "modality") as? NSString)?.lowercased, "pdf") || DCMAbstractSyntaxUID.isPDF(im?.value(forKeyPath: "series.seriesSOPClassUID") as? String) || DCMAbstractSyntaxUID.isStructuredReport(im?.value(forKeyPath: "series.seriesSOPClassUID") as? String)) && UserDefaults.standard.bool(forKey: "openPDFwithPreview") {
                    var path: String? = nil

                    if DCMAbstractSyntaxUID.isPDF(im?.value(forKeyPath: "series.seriesSOPClassUID") as? String) {
                        let dcmObject = (im?.value(forKey: "completePath") as? String).flatMap { HorosDCMTKObject(contentsOfFile: $0) }

                        if objcIsEqualToString(dcmObject?.attributeValue(withName: "SOPClassUID"), DCMAbstractSyntaxUID.pdfStorageClassUID()) {
                            let pdfData = dcmObject?.attributeValue(withName: "EncapsulatedDocument") as? Data

                            var filename = dcmObject?.attributeValue(withName: "DocumentTitle") as? String
                            if ((filename as NSString?)?.length ?? 0) <= 0 {
                                filename = "PDFFile.pdf"
                            }

                            if objcIsEqualToString(((filename as NSString?)?.pathExtension as NSString?)?.lowercased, "pdf") == false {
                                filename = (filename as NSString?)?.appendingPathExtension("pdf")
                            }

                            path = (self.database?.tempDirPath() as NSString?)?.appendingPathComponent(filename ?? "")
                            if let path {
                                try? FileManager.default.removeItem(atPath: path)
                                (pdfData as NSData?)?.write(toFile: path, atomically: true)
                            }
                        }
                    } else if DCMAbstractSyntaxUID.isStructuredReport(im?.value(forKeyPath: "series.seriesSOPClassUID") as? String) {
                        FileManager.default.confirmDirectory(atPath: (FileManager.default.tmpDirPath() as NSString).appendingPathComponent("dicomsr_osirix"))

                        let htmlpath = ((((FileManager.default.tmpDirPath() as NSString).appendingPathComponent("dicomsr_osirix") as NSString).appendingPathComponent(((im?.value(forKey: "completePath") as? NSString)?.lastPathComponent) ?? "")) as NSString).appendingPathExtension("xml")

                        if (htmlpath.map { FileManager.default.fileExists(atPath: $0) } ?? false) == false {
                            let aTask = Process()
                            aTask.environment = resourcePath("/dicom.dic").map { ["DCMDICTPATH": $0] }
                            aTask.launchPath = resourcePath("/dsr2html")
                            aTask.arguments = objcArray("+X1", "--unknown-relationship", "--ignore-constraints", "--ignore-item-errors", "--skip-invalid-items", im?.completePathResolved(), htmlpath) as? [String]

                            // The wait had no deadline and the launch could raise. Both
                            // ran on the main thread. A missing conversion leaves no
                            // file, which the PDF path below already has to survive.
                            var taskError: NSError? = nil
                            if HorosRunTaskUntilExit(aTask, 60, &taskError) == false {
                                NSLog("****** dsr2html failed: %@", objcFormatArgument(taskError?.localizedDescription))
                            }
                        }

                        if (htmlpath.flatMap { ($0 as NSString).appendingPathExtension("pdf") }.map { FileManager.default.fileExists(atPath: $0) } ?? false) == false {
                            if let decompress = resourcePath("/Decompress"), FileManager.default.fileExists(atPath: decompress) {
                                let aTask = Process()
                                aTask.launchPath = resourcePath("/Decompress")
                                aTask.arguments = objcArray(htmlpath, "pdfFromURL") as? [String]

                                var taskError: NSError? = nil
                                if HorosRunTaskUntilExit(aTask, 10, &taskError) == false {
                                    NSLog("****** Decompress pdfFromURL failed: %@", objcFormatArgument(taskError?.localizedDescription))
                                }
                            }
                        }

                        path = htmlpath.flatMap { ($0 as NSString).appendingPathExtension("pdf") }
                    } else {
                        path = im?.value(forKey: "completePath") as? String
                    }

                    if let path, NSWorkspace.shared.open(URL(fileURLWithPath: path)) == false {
                        r = false
                    } else {
                        r = true
                    }

                    Thread.sleep(forTimeInterval: 1)
                }

                // RTSTRUCT
                if objcIsEqualToString((im?.value(forKey: "modality") as? NSString)?.lowercased, "rtstruct") {
                    if HorosAlertPanel.runInformational(title: NSLocalizedString("RTSTRUCT", comment: ""),
                                                        message: NSLocalizedString("This series contains RTSTRUCT ROIs. Should I generate the corresponding ROIs on the images series?", comment: ""),
                                                        defaultButton: NSLocalizedString("OK", comment: ""),
                                                        alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                        otherButton: nil) == HorosAlertPanel.defaultResponse {
                        let dcmObj = im?.completePathResolved().flatMap { HorosDCMTKObject(contentsOfFile: $0) }

                        var pix: DCMPix? = nil
                        objcSynchronized(self.horos_previewPixThumbnails) {
                            pix = self.horos_previewPix?.object(at: 0) as? DCMPix  // Should only be one DCMPix associated w/ an RTSTRUCT
                        }

                        pix?.createROIs(fromRTSTRUCT: dcmObj)

                        r = true
                    }
                }

                // #endif
            }


            if let raised { raised.raise() }
        }

        }

        return r
    }

    @objc(databaseOpenStudy:withProtocol:)
    func databaseOpen(_ currentStudy: DicomStudy!, withProtocol currentHangingProtocol: [AnyHashable: Any]!) {
        var restoreNOAutotiling = false
        var WINDOWSIZEVIEWERCopy: Int32 = 0
        if UserDefaults.standard.bool(forKey: "AUTOTILING") != true {
            restoreNOAutotiling = true
            WINDOWSIZEVIEWERCopy = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "WINDOWSIZEVIEWER"))
            UserDefaults.standard.set(true, forKey: "AUTOTILING")
        }

        let children = NSMutableArray(array: self.childrenArray(currentStudy) ?? [])

        //Remove the series that are already displayed
        var alreadyDisplayed: Int32 = 0
        for s in ViewerController.getDisplayedSeries() ?? [] {
            for e in 0..<children.count {
                if objcIsEqualToString(objcValue(s, "seriesInstanceUID"), objcValue(children.object(at: e), "seriesInstanceUID")) {
                    alreadyDisplayed += 1
                }
            }
        }

        if alreadyDisplayed == 0 {
            if currentHangingProtocol?["Sync"] != nil {
                if objcBoolValue(currentHangingProtocol?["Sync"]) {
                    DCMView.setSyncro(Int16(syncroLOC))
                } else {
                    DCMView.setSyncro(Int16(syncroOFF))
                }
            }

            if currentHangingProtocol?["Propagate"] != nil {
                UserDefaults.standard.set(objcBoolValue(currentHangingProtocol?["Propagate"]), forKey: "COPYSETTINGS")
            }

            var seriesArray: NSMutableArray

            if (currentStudy?.imageSeriesContainingPixels(true)?.count ?? 0) > 0 {
                seriesArray = NSMutableArray(array: currentStudy?.imageSeriesContainingPixels(true) as? [Any] ?? [])
            } else {
                seriesArray = NSMutableArray(array: currentStudy?.imageSeries() as? [Any] ?? [])
            }

            // Sort series according to SeriesOrder, if available
            if currentHangingProtocol?["SeriesOrder"] != nil {
                let newSeriesArray = NSMutableArray()

                let caseSensitivityValue = currentHangingProtocol?["SeriesOrderIgnoreCase"]
                let ignoreCase = objcBoolValue(caseSensitivityValue)

                for term in (currentHangingProtocol?["SeriesOrder"] as? NSString)?.components(separatedBy: ",") ?? [] {
                    let term = term.trimmingCharacters(in: .whitespacesAndNewlines)

                    var index = -1
                    for i in 0..<seriesArray.count {
                        let s = seriesArray.object(at: i) as? DicomSeries

                        if ignoreCase {
                            let rangeValue = (s?.name as NSString?)?.range(of: term, options: .caseInsensitive) ?? NSRange(location: 0, length: 0)

                            if rangeValue.length > 0 {
                                index = i
                            }
                        } else {
                            if (s?.name as NSString?)?.n2Contains(term as NSString) ?? false {
                                index = i
                            }
                        }
                    }

                    if index != -1 {
                        newSeriesArray.add(seriesArray.object(at: index))
                        seriesArray.removeObject(at: index)
                    }
                }
                newSeriesArray.addObjects(from: seriesArray as? [Any] ?? [])

                seriesArray = newSeriesArray
            }

            // Prepare the series to be displayed
            var comparatives = NSMutableArray()
            if objcBoolValue(currentHangingProtocol?["Comparative"]) {
                // Find the previous studies
                let numberOfComparative = objcIntValue(currentHangingProtocol?["NumberOfComparativeToDisplay"])

                //PreviousStudySameModality , PreviousStudySameDescription

                for s in NSArray(array: self.subSearch(forComparativeStudies: currentStudy) ?? []) {
                    var comparativeStudy: AnyObject? = nil

                    // #ifndef OSIRIX_LIGHT
                    if let study = s as? DCMTKStudyQueryNode {
                        if !objcIsEqualToString(study.studyInstanceUID(), currentStudy?.value(forKey: "studyInstanceUID")) {
                            comparativeStudy = study

                            if objcBoolValue(currentHangingProtocol?["PreviousStudySameModality"]) {
                                if objcIsEqualToString(study.modality(), currentStudy?.value(forKey: "modality")) == false {
                                    comparativeStudy = nil
                                }
                            }

                            if objcBoolValue(currentHangingProtocol?["PreviousStudySameDescription"]) {
                                if objcBoolValue(currentHangingProtocol?["isDefaultProtocolForModality"]) {
                                    if objcIsEqualToString(study.studyName(), currentStudy?.value(forKey: "studyName")) == false {
                                        comparativeStudy = nil
                                    }
                                } else {
                                    let searchRange = (study.studyName() as NSString?)?.range(of: (currentHangingProtocol?["Study Description"] as? String) ?? "", options: [.caseInsensitive, .literal]) ?? NSRange(location: 0, length: 0)
                                    if searchRange.location == NSNotFound {
                                        comparativeStudy = nil
                                    }
                                }
                            }

                            if comparativeStudy != nil {
                                self.retrieveComparativeStudy(comparativeStudy as? DCMTKStudyQueryNode, select: false, open: false, showGUI: false)
                            }
                        }
                    }
                    // #endif

                    if let study = s as? DicomStudy {
                        if !objcIsEqualToString(study.studyInstanceUID, currentStudy?.value(forKey: "studyInstanceUID")) {
                            comparativeStudy = study

                            if objcBoolValue(currentHangingProtocol?["PreviousStudySameModality"]) {
                                if objcIsEqualToString(study.modality, currentStudy?.value(forKey: "modality")) == false {
                                    comparativeStudy = nil
                                }
                            }

                            if objcBoolValue(currentHangingProtocol?["PreviousStudySameDescription"]) {
                                if objcBoolValue(currentHangingProtocol?["isDefaultProtocolForModality"]) {
                                    if objcIsEqualToString(study.studyName, currentStudy?.value(forKey: "studyName")) == false {
                                        comparativeStudy = nil
                                    }
                                } else {
                                    let searchRange = (study.studyName as NSString?)?.range(of: (currentHangingProtocol?["Study Description"] as? String) ?? "", options: [.caseInsensitive, .literal]) ?? NSRange(location: 0, length: 0)
                                    if searchRange.location == NSNotFound {
                                        comparativeStudy = nil
                                    }
                                }
                            }
                        }
                    }

                    if let comparativeStudy {
                        comparatives.add(comparativeStudy)
                    }

                    // An NSUInteger against an int: a negative count compares as a huge one.
                    if UInt(comparatives.count) >= UInt(bitPattern: Int(numberOfComparative)) {
                        break
                    }
                }

                // #ifndef OSIRIX_LIGHT
                // Wait until all distant studies are retrieved
                var w: WaitRendering? = nil
                let timeout = Date.timeIntervalSinceReferenceDate
                var distantStudies = false
                let TIMEOUT: TimeInterval = 30 // #define TIMEOUT 30
                repeat {
                    distantStudies = false

                    // No time for decompression; the setting is shared with the comparative
                    // retrievals that may be running (#849).
                    ListenerCompressionSuspension.shared.begin()

                    for i in 0..<comparatives.count {
                        if let node = comparatives.object(at: i) as? DCMTKStudyQueryNode {
                            //                        [NSThread sleepForTimeInterval: 0.3];
                            //                        [[DicomDatabase activeLocalDatabase] initiateImportFilesFromIncomingDirUnlessAlreadyImporting];

                            _ = self.database?.importFilesFromIncomingDir()

                            let r = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
                            r.predicate = objcPredicate("(studyInstanceUID == %@)", node.studyInstanceUID())

                            var studyArray: [Any]? = nil
                            if let e = objcTry({
                                // We need to receive the 'messages' for the new db objects from the background thread
                                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

                                studyArray = try? self.database?.managedObjectContext?.fetch(r)
                            }) { _N2LogExceptionImpl(e, true, "-[BrowserController databaseOpenStudy:withProtocol:]") }

                            if let study = studyArray?.last as? DicomStudy, (study.imageSeriesContainingPixels(true)?.count ?? 0) > 0 { // We want images !
                                comparatives.replaceObject(at: i, with: study)
                            } else {
                                distantStudies = true
                            }
                        }
                    }

                    ListenerCompressionSuspension.shared.end()

                    if distantStudies && w == nil {
                        w = WaitRendering(NSLocalizedString("Retrieving...", comment: ""))
                        autoreleaseLater(w)
                        w?.showWindow(self)
                    }
                }
                while distantStudies && Date.timeIntervalSinceReferenceDate - timeout < TIMEOUT

                w?.close()
                // #endif
                var i = 0
                while i < comparatives.count {
                    if (comparatives.object(at: i) is DicomStudy) == false {
                        comparatives.removeObject(at: i)
                        i -= 1
                    }
                    i += 1
                }
            }

            // Expand comparatives study according to NumberOfSeriesPerComparative
            if comparatives.count > 0 {
                // Even one series must honor SeriesOrder; missing legacy counts mean one.
                let n = max(1, objcIntegerValue(currentHangingProtocol?["NumberOfSeriesPerComparative"]))

                let newComparatives = NSMutableArray()
                for study in comparatives {
                    let study = study as? DicomStudy
                    var availableSeries = study?.imageSeriesContainingPixels(true) as? [Any] ?? []
                    if availableSeries.count == 0 { availableSeries = study?.imageSeries() as? [Any] ?? [] }
                    var series = NSMutableArray(array: availableSeries)

                    // Sort series according to SeriesOrder, if available
                    if currentHangingProtocol?["SeriesOrder"] != nil {
                        let newSeriesArray = NSMutableArray()

                        let caseSensitivityValue = currentHangingProtocol?["SeriesOrderIgnoreCase"]
                        let ignoreCase = objcBoolValue(caseSensitivityValue)

                        for term in (currentHangingProtocol?["SeriesOrder"] as? NSString)?.components(separatedBy: ",") ?? [] {
                            let term = term.trimmingCharacters(in: .whitespacesAndNewlines)

                            var index = -1
                            for i in 0..<series.count {
                                let s = series.object(at: i) as? DicomSeries

                                if ignoreCase {
                                    let rangeValue = (s?.name as NSString?)?.range(of: term, options: .caseInsensitive) ?? NSRange(location: 0, length: 0)

                                    if rangeValue.length > 0 {
                                        index = i
                                    }
                                } else {
                                    if (s?.name as NSString?)?.n2Contains(term as NSString) ?? false {
                                        index = i
                                    }
                                }
                            }

                            if index != -1 {
                                newSeriesArray.add(series.object(at: index))
                                series.removeObject(at: index)
                            }
                        }
                        newSeriesArray.addObjects(from: series as? [Any] ?? [])

                        series = newSeriesArray
                    }

                    if series.count > n {
                        newComparatives.addObjects(from: series.subarray(with: NSRange(location: 0, length: n)))
                    } else {
                        newComparatives.addObjects(from: series as? [Any] ?? [])
                    }
                }

                comparatives = newComparatives
            }

            // Prepare the series
            let total = Int(Int32(truncatingIfNeeded: Int(WindowLayoutManager.windowsRows(forHangingProtocol: currentHangingProtocol)) * Int(WindowLayoutManager.windowsColumns(forHangingProtocol: currentHangingProtocol)) * (AppController.shared()?.viewerScreens()?.count ?? 0)))

            if seriesArray.count > total {
                seriesArray.removeObjects(in: NSRange(location: total, length: seriesArray.count - total))
            }

            if seriesArray.count + comparatives.count > total {
                while seriesArray.count + comparatives.count > total && seriesArray.count > 1 {
                    seriesArray.removeLastObject()
                }

                while seriesArray.count + comparatives.count > total && comparatives.count > 0 {
                    comparatives.removeLastObject()
                }
            }

            if objcBoolValue(currentHangingProtocol?["RepeatSeriesIfNotEnoughSeries"]) {
                if seriesArray.count + comparatives.count < total {
                    var i = 0
                    while seriesArray.count + comparatives.count < total && seriesArray.count > 0 {
                        seriesArray.add(seriesArray.object(at: i))
                        i += 1
                    }
                }
            }

            seriesArray.addObjects(from: comparatives as? [Any] ?? [])


            // Go to the series level, if we are at study level (comparatives)
            for i in 0..<seriesArray.count {
                if let s = seriesArray.object(at: i) as? DicomStudy {
                    if (s.imageSeriesContainingPixels(true)?.count ?? 0) > 0 {
                        seriesArray.replaceObject(at: i, with: s.imageSeriesContainingPixels(true).object(at: 0))
                    } else if (s.imageSeries()?.count ?? 0) > 0 {
                        seriesArray.replaceObject(at: i, with: s.imageSeries().object(at: 0))
                    } else {
                        NSLog("---- no imageSeries in this study?: %@", s)
                    }
                }
            }

            self.viewerDICOMInt(false, dcmFile: seriesArray as? [Any], viewer: nil, tileWindows: true, protocol: currentHangingProtocol)
        } else {
            for v in ViewerController.getDisplayed2DViewers() ?? [] {
                (v as? ViewerController)?.window?.makeKeyAndOrderFront(self)
            }
        }

        // Apply WL/WW
        for v in ViewerController.getDisplayed2DViewers() ?? [] {
            let v = v as? ViewerController
            let p = WindowLayoutManager.hangingProtocol(forModality: v?.modality(), description: v?.currentStudy()?.studyName)

            if let p {
                if objcIntValue(p["WL"]) == 0 && objcIntValue(p["WW"]) == 0 { // Default
                }

                else if objcIntValue(p["WL"]) == 1 && objcIntValue(p["WW"]) == 1 { // Full
                    v?.imageView()?.setWLWW(0, 0)
                }

                else if p["WL"] != nil && p["WW"] != nil {
                    v?.imageView()?.setWLWW(objcFloatValue(p["WL"]), objcFloatValue(p["WW"]))
                }
            }
        }

        if restoreNOAutotiling {
            UserDefaults.standard.set(false, forKey: "AUTOTILING")
            UserDefaults.standard.set(Int(WINDOWSIZEVIEWERCopy), forKey: "WINDOWSIZEVIEWER")
        }
    }

    @objc(displayWaitWindowIfNecessary)
    func displayWaitWindowIfNecessary() {
        if self.horos_waitOpeningWindow == nil { self.horos_waitOpeningWindow = WaitRendering(NSLocalizedString("Opening...", comment: "")) }
        self.horos_waitOpeningWindow?.showWindow(self)
    }

    @objc(closeWaitWindowIfNecessary)
    func closeWaitWindowIfNecessary() {
        self.horos_waitOpeningWindow?.close()
        autoreleaseLater(self.horos_waitOpeningWindow)
        self.horos_waitOpeningWindow = nil
    }

    @objc(databaseOpenStudy:)
    func databaseOpenStudy(_ item: NSManagedObject!) {
        // #ifndef  OSIRIX_LIGHT
        if let node = (item as AnyObject?) as? DCMTKStudyQueryNode {
            // Check to see if already in retrieving mode, if not download it
            self.retrieveComparativeStudy(node, select: true, open: true)

            return
        }
        // #endif

        let cells = self.horos_oMatrix?.selectedCells ?? []
        if cells.count > 1 {
            for c in self.horos_oMatrix?.cells ?? [] {
                c.isHighlighted = false
            }

            self.horos_oMatrix?.selectCell(cells[0])
        }

        if objcIsEqualToString(item?.value(forKey: "type"), "Series") {
            if self.is(usingExternalViewer: item) == false {
                // DICOM & others
                self.viewerDICOMInt(false, dcmFile: objcArray(item) as? [Any], viewer: nil)

            }
        } else { // STUDY - Hanging Protocols - Windows State
            let currentStudy = item as? DicomStudy

            self.checkIfLocalStudyHasMoreOrSameNumberOfImages(ofADistantStudy: objcArray(currentStudy) as? [Any])

            AppController.shared()?.addStudyToRecentStudiesMenu(currentStudy?.objectID)

            let windowsStateApplied = false

            if currentStudy?.value(forKey: "windowsState") != nil && UserDefaults.standard.bool(forKey: "automaticWorkspaceLoad") {
                let viewers = (currentStudy?.value(forKey: "windowsState") as? Data).flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) } as? NSArray ?? []

                // Check if this windowsState contains at least this study...

                var studyUIDFound = false
                for dict in viewers {
                    if objcIsEqualToString(currentStudy?.studyInstanceUID, objcValue(dict, "studyInstanceUID")) {
                        studyUIDFound = true
                    }
                }

                if studyUIDFound {
                    let seriesToOpen = NSMutableArray()
                    let viewersToLoad = NSMutableArray()

                    ViewerController.closeAllWindows()

                    var propagateSettings: Any? = nil
                    var syncSettings: Any? = nil
                    var SYNCSERIES: Any? = nil
                    var syncButtonBehaviorIsBetweenStudies: Any? = nil

                    if UserDefaults.standard.bool(forKey: "searchForComparativeStudiesOnDICOMNodes") {
                        self.displayWaitWindowIfNecessary()

                        // Check if all studies are available, available on PACS-On-Demand ?
                        for dict in viewers {
                            let studyUID = objcValue(dict, "studyInstanceUID")

                            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
                            request.predicate = objcPredicate("studyInstanceUID == %@", studyUID)

                            let context = self.database?.managedObjectContext
                            var studiesArray = try? context?.fetch(request)

                            if (studiesArray?.count ?? 0) == 0 {
                                // #ifndef OSIRIX_LIGHT
                                let servers = BrowserController.comparativeServers()

                                let distantStudy = (QueryController.queryStudies(forFilters: NSDictionary(object: studyUID ?? NSNull(), forKey: "StudyInstanceUID" as NSString) as? [AnyHashable: Any], servers: servers, showErrors: false) as NSArray?)?.lastObject as? DCMTKStudyQueryNode

                                if let distantStudy {
                                    // No time for decompression; the setting is shared with the comparative
                                    // retrievals that may be running (#849).
                                    ListenerCompressionSuspension.shared.begin()

                                    QueryController.retrieveStudies([distantStudy], showErrors: false, checkForPreviousAutoRetrieve: true)

                                    var lastNumberOfImages = 0, currentNumberOfImages = 0
                                    let dateStart = Date.timeIntervalSinceReferenceDate

                                    repeat {
                                        Thread.sleep(forTimeInterval: 0.1)

                                        lastNumberOfImages = (studiesArray?.last as? DicomStudy)?.images()?.count ?? 0

                                        _ = DicomDatabase.activeLocal()?.importFilesFromIncomingDir()

                                        // And find the study locally
                                        let r = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
                                        r.predicate = objcPredicate("studyInstanceUID == %@", studyUID)

                                        if let e = objcTry({
                                            studiesArray = try? context?.fetch(r)
                                        }) { _N2LogExceptionImpl(e, true, "-[BrowserController databaseOpenStudy:]") }

                                        currentNumberOfImages = (studiesArray?.last as? DicomStudy)?.images()?.count ?? 0
                                    }
                                    while ((studiesArray?.count ?? 0) == 0 || lastNumberOfImages != currentNumberOfImages) && Date.timeIntervalSinceReferenceDate - dateStart < 20

                                    ListenerCompressionSuspension.shared.end()
                                }
                                // #endif
                            }
                        }

                        self.closeWaitWindowIfNecessary()
                    }

                    for dict in viewers {
                        let studyUID = objcValue(dict, "studyInstanceUID")
                        let seriesUID = objcValue(dict, "seriesInstanceUID") as? NSString
                        let seriesDICOMUID = objcValue(dict, "seriesDICOMUID") as? NSString

                        propagateSettings = objcValue(dict, "propagateSettings")
                        syncSettings = objcValue(dict, "syncSettings")
                        SYNCSERIES = objcValue(dict, "SYNCSERIES")
                        syncButtonBehaviorIsBetweenStudies = objcValue(dict, "SyncButtonBehaviorIsBetweenStudies")

                        let series4D = seriesUID?.components(separatedBy: "\\**\\")
                        // Find the corresponding study & 4D series

                        if let e = objcTry({
                            let context = self.database?.managedObjectContext

                            N2ManagedObjectContextPerformAndWait(context) {

                            var seriesForThisViewer: NSMutableArray? = nil

                            if let e = objcTry({
                                for curSeriesUID in series4D ?? [] {
                                    var request = NSFetchRequest<NSFetchRequestResult>(entityName: "Series")
                                    request.predicate = objcPredicate("study.studyInstanceUID == %@ AND seriesInstanceUID == %@", studyUID, curSeriesUID)

                                    var seriesArray = try? context?.fetch(request)

                                    //Try the DICOMSeriesUID
                                    if (seriesArray?.count ?? 0) == 0 && (seriesDICOMUID?.length ?? 0) > 0 {
                                        request = NSFetchRequest<NSFetchRequestResult>(entityName: "Series")
                                        request.predicate = objcPredicate("study.studyInstanceUID == %@ AND seriesDICOMUID == %@", studyUID, seriesDICOMUID)
                                        seriesArray = try? context?.fetch(request)
                                    }

                                    if let seriesArray, seriesArray.count == 1 {
                                        // [nil compare:] answered NSOrderedSame.
                                        let patientUID = (seriesArray[0] as? NSObject)?.value(forKeyPath: "study.patientUID") as? NSString
                                        if (patientUID.map { $0.compare((currentStudy?.value(forKey: "patientUID") as? String) ?? "", options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) } ?? .orderedSame) == .orderedSame {
                                            if seriesForThisViewer == nil {
                                                let newSeriesForThisViewer = NSMutableArray()
                                                seriesForThisViewer = newSeriesForThisViewer

                                                seriesToOpen.add(newSeriesForThisViewer)
                                                viewersToLoad.add(dict)
                                            }

                                            seriesForThisViewer?.add(seriesArray[0])
                                        } else {
                                            NSLog("%@ versus %@", objcFormatArgument((seriesArray[0] as? NSObject)?.value(forKeyPath: "study.patientUID")), objcFormatArgument(currentStudy?.value(forKey: "patientUID")))
                                        }
                                    } else if (seriesArray?.count ?? 0) > 1 {
                                        NSLog("****** number of series corresponding to these UID (%@) is not unique?: %d", curSeriesUID as NSString, Int32(truncatingIfNeeded: seriesArray?.count ?? 0))
                                    }
                                }
                            }) {
                                _N2LogExceptionImpl(e, true, "-[BrowserController databaseOpenStudy:]")
                            }

                            }
                        }) {
                            _N2LogExceptionImpl(e, true, "-[BrowserController databaseOpenStudy:]")
                        }
                    }

                    if seriesToOpen.count > 0 && viewersToLoad.count == seriesToOpen.count {
                        if syncSettings != nil {
                            if objcBoolValue(syncSettings) {
                                DCMView.setSyncro(Int16(syncroLOC))
                            } else {
                                DCMView.setSyncro(Int16(syncroOFF))
                            }
                        }

                        if propagateSettings != nil {
                            UserDefaults.standard.set(objcBoolValue(propagateSettings), forKey: "COPYSETTINGS")
                        }

                        self.displayWaitWindowIfNecessary()

                        AppController.shared()?.checkAllWindowsAreVisibleIsOff = true

                        for i in 0..<seriesToOpen.count {
                            let toOpenArray = NSMutableArray()

                            let dict = viewersToLoad.object(at: i)

                            for curFile in (seriesToOpen.object(at: i) as? NSArray) ?? [] {
                                let loadList = self.childrenArray(curFile)
                                if let loadList { toOpenArray.add(loadList) }
                            }

                            if objcBoolValue(objcValue(dict, "4DData")) {
                                self.processOpenViewerDICOM(from: toOpenArray as? [Any], movie: true, viewer: nil)
                            } else {
                                self.processOpenViewerDICOM(from: toOpenArray as? [Any], movie: false, viewer: nil)
                            }
                        }

                        let displayedViewers = (ViewerController.getDisplayed2DViewers() as NSArray?) ?? []
                        var validWindowsPosition = true
                        for i in 0..<viewersToLoad.count {
                            let dict = viewersToLoad.object(at: i)

                            if i < displayedViewers.count {
                                let v = displayedViewers.object(at: i) as? ViewerController

                                var r = NSRect.zero
                                let s = Scanner(string: (objcValue(dict, "window position") as? String) ?? "")

                                // -scanFloat: left the value as it was when nothing could be read.
                                var scaleRatio: Float = 1, a: Float = 0
                                if let f = s.scanFloat() { a = f };  r.origin.x = CGFloat(a);       if let f = s.scanFloat() { a = f };  r.origin.y = CGFloat(a)
                                if let f = s.scanFloat() { a = f };  r.size.width = CGFloat(a);    if let f = s.scanFloat() { a = f };  r.size.height = CGFloat(a)

                                let screenIndex = (objcValue(dict, "screenIndex") as? NSNumber)?.uintValue ?? 0
                                let savedScreenRect = NSRectFromString((objcValue(dict, "screen") as? String) ?? "")
                                if savedScreenRect.size.width > 0 && savedScreenRect.size.height > 0 {
                                    if screenIndex < UInt(NSScreen.screens.count) {
                                        var widthRatio: Float = 1, heightRatio: Float = 1
                                        let curScreenVisibleRect = AppController.usefullRect(for: NSScreen.screens[Int(screenIndex)])

                                        widthRatio = Float(curScreenVisibleRect.size.width / savedScreenRect.size.width)
                                        heightRatio = Float(curScreenVisibleRect.size.height / savedScreenRect.size.height)

                                        r.size.width *= CGFloat(widthRatio)
                                        r.size.height *= CGFloat(heightRatio)

                                        r.origin.x = ((r.origin.x - savedScreenRect.origin.x) * CGFloat(widthRatio)) + curScreenVisibleRect.origin.x
                                        r.origin.y = ((r.origin.y - savedScreenRect.origin.y) * CGFloat(heightRatio)) + curScreenVisibleRect.origin.y

                                        if widthRatio < 1 || heightRatio < 1 {
                                            scaleRatio = widthRatio < heightRatio ? widthRatio : heightRatio
                                        }

                                        if widthRatio > 1 || heightRatio > 1 {
                                            scaleRatio = widthRatio > heightRatio ? widthRatio : heightRatio
                                        }

                                        // Test if the window is completely contained in the screen, otherwise, we will TileWindows.
                                        if NSEqualRects(NSIntersectionRect(curScreenVisibleRect, r), r) == false {
                                            r = NSIntersectionRect(curScreenVisibleRect, r)
                                            validWindowsPosition = false
                                        }
                                    } else {
                                        validWindowsPosition = false
                                    }
                                } else {
                                    validWindowsPosition = false
                                }

                                let index = objcIntValue(objcValue(dict, "index"))
                                let rows = objcIntValue(objcValue(dict, "rows"))
                                let columns = objcIntValue(objcValue(dict, "columns"))
                                var wl = objcFloatValue(objcValue(dict, "wl"))
                                let ww = objcFloatValue(objcValue(dict, "ww"))
                                let x = objcFloatValue(objcValue(dict, "x"))
                                let y = objcFloatValue(objcValue(dict, "y"))
                                let rotation = objcFloatValue(objcValue(dict, "rotation"))
                                let scale = objcFloatValue(objcValue(dict, "scale")) * scaleRatio*scaleRatio

                                if validWindowsPosition {
                                    v?.setWindowFrame(r, showWindow: false)
                                }

                                v?.setImageRows(rows, columns: columns)

                                // A workspace explicitly owns its saved zoom/pan.
                                v?.cancelOpeningScaleToFit()
                                for view in v?.seriesView()?.imageViews() ?? [] {
                                    (view as? DCMView)?.prepareForWorkspacePresentation()
                                }

                                v?.setImageIndex(Int(index))
                                wl = v?.imageView()?.curDCM?.calibratedWindowLevel(forStoredLevel: wl) ?? 0

                                if v?.imageView()?.curDCM?.suvConverted ?? false {
                                    v?.setWL(wl * (v?.factorPET2SUV() ?? 0), ww: ww * (v?.factorPET2SUV() ?? 0))
                                } else {
                                    v?.setWL(wl, ww: ww)
                                }

                                v?.setScaleValue(scale)
                                v?.setRotation(rotation)
                                v?.setOrigin(NSMakePoint(CGFloat(x), CGFloat(y)))

                                // Each flip axis is restored from its own key (#598). A workspace saved
                                // before the keys existed leaves the flips as the series stored them.
                                if objcValue(dict, "xFlipped") != nil {
                                    v?.setXFlipped(objcBoolValue(objcValue(dict, "xFlipped")))
                                }
                                if objcValue(dict, "yFlipped") != nil {
                                    v?.setYFlipped(objcBoolValue(objcValue(dict, "yFlipped")))
                                }

                                if objcBoolValue(objcValue(dict, "SyncButtonBehaviorIsBetweenStudies")) {
                                    v?.imageView()?.syncRelativeDiff = objcFloatValue(objcValue(dict, "syncRelativeDiff"))
                                }

                                if objcValue(dict, "LastWindowsTilingRowsColumns") != nil {
                                    UserDefaults.standard.set(objcValue(dict, "LastWindowsTilingRowsColumns"), forKey: "LastWindowsTilingRowsColumns")
                                }
                            }
                        }

                        AppController.shared()?.checkAllWindowsAreVisibleIsOff = false
                        AppController.shared()?.checkAllWindowsAreVisible(self)

                        if validWindowsPosition {
                            for i in 0..<viewersToLoad.count {
                                if i < displayedViewers.count {
                                    let v = displayedViewers.object(at: i) as? ViewerController

                                    if let window = v?.window, let screen = window.screen {
                                        // Test if the window is completely contained in the screen, otherwise, we will TileWindows.
                                        if NSEqualRects(NSIntersectionRect(screen.visibleFrame, window.frame), window.frame) == false {
                                            validWindowsPosition = false
                                        }
                                    } else {
                                        validWindowsPosition = false
                                    }
                                }
                            }

                        }

                        if validWindowsPosition == false {
                            var d: NSDictionary? = nil
                            let rw = UserDefaults.standard.string(forKey: "LastWindowsTilingRowsColumns") as NSString?
                            if let rw {
                                if rw.length == 2 {
                                    d = NSDictionary(objects: [NSNumber(value: (rw.substring(with: NSMakeRange(0, 1)) as NSString).intValue), NSNumber(value: (rw.substring(with: NSMakeRange(1, 1)) as NSString).intValue)], forKeys: ["rows" as NSString, "columns" as NSString])
                                }
                            }
                            AppController.shared()?.tileWindows(d)
                        }
                        if displayedViewers.count > 0 {
                            (displayedViewers.object(at: 0) as? ViewerController)?.window?.makeKeyAndOrderFront(self)
                        }

                        self.closeWaitWindowIfNecessary()

                        //windowsStateApplied = YES; // Hanging Protocol has to prevail over window state when opening studies

                        for v in displayedViewers.reverseObjectEnumerator().allObjects {
                            (v as? ViewerController)?.buildMatrixPreview(true)
                        }

                        if objcBoolValue(syncButtonBehaviorIsBetweenStudies) && objcBoolValue(SYNCSERIES) {
                            ViewerController.activateSYNCSERIESBetweenStudies()
                        }

                        ToolbarPanelController.checkForValidToolbar()

                        (displayedViewers.lastObject as? ViewerController)?.redrawToolbar()
                    }
                }
            }

            if windowsStateApplied == false {
                WindowLayoutManager.shared()?.setCurrentHangingProtocolForModality(currentStudy?.value(forKey: "modality") as? String,
                                                                                    description: currentStudy?.value(forKey: "studyName") as? String)

                let currentHangingProtocol = WindowLayoutManager.shared()?.currentHangingProtocol

                self.databaseOpen(currentStudy, withProtocol: currentHangingProtocol as? [AnyHashable: Any])
            }
        }
    }
}
