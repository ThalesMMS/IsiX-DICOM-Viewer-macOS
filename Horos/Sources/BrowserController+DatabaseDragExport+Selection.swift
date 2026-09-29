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

// The second half of the "database drag export (#605)" block of
// BrowserController (from -databasePressed: to -saveDBListAs:) is implemented
// in Swift since #831: an extension of BrowserController, which stays
// Objective-C, with the selectors of the former methods. The instance
// variables it uses are read through BrowserController (SwiftIvars), the
// methods BrowserController.m does not declare through BrowserController
// (SwiftPrivateMethods), and what Swift cannot say itself (the [super print:]
// of NSWindowController) through BrowserController (SwiftBridges).
//
// A message to nil is optional chaining with the Objective-C default (nil, 0,
// NO); comparisons of object pointers are ===, and a pointer that was nil on
// both sides still compares equal. An @try is HorosObjCException.perform
// (objcTry); an @finally is the code that follows it. The local retain/release
// pairs of the former code (the context, the Wait window, DCMPix, DicomFile)
// are the Swift references' own. NSSet relationships are enumerated as NSSet,
// in the order the former fast enumeration took.

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

/// `a == b` of two Objective-C object pointers: the same object, or both nil.
fileprivate func objcIdentical(_ a: Any?, _ b: Any?) -> Bool {
    return a.map { $0 as AnyObject } === b.map { $0 as AnyObject }
}

/// `[object selector]` of a method returning an object, nil for a nil object.
fileprivate func objcSend(_ object: Any?, _ selector: String) -> Any? {
    guard let object = object as? NSObject else { return nil }
    return object.perform(NSSelectorFromString(selector))?.takeUnretainedValue()
}

/// `[object isDistant]`, NO for nil: DicomStudy, DicomSeries, DicomImage and
/// the DCMTK query nodes all answer it.
fileprivate func objcIsDistant(_ object: Any?) -> Bool {
    guard let object else { return false }
    return (object as AnyObject).isDistant?() ?? false
}

/// `[object intValue]` of an NSNumber or an NSString, 0 for nil.
fileprivate func objcIntValue(_ object: Any?) -> Int32 {
    if let number = object as? NSNumber { return number.int32Value }
    if let string = object as? NSString { return string.intValue }
    return 0
}

/// `[object count]` of a collection, 0 for nil.
fileprivate func objcCount(_ object: Any?) -> Int {
    if let array = object as? NSArray { return array.count }
    if let set = object as? NSSet { return set.count }
    if let set = object as? NSOrderedSet { return set.count }
    if let dictionary = object as? NSDictionary { return dictionary.count }
    return 0
}

/// `[array indexOfObject:object]`, NSNotFound for a nil array or a nil object.
fileprivate func objcIndex(_ array: NSArray?, _ object: Any?) -> Int {
    guard let array, let object else { return NSNotFound }
    return array.index(of: object)
}

/// `[[object valueForKey:@"type"] isEqualToString:type]`, NO for nil.
fileprivate func objcIsType(_ object: Any?, _ type: String) -> Bool {
    guard let object = object as? NSObject else { return false }
    return (object.value(forKey: "type") as? NSString)?.isEqual(to: type) ?? false
}

/// `[string appendString:other]`: raises, as NSMutableString did, when the
/// string appended is nil.
fileprivate func objcAppend(_ string: NSMutableString, _ other: String?) {
    guard let other else {
        NSException(name: .invalidArgumentException, reason: "-[__NSCFString appendString:]: nil argument", userInfo: nil).raise()
        return
    }
    string.append(other)
}

/// `[NSArray arrayWithObject:object]`: raises, as NSArray did, when the object
/// is nil.
fileprivate func objcArrayWithObject(_ object: Any?) -> [Any] {
    guard let object else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSPlaceholderArray initWithObjects:count:]: attempt to insert nil object from objects[0]", userInfo: nil).raise()
        return []
    }
    return [object]
}

/// `[array addObject:object]`: raises, as NSMutableArray did, when the object
/// is nil.
fileprivate func objcAddObject(_ array: NSMutableArray, _ object: Any?) {
    guard let object else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil", userInfo: nil).raise()
        return
    }
    array.add(object)
}

/// A component of `[NSCalendarDate date]` (-minuteOfHour, -secondOfMinute),
/// which Swift cannot name: the Gregorian calendar in the default time zone,
/// as NSCalendarDate read it.
fileprivate func calendarDateComponent(_ component: Calendar.Component) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = NSTimeZone.default
    return calendar.component(component, from: Date())
}

public extension BrowserController {

    // MARK: - database drag export (#605)

    @objc(databasePressed:)
    func databasePressed(_ sender: Any!) {
        resetROIsAndKeysButton()
    }

    @objc(print:)
    func print(_ sender: Any!) {
        printDatabaseSelection(sender)
    }

    @objc(printDatabaseSelection:)
    func printDatabaseSelection(_ sender: Any!) {
        if PrintSelection.mayPrintOutlineView() {
            horos_superPrint(sender)
            return
        }

        // File > Print follows the focused thumbnail selection as well as the
        // matrix context menu. Snapshot before Wait services the modal run loop.
        let selection = NSMutableArray()
        let oMatrix = horos_oMatrix
        let responder = window?.firstResponder
        var matrixSelection = false
        if let oMatrix {
            matrixSelection = objcIdentical(sender, oMatrix) || responder === oMatrix ||
                ((responder as? NSView)?.isDescendant(of: oMatrix) ?? false)
        }
        if matrixSelection {
            let matrixViewArray = horos_matrixViewArray as NSArray?
            for case let cell as NSCell in ((oMatrix?.selectedCells ?? []) as NSArray).sortedArray(using:
                [NSSortDescriptor(key: "tag", ascending: true)]) {
                if cell.isEnabled && cell.tag >= 0 && cell.tag < (matrixViewArray?.count ?? 0) {
                    selection.add(matrixViewArray!.object(at: cell.tag))
                }
            }
        } else {
            selection.addObjects(from: databaseSelection() ?? [])
        }

        var records: [PrintRecord] = []
        for item in selection {
            let parentIsStudy = item is DicomStudy
            let singleImage = item is DicomImage
            let series: NSArray
            if parentIsStudy {
                series = ((item as? DicomStudy)?.series as NSSet?)?.allObjects as NSArray? ?? NSArray()
            } else if item is DicomSeries {
                series = [item]
            } else if singleImage, let imageSeries = (item as? DicomImage)?.series {
                series = [imageSeries]
            } else {
                series = NSArray()
            }
            for case let candidate as DicomSeries in series.sortedArray(using:
                [NSSortDescriptor(key: "id", ascending: true)]) {
                let images: NSArray = singleImage ? [item] : ((candidate.sortedImages() as NSArray?) ?? NSArray())
                for case let image as DicomImage in images {
                    let record = PrintRecord()
                    // A series with a single database row may hold all frames;
                    // indexed per-frame rows and a partial image selection never expand.
                    let report = PrintSelection.isReport(sopClassUID: candidate.seriesSOPClassUID ?? "", modality: candidate.modality ?? "")
                    record.kind = !singleImage && (images.count == 1 || report) ? "series" : "image"
                    record.seriesSOPClassUID = candidate.seriesSOPClassUID ?? ""
                    record.modality = candidate.modality ?? ""
                    record.seriesName = candidate.name ?? ""
                    record.parentIsStudy = parentIsStudy
                    record.path = image.completePathResolved() ?? ""
                    record.title = candidate.name ?? ""
                    record.imageCount = images.count
                    record.numberOfFrames = image.numberOfFrames?.intValue ?? 0
                    record.frameID = image.frameID?.intValue ?? 0
                    record.windowWidth = candidate.windowWidth?.doubleValue ?? 0
                    record.windowLevel = candidate.windowLevel?.doubleValue ?? 0
                    records.append(record)
                }
            }
        }

        let job = PrintSelection.job(from: records, source: "effective")
        if !job.refusal.isEmpty {
            HorosAlertPanel.runInformational(title: NSLocalizedString("Print", comment: ""), message: job.refusal, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        let dir = PrintSelection.newSpoolDirectory()
        let wait: Wait? = Wait(string: NSLocalizedString("Preparing printing...", comment: ""), true)
        if objcTry({
            wait?.setCancel(true)
            wait?.progress()?.maxValue = Double(job.entries.count)
            wait?.showWindow(self)
            wait?.increment(by: 0)
            let spool = PrintSelection.spool(job, directory: dir,
                rasterAt: { index -> PrintRaster? in
                    let entry = job.entries[index]
                    let raster = PrintRaster()
                    if objcTry({
                        if entry.isReport {
                            let data = NSData(contentsOfFile: entry.path)
                            if let data, data.length >= 5, memcmp(data.bytes, "%PDF-", 5) == 0 {
                                raster.pdfBytes = data as Data
                            } else if PrintSelection.isEncapsulatedPDF(entry.sopClassUID) {
                                // EncapsulatedDocument is the PDF; the surrounding
                                // DICOM bytes are neither a PDF nor an image raster.
                                let object = HorosDCMTKObject(contentsOfFile: entry.path)
                                let document = object?.attributeValue(withName: "EncapsulatedDocument")
                                if let document = document as? NSData { raster.pdfBytes = document as Data }
                            } else if PrintSelection.isStructuredReport(entry.sopClassUID) {
                                let html = (dir as NSString).appendingPathComponent(String(format: "report-%04ld.html", index))
                                var task = Process()
                                task.launchPath = Bundle.main.path(forResource: "dsr2html", ofType: nil)
                                task.arguments = ["+X1", "--unknown-relationship", "--ignore-constraints", "--ignore-item-errors", "--skip-invalid-items", entry.path, html]
                                task.standardOutput = FileHandle.nullDevice
                                task.standardError = FileHandle.nullDevice
                                let cancelled: () -> Bool = { wait?.pollCancellation() ?? false }
                                if HorosRunTaskUntilExitCheckingCancellation(task, 60, cancelled, nil) && task.terminationStatus == 0 {
                                    task = Process()
                                    task.launchPath = Bundle.main.path(forResource: "Decompress", ofType: nil)
                                    task.arguments = [html, "pdfFromURL"]
                                    task.standardOutput = FileHandle.nullDevice
                                    task.standardError = FileHandle.nullDevice
                                    if HorosRunTaskUntilExitCheckingCancellation(task, 30, cancelled, nil) && task.terminationStatus == 0 {
                                        raster.pdfBytes = (html as NSString).appendingPathExtension("pdf").flatMap { NSData(contentsOfFile: $0) } as Data?
                                    }
                                }
                            }
                            raster.missing = (raster.pdfBytes?.count ?? 0) == 0
                        } else {
                            let pix = DCMPix(path: entry.path, 0, 1, nil, entry.frame, -1, isBonjour: false, imageObj: nil)
                            pix?.checkLoad()
                            if pix == nil || pix!.notAbleToLoadImage || pix!.pwidth <= 0 || pix!.pheight <= 0 {
                                raster.missing = true
                            } else if let pix {
                                let width: Float = entry.windowWidth > 0 ? Float(entry.windowWidth) : pix.savedWW
                                let level: Float = entry.windowWidth > 0 ? pix.calibratedWindowLevel(forStoredLevel: Float(entry.windowLevel)) : pix.savedWL
                                pix.checkImageAvailble(width, level)
                                // DCMPix supplies its full-resolution, windowed
                                // image, including RGB. No thumbnail or screen DPI.
                                raster.image = pix.image()
                                raster.pixelRatio = Double(pix.pixelRatio)
                                raster.missing = raster.image == nil
                            }
                        }
                    }) != nil {
                        raster.missing = true
                    }
                    return raster
                },
                continueAfter: { completed, total in
                    wait?.progress()?.doubleValue = Double(completed)
                    return !(wait?.pollCancellation() ?? false)
                })
            wait?.close()
            if spool.cancelled { return }
            if !spool.refusal.isEmpty || !spool.success {
                let reason = !spool.refusal.isEmpty ? spool.refusal : PrintSelection.prepareFailureRefusal
                HorosAlertPanel.runInformational(title: NSLocalizedString("Print", comment: ""), message: reason, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return
            }
            self.printDatabaseSpool(spool)
        }) != nil {
            wait?.close()
            HorosAlertPanel.runInformational(title: NSLocalizedString("Print", comment: ""), message: PrintSelection.prepareFailureRefusal, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
        // @finally
        wait?.close()
        _ = PrintSelection.discardSpoolDirectory(dir)
    }

    @objc(printDatabaseSpool:)
    func printDatabaseSpool(_ object: Any!) {
        let spool = object as? PrintSpool
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .spool
        guard let spool, let operation = PrintSelection.printOperation(for: spool, printInfo: info) else {
            HorosAlertPanel.runInformational(title: NSLocalizedString("Print", comment: ""), message: PrintSelection.prepareFailureRefusal, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        // AppKit reports printer errors and supplies preview, page selection,
        // orientation and cancellation. NO includes a dismissed print panel.
        if !operation.run() {
            spool.success = false
        }
    }


    @objc(databaseDoublePressed:)
    func databaseDoublePressed(_ sender: Any!) {
        if ((sender as? NSTableView)?.clickedRow ?? 0) != -1 {
            let databaseOutline = horos_databaseOutline
            let item: Any?
            if (databaseOutline?.clickedRow ?? 0) != -1 {
                item = databaseOutline?.item(atRow: databaseOutline?.clickedRow ?? 0)
            } else {
                item = databaseOutline?.item(atRow: databaseOutline?.selectedRow ?? 0)
            }

            if objcIntValue(objcSend(item, "numberOfImages")) != 0 {
                if objcIsDistant(item) {
                    var study = item

                    if item is DCMTKSeriesQueryNode {
                        study = (item as? DCMTKSeriesQueryNode)?.study
                    }

                    // Check to see if already in retrieving mode, if not download it
                    retrieveComparativeStudy(study as? DCMTKStudyQueryNode, select: true, open: false)
                } else {
                    databaseOpenStudy(item as? NSManagedObject)
                }
            } else {
                querySelectedStudy(self)
            }
        }
    }

    @objc(outlineView:shouldEditTableColumn:item:)
    func outlineView(_ outlineView: NSOutlineView!, shouldEdit tableColumn: NSTableColumn!, item: Any!) -> Bool {
        if database?.isReadOnly ?? false {
            return false
        }

        let identifier = tableColumn?.identifier.rawValue
        if identifier == "comment" || identifier == "comment2" || identifier == "comment3" || identifier == "comment4" {
            horos_DatabaseIsEdited = true
            return true
        } else {
            horos_DatabaseIsEdited = false
            return false
        }
    }

    @objc(outlineView:shouldTrackCell:forTableColumn:item:)
    func outlineView(_ outlineView: NSOutlineView!, shouldTrackCell cell: NSCell!, for tableColumn: NSTableColumn!, item: Any!) -> Bool {
        if database?.isReadOnly ?? false {
            return false
        }

        return true
    }

    @objc(displayImagesOfSeries:)
    func displayImagesOfSeries(_ sender: Any!) {
        let dicomFiles = NSMutableArray()
        let oMatrix = horos_oMatrix
        let databaseOutline = horos_databaseOutline

        if ((sender is NSMenuItem) && (sender as? NSMenuItem)?.menu === oMatrix?.menu) || window?.firstResponder === oMatrix {
            let matrixViewArray = horos_matrixViewArray as NSArray?
            // NSUInteger > NSInteger: the tag is compared as unsigned.
            if UInt(matrixViewArray?.count ?? 0) > UInt(bitPattern: oMatrix?.selectedCell()?.tag ?? 0) {
                let curObj = matrixViewArray?.object(at: oMatrix?.selectedCell()?.tag ?? 0) as? NSObject

                if objcIsType(curObj, "Image") {
                    _ = files(forDatabaseMatrixSelection: dicomFiles)

                    if databaseOutline?.isItemExpanded(curObj?.value(forKeyPath: "series.study")) ?? false {
                        databaseOutline?.collapseItem(curObj?.value(forKeyPath: "series.study"))
                    }

                } else {
                    _ = files(forDatabaseMatrixSelection: dicomFiles)
                    _ = findAndSelectFile(nil, image: dicomFiles.object(at: 0) as? DicomImage, shouldExpand: true)
                }
            }
        }
    }

    @objc(findAndSelectFile:image:shouldExpand:)
    func findAndSelectFile(_ path: String!, image curImage: DicomImage!, shouldExpand expand: Bool) -> Bool {
        return findAndSelectFile(path, image: curImage, shouldExpand: expand, extendingSelection: false)
    }

    @objc(findAndSelectFile:image:shouldExpand:extendingSelection:)
    func findAndSelectFile(_ path: String!, image curImage: DicomImage!, shouldExpand expand: Bool, extendingSelection: Bool) -> Bool {
        var curImage: DicomImage? = curImage
        let databaseOutline = horos_databaseOutline
        let oMatrix = horos_oMatrix

        if curImage == nil {
            var isDirectory: ObjCBool = false

            if let path, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {     // A directory
                var curFile: DicomFile? = nil

                if let e = objcTry({
                    if isDirectory.boolValue == true {
                        var go = true
                        let aPath = path
                        let enumer = FileManager.default.enumerator(atPath: aPath)

                        while true {
                            let pathname = enumer?.nextObject() as? String
                            guard pathname != nil && go == true else { break }
                            let itemPath = (aPath as NSString).appendingPathComponent(pathname!)
                            let fileType = enumer?.fileAttributes?[FileAttributeKey.type]

                            if (fileType as? NSString)?.isEqual(FileAttributeType.typeRegular.rawValue) ?? false {

                                if ((itemPath as NSString).lastPathComponent as NSString).character(at: 0) != UInt16(UInt8(ascii: ".")) {
                                    curFile = DicomFile(itemPath)
                                }

                                if curFile != nil { go = false }
                            }
                        }
                    } else {
                        curFile = DicomFile(path)
                    }
                }) {
                    _N2LogExceptionImpl(e, true, "-[BrowserController findAndSelectFile:image:shouldExpand:extendingSelection:]")
                    curFile = nil
                }

                //We have first to find the image object from the path

                if let curFile {
                    let context = database?.managedObjectContext

                    let dbRequest = NSFetchRequest<NSFetchRequestResult>()
                    dbRequest.entity = database?.managedObjectModel?.entitiesByName["Study"]
                    dbRequest.predicate = NSPredicate(value: true)

                    context?.lock()

                    if let e = objcTry({
                        let studiesArray = ((try? context?.fetch(dbRequest)) as NSArray?)

                        var index = objcIndex(studiesArray?.value(forKey: "studyInstanceUID") as? NSArray, curFile.element(forKey: "studyID"))
                        if index != NSNotFound {
                            let study = studiesArray?.object(at: index) as? NSManagedObject
                            let seriesArray = (study?.value(forKey: "series") as? NSSet)?.allObjects as NSArray?
                            index = objcIndex(seriesArray?.value(forKey: "seriesInstanceUID") as? NSArray, curFile.element(forKey: "seriesID"))
                            if index != NSNotFound {
                                let seriesTable = seriesArray?.object(at: index) as? NSManagedObject
                                let imagesArray = (seriesTable?.value(forKey: "images") as? NSSet)?.allObjects as NSArray?
                                index = objcIndex(imagesArray?.value(forKey: "sopInstanceUID") as? NSArray, curFile.element(forKey: "SOPUID"))
                                if index != NSNotFound { curImage = imagesArray?.object(at: index) as? DicomImage }
                            }
                        }
                    }) {
                        _N2LogExceptionImpl(e, true, "-[BrowserController findAndSelectFile:image:shouldExpand:extendingSelection:]")
                    }

                    context?.unlock()
                }
            }
        }

        let study = curImage?.series?.study

        let index = objcIndex(horos_outlineViewArray as NSArray?, study)

        if index != NSNotFound {
            if expand { // || [databaseOutline isItemExpanded: study])
                databaseOutline?.expandItem(study)

                if (databaseOutline?.row(forItem: curImage?.value(forKey: "series")) ?? 0) != (databaseOutline?.selectedRow ?? 0) {
                    if let databaseOutline {
                        OutlineSelectionRestore.select(curImage?.value(forKey: "series"), in: databaseOutline, extending: extendingSelection)
                    }
                    databaseOutline?.scrollRowToVisible(databaseOutline?.selectedRow ?? 0)
                }
            } else {
                if (databaseOutline?.row(forItem: study) ?? 0) != (databaseOutline?.selectedRow ?? 0) {
                    if let databaseOutline {
                        OutlineSelectionRestore.select(study, in: databaseOutline, extending: extendingSelection)
                    }
                    databaseOutline?.scrollRowToVisible(databaseOutline?.selectedRow ?? 0)
                }

                if objcIdentical(oMatrix?.selectedCell()?.representedObject, curImage?.series?.objectID) {
                    return true
                }

                for cell in oMatrix?.cells ?? [] {
                    if objcIdentical(cell.representedObject, curImage?.series?.objectID) {
                        oMatrix?.selectCell(cell)
                        matrixPressed(oMatrix)
                        return true
                    }
                }

                let seriesArray = childrenArray(study) as NSArray?

                outlineViewSelectionDidChange(nil)

                matrixDisplayIcons(self)

                let seriesPosition = objcIndex(seriesArray, curImage?.value(forKey: "series"))

                if seriesPosition != NSNotFound {
                    if (oMatrix?.selectedCell()?.tag ?? 0) != seriesPosition {
                        // Select the right thumbnail matrix
                        var rows = 0, cols = 0; oMatrix?.getNumberOfRows(&rows, columns: &cols); if cols < 1 { cols = 1 }
                        oMatrix?.selectCell(atRow: seriesPosition / cols, column: seriesPosition % cols)
                        matrixPressed(oMatrix)
                    }

                    return true
                }
            }
        }

        return false
    }

    @objc(displayStudy:object:command:)
    func display(_ study: DicomStudy!, object element: NSManagedObject!, command execute: String!) -> Bool {
        if selectThisStudy(study) {
            if execute == "Open" {
                let viewersList = (ViewerController.getDisplayed2DViewers() as NSArray?) ?? NSArray()
                var found = false

                if objcIsType(element, "Study") {
                    // Is a viewer containing this study opened? -> select it
                    for case let vc as ViewerController in viewersList {
                        if objcIdentical(element, ((vc.fileList() as NSArray?)?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.study")) {
                            vc.window?.makeKeyAndOrderFront(self)
                            found = true
                        }
                    }
                } else if objcIsType(element, "Series") {
                    // Is a viewer containing this series opened? -> select it
                    for case let vc as ViewerController in viewersList {
                        if objcIdentical(element, ((vc.fileList() as NSArray?)?.object(at: 0) as? NSObject)?.value(forKeyPath: "series")) {
                            vc.window?.makeKeyAndOrderFront(self)
                            found = true
                        }
                    }
                } else if objcIsType(element, "Image") {
                    // Is a viewer containing this image opened? -> select it
                    for case let vc as ViewerController in viewersList {
                        for case let im as NSManagedObject in (vc.fileList() as NSArray?) ?? NSArray() {
                            if element === im {
                                vc.window?.makeKeyAndOrderFront(self)
                                found = true

                                vc.setImage(im)
                            }
                        }
                    }
                }

                if found == false {
                    if objcIsType(element, "Series") {
                        _ = findAndSelectFile(nil, image: (element?.value(forKey: "images") as? NSSet)?.anyObject() as? DicomImage, shouldExpand: false)
                        databaseOpenStudy(element)
                    } else if objcIsType(element, "Image") {
                        _ = findAndSelectFile(nil, image: element as? DicomImage, shouldExpand: false)
                        databaseOpenStudy(element?.value(forKey: "series") as? NSManagedObject)

                        // Is a viewer containing this image opened? -> select it
                        for case let vc as ViewerController in (ViewerController.getDisplayed2DViewers() as NSArray?) ?? NSArray() {
                            for case let im as NSManagedObject in (vc.fileList() as NSArray?) ?? NSArray() {
                                if element === im {
                                    vc.window?.makeKeyAndOrderFront(self)
                                    found = true

                                    vc.setImage(im)
                                }
                            }
                        }
                    } else { BrowserController.currentBrowser()?.databaseOpenStudy(element) }
                    //
                }
            }

            return true
        }

        return false
    }

    @available(*, deprecated)
    @objc(findObject:table:execute:elements:)
    func findObject(_ request: String!, table: String!, execute: String!, elements: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Int32 { // __deprecated
        if let elements {
            elements.pointee = nil
        }

        guard let request else { return -32 }
        guard let table else { return -33 }
        guard let execute else { return -34 }

        var error: NSError? = nil

        var element: NSManagedObject? = nil
        var array: NSArray? = nil
        let context = database?.managedObjectContext

        checkIncoming(self)
        // We cannot call checkIncomingNow, because we currently have the lock for context, and IF a separate checkIncoming thread has started, he is currently waiting for the context lock, and we will wait for the checkIncomingLock...

        let dbRequest = NSFetchRequest<NSFetchRequestResult>()
        dbRequest.entity = database?.managedObjectModel?.entitiesByName[table]
        dbRequest.predicate = NSPredicate(format: request)

        context?.lock()

        var failedWithError = false
        if let e = objcTry({
            error = nil
            do {
                array = try context?.fetch(dbRequest) as NSArray?
            } catch let fetchError {
                array = nil
                error = fetchError as NSError
            }

            if error != nil {
                context?.unlock()

                failedWithError = true
                return
            }

            if (array?.count ?? 0) != 0 {
                element = array?.object(at: 0) as? NSManagedObject

                if execute != "Delete" {
                    var study: NSManagedObject? = nil

                    if objcIsType(element, "Image") { study = element?.value(forKeyPath: "series.study") as? NSManagedObject }
                    else if objcIsType(element, "Series") { study = element?.value(forKey: "study") as? NSManagedObject }
                    else if objcIsType(element, "Study") { study = element }

                    if objcCount(study?.value(forKey: "imageSeries")) == 0 {
                        element = nil
                    }
                }
            }
        }) {
            _N2LogExceptionImpl(e, true, "-[BrowserController findObject:table:execute:elements:]")
        }
        if failedWithError {
            return Int32(truncatingIfNeeded: error?.code ?? 0)
        }

        context?.unlock()


        if let element {
            if execute == "Select" || execute == "Open" {
                var study: DicomStudy? = nil

                if objcIsType(element, "Image") { study = element.value(forKeyPath: "series.study") as? DicomStudy }
                else if objcIsType(element, "Series") { study = element.value(forKey: "study") as? DicomStudy }
                else if objcIsType(element, "Study") { study = element as? DicomStudy }
                else { NSLog("DB selectObject : Unknown table") }

                let succeed = display(study, object: element, command: execute)

                if succeed == false {
                    return -1
                }
            }

            // Generate an answer containing the elements
            let a = NSMutableString(string: "<value><array><data>")

            for case let obj as NSManagedObject in array ?? NSArray() {
                let c = NSMutableString(string: "<value><struct>")

                let allKeys = (database?.managedObjectModel?.entitiesByName[table]?.attributesByName as NSDictionary?)?.allKeys ?? []

                for case let keyname as String in allKeys {
                    if let e = objcTry({
                        let objectValue = obj.value(forKey: keyname)
                        if objectValue is NSString ||
                           objectValue is NSDate ||
                           objectValue is NSNumber {
                            let value = (objectValue as AnyObject).description as String
                            let escaped = CFXMLCreateStringByEscapingEntities(nil, value as CFString, nil) as String?
                            c.append("<member><name>\(keyname)</name><value>\(escaped ?? "(null)")</value></member>")
                        }
                    }) {
                        _N2LogExceptionImpl(e, true, "-[BrowserController findObject:table:execute:elements:]")
                    }
                }

                c.append("</struct></value>")

                a.append(c as String)
            }

            a.append("</data></array></value>")

            if let elements {
                elements.pointee = a
            }

            if execute == "Delete" {
                context?.lock()

                if let e = objcTry({

                    for case let curElement as NSManagedObject in array ?? NSArray() {
                        var study: NSManagedObject? = nil

                        if objcIsType(curElement, "Image") { study = curElement.value(forKeyPath: "series.study") as? NSManagedObject }
                        else if objcIsType(curElement, "Series") { study = curElement.value(forKey: "study") as? NSManagedObject }
                        else if objcIsType(curElement, "Study") { study = curElement }
                        else { NSLog("DB selectObject : Unknown table") }

                        if let study {
                            context?.delete(study)
                        }
                    }

                    database?.save(nil)
                }) {
                    _N2LogExceptionImpl(e, true, "-[BrowserController findObject:table:execute:elements:]")
                }

                context?.unlock()
            }

            return 0
        }

        return -1
    }

    @objc(loadNextPatient::::keyImagesOnly:)
    func loadNextPatient(_ curImage: NSManagedObject!, _ direction: Int, _ viewer: ViewerController!, _ firstViewer: Bool, keyImagesOnly keyImages: Bool) {
        let copyPatientsSettings = UserDefaults.standard.bool(forKey: "onlyDisplayImagesOfSamePatient")

        NSDisableScreenUpdates()

        UserDefaults.standard.set(false, forKey: "onlyDisplayImagesOfSamePatient")

        if delayedTileWindows != 0 {
            delayedTileWindows = 0
            if let app = AppController.shared() {
                NSObject.cancelPreviousPerformRequests(withTarget: app, selector: #selector(AppController.tileWindows(_:)), object: nil)
            }
        }

        if ((ViewerController.get2DViewers() as NSArray?)?.count ?? 0) != 0 {
            // Save workspace
            viewer?.saveWindowsState(self)

            // If multiple viewer are opened, apply it to the entire list
            for case let v as ViewerController in (ViewerController.get2DViewers() as NSArray?) ?? NSArray() {
                v.window?.orderOut(self)
            }

            for case let v as ViewerController in (ViewerController.get2DViewers() as NSArray?) ?? NSArray() {
                v.close()
            }
        }

        if delayedTileWindows != 0 {
            delayedTileWindows = 0
            if let app = AppController.shared() {
                NSObject.cancelPreviousPerformRequests(withTarget: app, selector: #selector(AppController.tileWindows(_:)), object: nil)
            }
        }

        let study = curImage?.value(forKeyPath: "series.study") as? DicomStudy

        var studiesList = horos_originalOutlineViewArray as NSArray?

        if studiesList == nil {
            studiesList = horos_outlineViewArray as NSArray?
        }

        var index = objcIndex(studiesList, study)

        if index != NSNotFound {
            var found = false
            var nextStudy: Any? = nil
            repeat {
                index += direction
                if index >= 0 && index < (studiesList?.count ?? 0) {
                    nextStudy = studiesList?.object(at: index)

                    let nextPatientUID = objcSend(nextStudy, "patientUID") as? NSString
                    // compare: with a nil study.patientUID answers NSOrderedDescending,
                    // even for an empty string.
                    let studyPatientUID = study?.patientUID
                    if (nextPatientUID.map { uid in studyPatientUID.map { uid.compare($0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) } ?? .orderedDescending } ?? .orderedSame) != .orderedSame { // skip empty studies
                        if objcIsDistant(nextStudy) {
                            retrieveComparativeStudy(nextStudy as? DCMTKStudyQueryNode, select: true, open: true)
                            found = true
                        }

                        if objcIsDistant(nextStudy) == false && objcCount((nextStudy as? DicomStudy)?.images()) != 0 {
                            found = true
                        }
                    }
                } else {
                    NSSound.beep()
                    break
                }

            } while found == false

            if objcIsDistant(nextStudy) == false {
                if found {
                    if let databaseOutline = horos_databaseOutline {
                        OutlineSelectionRestore.select(nextStudy, in: databaseOutline, extending: false)
                    }
                    databaseOpenStudy(nextStudy as? NSManagedObject)
                }
            }

            //		NSManagedObject	*series =  [[self childrenArray:nextStudy] objectAtIndex:0];
            //
            //		[self openViewerFromImages :[NSArray arrayWithObject: [self childrenArray: series]] movie: NO viewer :viewer keyImagesOnly:keyImages];
            //
            //		[self loadNextSeries:[[self childrenArray: series] objectAtIndex: 0] :0 :viewer :YES keyImagesOnly:keyImages];
        }

        NSEnableScreenUpdates()

        NotificationCenter.default.post(name: .OsirixDidLoadNewObject, object: study, userInfo: nil)

        UserDefaults.standard.set(copyPatientsSettings, forKey: "onlyDisplayImagesOfSamePatient")
    }

    @objc(loadNextSeries::::keyImagesOnly:)
    func loadNextSeries(_ curImage: NSManagedObject!, _ direction: Int, _ viewer: ViewerController!, _ firstViewer: Bool, keyImagesOnly keyImages: Bool) {
        var curImage: NSManagedObject? = curImage
        var direction = direction
        var viewer: ViewerController? = viewer
        let model = database?.managedObjectModel
        let context = database?.managedObjectContext
        let winList = NSApp.windows
        let viewersList = NSMutableArray(capacity: 0)
        var applyToAllViewers = UserDefaults.standard.bool(forKey: "nextSeriesToAllViewers")

        let previousNumberOf2DViewers = Int32(truncatingIfNeeded: (ViewerController.getDisplayed2DViewers() as NSArray?)?.count ?? 0)

        if NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) ?? false {
            applyToAllViewers = !applyToAllViewers
        }

        if let viewer, viewer.fullScreenON() { viewersList.add(viewer) }
        else {
            // If multiple viewer are opened, apply it to the entire list
            if applyToAllViewers {
                for win in winList {
                    if let controller = win.windowController as? ViewerController, controller.windowWillClose() == false {
                        viewersList.add(controller)
                    }
                }
                viewer = viewersList.object(at: 0) as? ViewerController
                curImage = (viewer?.fileList() as NSArray?)?.object(at: 0) as? NSManagedObject
            } else {
                // -addObject: of a nil viewer raised; nothing is added.
                if let viewer { viewersList.add(viewer) }
            }
        }

        // FIND ALL STUDIES of this patient
        let study = curImage?.value(forKeyPath: "series.study") as? NSManagedObject
        let currentSeries = curImage?.value(forKey: "series") as? NSManagedObject

        let predicate = NSPredicate(format: "(patientUID BEGINSWITH[cd] %@)", argumentArray: [study?.value(forKey: "patientUID") ?? NSNull()])
        let dbRequest = NSFetchRequest<NSFetchRequestResult>()
        dbRequest.entity = model?.entitiesByName["Study"]
        dbRequest.predicate = predicate

        context?.lock()

        let viewersArray = NSMutableArray()

        if let e = objcTry({
            var studiesArray = ((try? context?.fetch(dbRequest)) as NSArray?)
            var seriesArray = NSArray()


            if (studiesArray?.count ?? 0) > 0 && objcIndex(studiesArray, study) != NSNotFound {
                let sort = NSSortDescriptor(key: "date", ascending: false)
                let sortDescriptors = [sort]

                studiesArray = studiesArray?.sortedArray(using: sortDescriptors) as NSArray?

                for case let curStudy as NSManagedObject in studiesArray ?? NSArray() {
                    seriesArray = seriesArray.addingObjects(from: childrenArray(curStudy) ?? []) as NSArray
                }

                var index = objcIndex(seriesArray, currentSeries)

                if index != NSNotFound {
                    if direction == 0 {	// Called from loadNextPatient
                        if firstViewer == false { direction = 1 }
                    }

                    index += direction * viewersList.count
                    if index < 0 && index + viewersList.count == 0 {
                        NSSound.beep()
                    } else {
                        if index < 0 { index = 0 }
                        if index < seriesArray.count {
                            if index + viewersList.count > seriesArray.count {
                                index = seriesArray.count - viewersList.count
                                if index < 0 { index = 0 }
                            }

                            for case let vc as ViewerController in viewersList {
                                if index >= 0 && index < seriesArray.count {
                                    objcAddObject(viewersArray, childrenArray(seriesArray.object(at: index)))

                                } else {
                                    viewersArray.add(NSNull())

                                    // Close the viewer
                                    vc.window?.performClose(self)
                                }

                                index += 1
                            }
                        } else { NSSound.beep() }
                    }
                }
            }
        }) {
            _N2LogExceptionImpl(e, true, "-[BrowserController loadNextSeries::::keyImagesOnly:]")
        }
        // @finally
        context?.unlock()

        if viewersArray.count == viewersList.count {
            var i = 0
            for case let vc as ViewerController in viewersList {
                if !(viewersArray.object(at: i) is NSNull) {
                    _ = openViewer(fromImages: [viewersArray.object(at: i)], movie: false, viewer: vc, keyImagesOnly: keyImages)
                }

                i += 1
            }
        }

        if Int(previousNumberOf2DViewers) != ((ViewerController.getDisplayed2DViewers() as NSArray?)?.count ?? 0) {
            if delayedTileWindows != 0 {
                delayedTileWindows = 0
                if let app = AppController.shared() {
                    NSObject.cancelPreviousPerformRequests(withTarget: app, selector: #selector(AppController.tileWindows(_:)), object: nil)
                }
            }

            AppController.shared()?.tileWindows(nil)
        }
    }

    @objc(loadSeries:::keyImagesOnly:)
    func loadSeries(_ series: NSManagedObject!, _ viewer: ViewerController!, _ firstViewer: Bool, keyImagesOnly keyImages: Bool) -> ViewerController! {
        var gspsViewer: ViewerController? = nil
        if horos_tryOpenGSPSSeries(series as? DicomSeries,
                                   viewer: viewer,
                                   keyImagesOnly: keyImages,
                                   openedViewer: &gspsViewer) {
            return gspsViewer
        }

        var movie4D = false

        if NSApplication.shared.currentEvent?.modifierFlags.contains(.control) ?? false {
            movie4D = true
        }

        if NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) ?? false {
            horos_openReparsedSeriesFlag = true
            processOpenViewerDICOM(from: objcArrayWithObject(childrenArray(series)), movie: false, viewer: viewer)
            horos_openReparsedSeriesFlag = false
        } else {
            return openViewer(fromImages: objcArrayWithObject(childrenArray(series)), movie: movie4D, viewer: viewer, keyImagesOnly: keyImages, tryToFlipData: true)
        }

        return nil
    }

    @objc(exportDBListOnlySelected:)
    func exportDBListOnlySelected(_ onlySelected: Bool) -> String! {
        let databaseOutline = horos_databaseOutline
        let rowIndex: IndexSet

        if onlySelected { rowIndex = databaseOutline?.selectedRowIndexes ?? IndexSet() }
        else { rowIndex = IndexSet(integersIn: 0 ..< (databaseOutline?.numberOfRows ?? 0)) }

        let string = NSMutableString()
        let columns = ((databaseOutline?.tableColumns ?? []) as NSArray).value(forKey: "identifier") as? NSArray ?? NSArray()
        let descriptions = ((databaseOutline?.tableColumns ?? []) as NSArray).value(forKey: "headerCell") as? NSArray ?? NSArray()

        // The indexes of the set, in order (-firstIndex, then -indexGreaterThanIndex:).
        for r in rowIndex {
            let aFile = databaseOutline?.item(atRow: r) as? NSObject

            if aFile != nil && objcIsType(aFile, "Study") {
                if string.length != 0 {
                    string.append("\r")
                } else { // Header
                    var i = 0
                    for case let s as NSCell in descriptions {
                        if let e = objcTry({
                            objcAppend(string, s.stringValue)
                        }) {
                            _N2LogExceptionImpl(e, false, "-[BrowserController exportDBListOnlySelected:]")
                        }
                        i += 1
                        if i != columns.count {
                            string.append("\t")
                        }
                    }
                    string.append("\r")
                }

                // A column that raised still ends with its tab, so that the
                // next ones stay under their headers.
                var i = 0
                for case let identifier as String in columns {
                    if let e = objcTry({
                        let value: Any? = identifier == "yearOld"
                            ? outlineView(databaseOutline, objectValueFor: databaseOutline?.tableColumns[i], byItem: aFile)
                            : aFile?.value(forKey: identifier)
                        if let value {
                            let c = databaseOutline?.tableColumns[i].dataCell as? NSCell

                            if let formatter = c?.formatter {
                                objcAppend(string, formatter.string(for: value))
                            } else {
                                objcAppend(string, (value as AnyObject).description)
                            }
                        }
                    }) {
                        _N2LogExceptionImpl(e, false, "-[BrowserController exportDBListOnlySelected:]")
                    }
                    i += 1

                    if i != columns.count {
                        string.append("\t")
                    }
                }
            }
        }

        return string as String
    }

    @objc(pasteImageForSourceFile:)
    func pasteImage(forSourceFile sourceFile: String!) {
        var sourceFile: String? = sourceFile
        // If the clipboard contains an image -> generate a SC DICOM file corresponding to the selected patient
        if NSPasteboard.general.data(forType: .tiff) != nil {
            let image = NSPasteboard.general.data(forType: .tiff).flatMap { NSImage(data: $0) }

            if let path = sourceFile {
                if FileManager.default.fileExists(atPath: path) == false {
                    sourceFile = nil
                }
            }

            if sourceFile == nil {
                let images = NSMutableArray()

                if window?.firstResponder === horos_oMatrix { _ = files(forDatabaseMatrixSelection: images) }
                else { _ = files(forDatabaseOutlineSelection: images) }

                if images.count != 0 {
                    sourceFile = (images.object(at: 0) as? NSObject)?.value(forKey: "completePath") as? String
                }
            }

            let e = DICOMExport()

            // DICOM source character sets may not encode localized date punctuation (e.g. U+202F).
            let exportTimestamp = DateFormatter()
            exportTimestamp.locale = Locale(identifier: "en_US_POSIX")
            exportTimestamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
            e.setSeriesDescription(String(format: NSLocalizedString("Clipboard - %@", comment: ""), exportTimestamp.string(from: Date()) as NSString))
            e.setSeriesNumber(66532 + calendarDateComponent(.minute) + calendarDateComponent(.second))

            e.setSourceFile(sourceFile)
            if e.setPixelNSImage(image) == 0 {
                let f = e.writeDCMFile(nil)
                if let f {
                    _ = database?.addFiles(atPaths: [f],
                                           postNotifications: true,
                                           dicomOnly: true,
                                           rereadExistingItems: true,
                                           generatedByOsiriX: true)
                    return
                }
            }
        }

        NSSound.beep()
    }


    @objc(paste:)
    func paste(_ sender: Any!) {
        pasteImage(forSourceFile: nil)
    }

    @objc(copy:)
    func copy(_ sender: Any!) {
        let pb = NSPasteboard.general

        pb.declareTypes([.string], owner: self)

        let string: String?
        let databaseOutline = horos_databaseOutline

        if (databaseOutline?.selectedRowIndexes.count ?? 0) == 1 {
            string = (databaseOutline?.item(atRow: databaseOutline?.selectedRowIndexes.first ?? NSNotFound) as? NSObject)?.value(forKey: "name") as? String
        } else {
            string = exportDBListOnlySelected(true)
        }

        // -setString:nil still fulfilled the declared type, with empty data.
        pb.setString(string ?? "", forType: .string)
    }

    // The item is built here, not in a nib, because there is one nib per language
    // and it belongs beside the export that already exists.
    @objc(buildMetadataExportMenuItem)
    func buildMetadataExportMenuItem() {
        guard let existing = BrowserController.item(in: NSApp.mainMenu, withAction: #selector(BrowserController.saveDBListAs(_:))) else { return }

        let title = NSLocalizedString("Export Study Metadata as CSV...", comment: "")
        if (existing.menu?.indexOfItem(withTitle: title) ?? 0) >= 0 { return }

        let item = NSMenuItem(title: title,
                              action: #selector(BrowserController.exportStudyMetadataAsCSV(_:)),
                              keyEquivalent: "")
        item.target = nil                              // through the responder chain, like its neighbour
        existing.menu?.insertItem(item, at: (existing.menu?.index(of: existing) ?? 0) + 1)

        let byList = NSMenuItem(title: NSLocalizedString("Export Studies by Identifier List...", comment: ""),
                                action: #selector(BrowserController.exportStudiesByIdentifierList(_:)),
                                keyEquivalent: "")
        byList.target = nil
        existing.menu?.insertItem(byList, at: (existing.menu?.index(of: item) ?? 0) + 1)

        // Goes to whichever 2D viewer is in front, like the other export commands.
        let cropped = NSMenuItem(title: NSLocalizedString("Export Cropped Series...", comment: ""),
                                 action: NSSelectorFromString("exportCroppedSeries:"),
                                 keyEquivalent: "")
        cropped.target = nil
        existing.menu?.insertItem(cropped, at: (existing.menu?.index(of: byList) ?? 0) + 1)
    }

    @objc(itemInMenu:withAction:)
    class func item(in menu: NSMenu!, withAction action: Selector!) -> NSMenuItem! {
        for item in menu?.items ?? [] {
            if item.action == action { return item }
            if let submenu = item.submenu {
                let found = BrowserController.item(in: submenu, withAction: action)
                if let found { return found }
            }
        }
        return nil
    }

    // One file of this study, to read the tags from. Which one does not matter for
    // study-level tags, and taking it from the study itself is what keeps a row
    // about one patient.
    @objc(aFileOfStudy:)
    func aFile(of study: DicomStudy!) -> String! {
        for case let series as DicomSeries in (study?.series as NSSet?) ?? NSSet() {
            for case let image as DicomImage in (series.images as NSSet?) ?? NSSet() {
                let path = image.completePathResolved()
                if let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    // Five hundred identifiers and no wish to find each one by hand. The list is
    // resolved by identifier and never by name, so two patients who share a name are
    // never merged, and the run leaves a report that can be checked afterwards
    // instead of trusted.
    @objc(exportStudiesByIdentifierList:)
    func exportStudiesByIdentifierList(_ sender: Any!) {
        let list = NSOpenPanel()
        list.allowedFileTypes = ["txt", "csv", "text"]
        list.allowsOtherFileTypes = true
        list.message = NSLocalizedString("Choose the list of patient identifiers, one per line.", comment: "")
        if list.runModal() != .OK { return }

        var error: Error? = nil
        var text: String? = nil
        if let url = list.url {
            do { text = try NSString(contentsOf: url, usedEncoding: nil) as String } catch let e { error = e }
        }
        if text == nil, let url = list.url {
            do { text = try NSString(contentsOf: url, encoding: String.Encoding.utf8.rawValue) as String } catch let e { error = e }
        }
        guard let text else {
            HorosAlertPanel.run(title: NSLocalizedString("Export by Identifier", comment: ""),
                                message: error?.localizedDescription ?? NSLocalizedString("That list could not be read.", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }

        let identifiers = BatchExportManifest.identifiers(fromText: text)
        if identifiers.count == 0 {
            HorosAlertPanel.run(title: NSLocalizedString("Export by Identifier", comment: ""),
                                message: NSLocalizedString("That list holds no identifiers.", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }

        let dryRun = NSButton(checkboxWithTitle: NSLocalizedString("Dry run: write the report, copy nothing", comment: ""), target: nil, action: nil)
        dryRun.frame = NSMakeRect(0, 4, 420, 18)
        let count = NSTextField(labelWithString: String(format: NSLocalizedString("%lu identifier(s) to resolve.", comment: ""), UInt(identifiers.count)))
        count.frame = NSMakeRect(0, 26, 420, 18)
        count.font = NSFont.systemFont(ofSize: 11)
        count.textColor = NSColor.secondaryLabelColor
        let accessory = NSView(frame: NSMakeRect(0, 0, 420, 48))
        accessory.addSubview(dryRun)
        accessory.addSubview(count)

        let destination = NSOpenPanel()
        destination.canChooseFiles = false
        destination.canChooseDirectories = true
        destination.canCreateDirectories = true
        destination.prompt = NSLocalizedString("Export", comment: "")
        destination.message = NSLocalizedString("Choose where to write the studies and the report.", comment: "")
        destination.accessoryView = accessory
        destination.isAccessoryViewDisclosed = true
        if destination.runModal() != .OK { return }

        _ = exportStudies(forIdentifiers: identifiers,
                          toDirectory: destination.url?.path,
                          dryRun: dryRun.state == .on)
    }

    @objc(exportStudiesForIdentifiers:toDirectory:dryRun:)
    func exportStudies(forIdentifiers identifiers: [Any]!, toDirectory directory: String!, dryRun: Bool) -> String! {
        let identifiers = identifiers ?? []
        let directory = (directory ?? "") as NSString
        var rows: [[String]] = [BatchExportManifest.header]
        let files = FileManager.default

        let wait: Wait? = Wait(string: NSLocalizedString("Export by Identifier...", comment: ""), true)
        wait?.setCancel(true)
        wait?.showWindow(self)
        wait?.progress()?.maxValue = Double(identifiers.count)

        var cancelled = false

        for case let identifier as String in identifiers {
            autoreleasepool {
                if cancelled || (wait?.aborted() ?? false) {
                    cancelled = true
                    rows.append(BatchExportManifest.row(identifier: identifier, status: "cancelled",
                                                        names: [], studies: 0, files: 0, bytes: 0,
                                                        digest: "", detail: ""))
                    return // continue
                }

                // By identifier, never by name: two patients who share a name keep
                // their own identifiers and their own studies.
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
                request.predicate = NSPredicate(format: "patientID == %@", identifier)

                var studies: NSArray? = nil
                if let e = objcTry({ studies = (try? database?.managedObjectContext?.fetch(request)) as NSArray? }) { _N2LogExceptionImpl(e, true, "-[BrowserController exportStudiesForIdentifiers:toDirectory:dryRun:]") }

                if (studies?.count ?? 0) == 0 {
                    rows.append(BatchExportManifest.row(identifier: identifier, status: "not found",
                                                        names: [], studies: 0, files: 0, bytes: 0,
                                                        digest: "", detail: ""))
                    wait?.progress()?.increment(by: 1)
                    return // continue
                }

                // One identifier that answers to more than one name is worth saying
                // out loud: it is either a correction or two people in one record.
                let names = NSMutableOrderedSet()
                for case let study as DicomStudy in studies ?? NSArray() {
                    if let name = study.name, !name.isEmpty { names.add(name) }
                }

                let digest = FileSetDigest()
                var trouble: [String] = []
                let folder = directory.appendingPathComponent(BrowserController.replaceNotAdmitted(identifier) as String? ?? "") as NSString

                for case let study as DicomStudy in studies ?? NSArray() {
                    for case let series as DicomSeries in (study.series as NSSet?) ?? NSSet() {
                        for case let image as DicomImage in (series.images as NSSet?) ?? NSSet() {
                            let source = image.completePathResolved() ?? ""
                            if source.isEmpty || files.fileExists(atPath: source) == false {
                                trouble.append(String(format: "missing file for %@", (study.studyInstanceUID as NSString?) ?? "(null)"))
                                continue
                            }

                            digest.add(path: source)

                            if dryRun { continue }

                            let studyFolder = folder.appendingPathComponent(BrowserController.replaceNotAdmitted(study.studyInstanceUID ?? "study") as String? ?? "") as NSString
                            try? files.createDirectory(atPath: studyFolder as String, withIntermediateDirectories: true, attributes: nil)
                            let target = studyFolder.appendingPathComponent((source as NSString).lastPathComponent)
                            if files.fileExists(atPath: target) == false {
                                do {
                                    try files.copyItem(atPath: source, toPath: target)
                                } catch let copyError {
                                    trouble.append(copyError.localizedDescription)
                                }
                            }
                        }
                    }
                    if wait?.aborted() ?? false { cancelled = true; break }
                }

                for unreadable in digest.unreadable {
                    trouble.append(String(format: "unreadable %@", (unreadable as NSString).lastPathComponent))
                }

                let status = cancelled ? "cancelled" : (!trouble.isEmpty ? "failed" : (dryRun ? "dry run" : "exported"))
                rows.append(BatchExportManifest.row(identifier: identifier, status: status,
                                                    names: names.array as? [String] ?? [], studies: studies?.count ?? 0,
                                                    files: digest.fileCount, bytes: digest.byteCount,
                                                    digest: digest.hexDigest,
                                                    detail: trouble.joined(separator: "; ")))
                wait?.progress()?.increment(by: 1)
            }
        }

        wait?.close()

        let report = StudyMetadataExport.csv(fromRows: rows)
        let path = directory.appendingPathComponent("horos-export-manifest.csv")
        try? (StudyMetadataExport.data(forCSV: report) as NSData).write(toFile: path, options: .atomic)
        NSLog("Export by identifier: %lu identifier(s), %@, report at %@",
              UInt(identifiers.count), (cancelled ? "cancelled" : (dryRun ? "dry run" : "exported")) as NSString, path as NSString)
        return report
    }

    @objc(exportStudyMetadataAsCSV:)
    func exportStudyMetadataAsCSV(_ sender: Any!) {
        let defaults = UserDefaults.standard
        var stored = defaults.string(forKey: "StudyMetadataCSVColumns") ?? ""
        if stored.isEmpty {
            stored = StudyMetadataExport.suggestedColumns.joined(separator: "\n")
        }

        let tags = NSTextView(frame: NSMakeRect(0, 26, 380, 190))
        tags.string = stored
        tags.font = NSFont.userFixedPitchFont(ofSize: 11)
        tags.isAutomaticQuoteSubstitutionEnabled = false
        let scroll = NSScrollView(frame: NSMakeRect(0, 26, 380, 190))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tags

        let onlySelected = NSButton(checkboxWithTitle: NSLocalizedString("Only the selected studies", comment: ""), target: nil, action: nil)
        onlySelected.frame = NSMakeRect(0, 2, 380, 18)
        onlySelected.state = (horos_databaseOutline?.selectedRowIndexes.count ?? 0) != 0 ? .on : .off

        let hint = NSTextField(labelWithString: NSLocalizedString("One field per line: a DICOM keyword such as PatientName, or a tag written (0010,0010).", comment: ""))
        hint.frame = NSMakeRect(0, 220, 380, 32)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = NSColor.secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2

        let accessory = NSView(frame: NSMakeRect(0, 0, 380, 254))
        accessory.addSubview(scroll)
        accessory.addSubview(onlySelected)
        accessory.addSubview(hint)

        let panel = NSSavePanel()
        panel.allowedFileTypes = ["csv"]
        panel.nameFieldStringValue = NSLocalizedString("Horos Study Metadata", comment: "")
        panel.accessoryView = accessory

        panel.begin { result in
            if result != .OK { return }

            let columns = StudyMetadataExport.columns(fromText: tags.string)
            defaults.set(tags.string, forKey: "StudyMetadataCSVColumns")

            let csv = self.metadataCSV(forColumns: columns, onlySelected: onlySelected.state == .on) ?? ""
            var error: Error? = nil
            var written = false
            if let url = panel.url {
                do {
                    try (StudyMetadataExport.data(forCSV: csv) as NSData).write(to: url, options: .atomic)
                    written = true
                } catch let writeError {
                    error = writeError
                }
            }
            if written == false {
                HorosAlertPanel.run(title: NSLocalizedString("Export Study Metadata", comment: ""), message: error?.localizedDescription ?? "(null)", defaultButton: nil, alternateButton: nil, otherButton: nil)
            }
        }
    }

    @objc(metadataCSVForColumns:onlySelected:)
    func metadataCSV(forColumns columns: [Any]!, onlySelected: Bool) -> String! {
        let databaseOutline = horos_databaseOutline
        let rows: IndexSet = onlySelected ? (databaseOutline?.selectedRowIndexes ?? IndexSet())
                                          : IndexSet(integersIn: 0 ..< (databaseOutline?.numberOfRows ?? 0))
        let columns = (columns as? [String]) ?? []

        var out: [[String]] = [StudyMetadataExport.headerRow(columns: columns)]
        let done = NSMutableSet()

        for row in rows {
            let item = databaseOutline?.item(atRow: row)
            var study: DicomStudy? = nil

            if objcIsType(item, "Study") { study = item as? DicomStudy }
            else if objcIsType(item, "Series") { study = (item as? NSObject)?.value(forKey: "study") as? DicomStudy }

            // Selecting a study and one of its series must not write the study twice.
            guard let study, done.contains(study.objectID) == false else { continue }
            done.add(study.objectID)

            let path = aFile(of: study)
            let values = path != nil ? (DicomFile.values(forDicomFields: columns, forFile: path) as NSDictionary?) : NSDictionary()
            var stringValues: [String: String] = [:]
            for case let (key as String, value as String) in values ?? NSDictionary() { stringValues[key] = value }
            out.append(StudyMetadataExport.row(columns: columns, values: stringValues))
        }

        return StudyMetadataExport.csv(fromRows: out)
    }

    @objc(saveDBListAs:)
    func saveDBListAs(_ sender: Any!) {
        let list = exportDBListOnlySelected(false)

        let sPanel = NSSavePanel()
        sPanel.allowedFileTypes = ["txt"]
        sPanel.nameFieldStringValue = NSLocalizedString("Horos Database List", comment: "")

        sPanel.begin { result in
            if result != .OK {
                return
            }

            if let url = sPanel.url {
                try? list?.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
