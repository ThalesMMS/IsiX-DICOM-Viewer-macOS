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

// The "Albums TableView functions" block of BrowserController is implemented in
// Swift since #831: an extension of BrowserController, which stays
// Objective-C, with the same selectors. The instance variables it reads are
// reached through BrowserController (SwiftIvars); their retain setters do the
// release of the old value and the retain of the new one the former code
// wrote. The methods serve both the albums table and the comparative studies
// table: each one still tests which table it was sent for.
//
// A message to nil returned nil, NO or 0: an outlet is an optional chain and
// that value is the default. The comparisons of a signed row with an
// NSUInteger count were unsigned, so a row of -1 was "past the end": they keep
// UInt(bitPattern:). The comparative studies are DicomStudy or
// DCMTKStudyQueryNode objects the former code sent the same messages to:
// objcMessage sends them by selector. An @try is HorosObjCException.perform,
// an @synchronized is objcSynchronized (the same recursive lock on the same
// object), the method-scope statics are file-scope variables, and the former
// NSAutoreleasePools are autoreleasepool blocks.

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

/// `[object selector]` for a method that returns an object: nil for a nil
/// object, an unrecognized selector exception as before for an object that
/// does not implement it.
fileprivate func objcMessage(_ object: Any?, _ selector: String) -> Any? {
    guard let object = object as AnyObject? else { return nil }
    return object.perform(NSSelectorFromString(selector))?.takeUnretainedValue()
}

/// `[object isDistant]`: NO for nil.
fileprivate func objcIsDistant(_ object: Any?) -> Bool {
    return (object as AnyObject?)?.isDistant?() ?? false
}

/// `[object boolValue]` of an NSNumber or an NSString, NO for nil.
fileprivate func objcBoolValue(_ object: Any?) -> Bool {
    if let number = object as? NSNumber { return number.boolValue }
    if let string = object as? NSString { return string.boolValue }
    return false
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

/// N2LocalizedSingularPluralCount(c, s, p) of N2Stuff.h.
fileprivate func singularPluralCount(_ count: Int, _ singular: String, _ plural: String) -> String {
    return String(format: "%@ %@", NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal), count == 1 ? singular : plural)
}

/// DLog of N2Debug.h: NSLog in a DEBUG build, otherwise only while N2Debug is
/// active.
fileprivate func DLog(_ format: String, _ arguments: CVarArg...) {
    #if DEBUG
    withVaList(arguments) { NSLogv(format, $0) }
    #else
    if N2Debug.isActive() { withVaList(arguments) { NSLogv(format, $0) } }
    #endif
}

/// A `%@` argument: the object, or "(null)" as Objective-C printed nil.
fileprivate func objcFormatArgument(_ object: Any?) -> CVarArg {
    if let object = object as? NSObject { return object }
    if let object { return String(describing: object) as NSString }
    return "(null)" as NSString
}

/// DISTANTSTUDYFONT.
fileprivate let DISTANTSTUDYFONT = "Helvetica-BoldOblique"

/// MAX_CONCURRENT_comparativeRetrieve.
fileprivate let MAX_CONCURRENT_comparativeRetrieve = 5

/// -comparativeRetrieve:'s `static dispatch_semaphore_t sid`.
fileprivate var sid: DispatchSemaphore? = nil

/// -saveLoadAlbumsSortDescriptors's `static id previousSelectedAlbumId`,
/// retained as before.
fileprivate var previousSelectedAlbumId: Any? = nil
/// -saveLoadAlbumsSortDescriptors's `static void* previousDatabase`: the
/// address alone, not retained.
fileprivate var previousDatabase: UnsafeMutableRawPointer? = nil

extension BrowserController: NSTableViewDelegate {}

public extension BrowserController {

    // MARK: - Albums TableView functions

    //NSTableView delegate and datasource
    @objc(numberOfRowsInTableView:)
    func numberOfRows(in aTableView: NSTableView) -> Int {
        if aTableView.isEqual(horos_albumTable) && self.database != nil {
            return self.albumArray()?.count ?? 0
        }

        if aTableView.isEqual(horos_comparativeTable) && self.database != nil {
            return horos_comparativeStudies?.count ?? 0
        }

        return 0
    }

    @objc(tableView:objectValueForTableColumn:row:)
    func tableView(_ aTableView: NSTableView, objectValueFor aTableColumn: NSTableColumn?, row rowIndex: Int) -> Any? {
        return nil
    }

    @objc(tableView:willDisplayCell:forTableColumn:row:)
    func tableView(_ aTableView: NSTableView, willDisplayCell aCell: Any, for aTableColumn: NSTableColumn?, row rowIndex: Int) {
        if let exception = objcTry({
            if aTableView.isEqual(self.horos_albumTable) {
                let txtFont: NSFont
                let cell = aCell as? PrettyCell

                if rowIndex == 0 { txtFont = NSFont.boldSystemFont(ofSize: CGFloat(self.fontSize("dbAlbumFont"))) }
                else { txtFont = NSFont.systemFont(ofSize: CGFloat(self.fontSize("dbAlbumFont"))) }

                cell?.font = txtFont

                let albumArray = self.albumArray() as NSArray?

                if UInt(albumArray?.count ?? 0) > UInt(bitPattern: rowIndex) && objcBoolValue((albumArray?.object(at: rowIndex) as AnyObject?)?.value(forKey: "smartAlbum")) {
                    if !(self.database?.isLocal() ?? false) {
                        cell?.image = NSImage(named: "small_sharedSmartAlbum.tif")
                    } else { cell?.image = NSImage(named: "small_smartAlbum.tif") }
                } else {
                    if !(self.database?.isLocal() ?? false) {
                        cell?.image = NSImage(named: "small_sharedAlbum.tif")
                    } else { cell?.image = NSImage(named: "small_album.tif") }
                }

                // -setTitle: nil, which the Swift title (a String) cannot take.
                _ = cell?.perform(#selector(setter: NSButtonCell.title), with: nil)
                if rowIndex >= 0 && rowIndex < (albumArray?.count ?? 0) {
                    _ = cell?.perform(#selector(setter: NSButtonCell.title), with: (albumArray?.object(at: rowIndex) as AnyObject?)?.value(forKey: "name"))
                }

                var noOfStudies: String? = nil
                let albumNoOfStudiesCache = self.horos_albumNoOfStudiesCache
                objcSynchronized(albumNoOfStudiesCache) {
                    if albumNoOfStudiesCache == nil ||
                        UInt(bitPattern: rowIndex) >= UInt(albumNoOfStudiesCache?.count ?? 0) ||
                        (albumNoOfStudiesCache?.object(at: rowIndex) as? NSString)?.isEqual(to: "") == true {
                        self.refreshAlbums()
                        // It will be computed in a separate thread, and then displayed later.
                        noOfStudies = "#"
                    } else {
                        noOfStudies = (albumNoOfStudiesCache?.object(at: rowIndex) as? NSString)?.copy() as? String
                    }
                }

                cell?.rightText = noOfStudies as NSString?
            }

            if aTableView.isEqual(self.horos_comparativeTable) {
                let cell = aCell as? ComparativeCell
                let comparativeStudies = self.horos_comparativeStudies as NSArray?

                if rowIndex >= 0 && rowIndex < (comparativeStudies?.count ?? 0) && self.database != nil {
                    let txtFont: NSFont?
                    var local = false

                    let study = comparativeStudies?.object(at: rowIndex)

                    if (study as AnyObject?)?.isKind(of: DicomStudy.self) == true {
                        local = true
                    }

                    if local { txtFont = NSFont.boldSystemFont(ofSize: CGFloat(self.fontSize("dbComparativeFont"))) }
                    else { txtFont = NSFont(name: DISTANTSTUDYFONT, size: CGFloat(self.fontSize("dbComparativeFont"))) }

                    cell?.font = txtFont
                    cell?.title = "DUMMY" // avoid NIL values here

                    cell?.leftTextFirstLine = objcMessage(study, "studyName") as? NSString
                    cell?.rightTextFirstLine = objcMessage(study, "modality") as? NSString
                    cell?.leftTextSecondLine = (objcMessage(study, "date") as? Date).flatMap { UserDefaults.dateFormatter()?.string(from: $0) } as NSString?
                    cell?.rightTextSecondLine = singularPluralCount(abs(Int((objcMessage(study, "numberOfImages") as? NSNumber)?.int32Value ?? 0)), NSLocalizedString("image", comment: ""), NSLocalizedString("images", comment: "")) as NSString
                } else {
                    cell?.title = ""
                    cell?.leftTextFirstLine = ""
                    cell?.rightTextFirstLine = ""
                    cell?.leftTextSecondLine = ""
                    cell?.rightTextSecondLine = ""
                }
            }
        }) {
            _N2LogExceptionImpl(exception, false, "-[BrowserController tableView:willDisplayCell:forTableColumn:row:]")
        }
    }

    @objc(findStudyUID:)
    func findStudyUID(_ uid: String!) -> NSManagedObject! {
        var studyArray: [Any]? = nil
        let request = NSFetchRequest<NSFetchRequestResult>()
        let context = BrowserController.currentBrowser()?.database?.managedObjectContext
        let predicate = uid.map { NSPredicate(format: "(studyInstanceUID == %@)", $0) } ?? NSPredicate(format: "(studyInstanceUID == nil)")

        request.entity = self.database?.managedObjectModel?.entitiesByName["Study"]
        request.predicate = predicate

        context?.lock()

        if let e = objcTry({
            studyArray = try? context?.fetch(request)
        }) {
            _N2LogExceptionImpl(e, true, "-[BrowserController findStudyUID:]")
        }

        context?.unlock()

        if (studyArray?.count ?? 0) != 0 { return studyArray?[0] as? NSManagedObject }
        else { return nil }
    }

    @objc(findSeriesUID:)
    func findSeriesUID(_ uid: String!) -> NSManagedObject! {
        var seriesArray: [Any]? = nil
        let request = NSFetchRequest<NSFetchRequestResult>()
        let context = BrowserController.currentBrowser()?.database?.managedObjectContext
        let predicate = uid.map { NSPredicate(format: "(seriesDICOMUID == %@)", $0) } ?? NSPredicate(format: "(seriesDICOMUID == nil)")

        request.entity = BrowserController.currentBrowser()?.database?.managedObjectModel?.entitiesByName["Series"]
        request.predicate = predicate

        context?.lock()

        if let e = objcTry({
            seriesArray = try? context?.fetch(request)
        }) {
            _N2LogExceptionImpl(e, true, "-[BrowserController findSeriesUID:]")
        }

        context?.unlock()

        if (seriesArray?.count ?? 0) != 0 { return seriesArray?[0] as? NSManagedObject }
        else { return nil }
    }

    @available(*, deprecated)
    @objc(sendFilesToCurrentBonjourDB:)
    func sendFiles(toCurrentBonjourDB files: [Any]!) {
        autoreleasepool {
            if !(self.database?.isLocal() ?? false) {
                (self.database as? RemoteDicomDatabase)?.uploadFiles(atPaths: files, imageObjects: nil, generatedByOsiriX: false)
            }
        }
    }

    @objc(sendFilesToCurrentBonjourGeneratedByOsiriXDB:)
    func sendFilesToCurrentBonjourGenerated(byOsiriXDB files: [Any]!) {
        autoreleasepool {
            if !(self.database?.isLocal() ?? false) {
                (self.database as? RemoteDicomDatabase)?.uploadFiles(atPaths: files, imageObjects: nil, generatedByOsiriX: true)
            }
        }
    }

    @objc(DatabaseObjectXIDsPasteboardTypes)
    class func databaseObjectXIDsPasteboardTypes() -> [String]! {
        return [O2PasteboardTypeDatabaseObjectXIDs,
                O2DatabaseXIDsDragType]
    }

    @objc(tableView:acceptDrop:row:dropOperation:)
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        if tableView.isEqual(horos_albumTable) {
            let albumArray = self.albumArray() as NSArray?

            if UInt(bitPattern: row) >= UInt(albumArray?.count ?? 0) || row == 0 { // can't add to database
                return false
            }
            if objcBoolValue((albumArray?.object(at: row) as AnyObject?)?.value(forKey: "smartAlbum")) { // // can't add to smart album -- this should not be happening: validateDrop avoids it...
                return false
            }

            let album = albumArray?.object(at: row) as? DicomAlbum

            let pb = info.draggingPasteboard
            // One pasteboard item per dragged row: read them all, not the first (#605).
            let xids = BrowserController.databaseObjectXIDs(on: pb) as NSArray?
            let items = NSMutableArray()
            for case let xid as String in xids ?? [] {
                let object = self.database?.object(withID: NSManagedObject.uid(forXid: xid))
                if let object { items.add(object) }
            }

            let studies = NSMutableArray()
            for case let object as NSManagedObject in items {
                // A nil study was an NSInvalidArgumentException of -addObject:;
                // NSMutableArray.add cannot take nil, so it is skipped.
                if object.isKind(of: DicomStudy.self) {
                    studies.add(object)
                }
                if object.isKind(of: DicomSeries.self) {
                    if let study = (object as? DicomSeries)?.study { studies.add(study) }
                }
                if object.isKind(of: DicomImage.self) {
                    if let study = (object as? DicomImage)?.series?.study { studies.add(study) }
                }
            }

            if studies.count != 0 {
                self.database?.addStudies(studies as? [Any], to: album)
                _ = self.database?.save()
                self.refreshAlbums()
                return true
            }
        }

        return false
    }

    @objc(tableView:validateDrop:proposedRow:proposedDropOperation:)
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        if operation != .on {
            return []
        }

        if tableView.isEqual(horos_albumTable) {
            let array = self.albumArray() as NSArray?

            if (UInt(bitPattern: row) >= UInt(array?.count ?? 0)) || objcBoolValue((array?.object(at: row) as AnyObject?)?.value(forKey: "smartAlbum")) || row == 0 { return [] }

            horos_albumTable?.setDropRow(row, dropOperation: .on)

            return .link
        }

        return []
    }

    @objc(tableView:toolTipForCell:rect:tableColumn:row:mouseLocation:)
    func tableView(_ tv: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn tc: NSTableColumn?, row: Int, mouseLocation: NSPoint) -> String {
        // The row is -1 outside the rows, where -objectAtIndex: raised.
        if tv === horos_comparativeTable, let studies = horos_comparativeStudies as NSArray?, row >= 0, row < studies.count {
            if objcIsDistant(studies.object(at: row)) {
                return NSLocalizedString("Double-Click to retrieve", comment: "")
            }
        }

        // The former nil: the protocol's Swift signature returns a String, and
        // an empty tool tip is not shown.
        return ""
    }

    @objc(databaseAlbumSortDescriptorsPlistPath)
    func databaseAlbumSortDescriptorsPlistPath() -> String! {
        return (self.database?.dataBaseDirPath as NSString?)?.appendingPathComponent("AlbumSortDescriptors.plist")
    }

    @objc(saveSortDescriptors:)
    func saveSortDescriptors(_ album: DicomAlbum!) {
        // save the sortDescriptor
        if self.database != nil && album != nil {
            let albums = self.albumArray() as NSArray?

            let albumSortDescriptors = horos_databaseOutline?.sortDescriptors

            var plist = self.databaseAlbumSortDescriptorsPlistPath().flatMap { NSMutableDictionary(contentsOfFile: $0) }
            if plist == nil { plist = NSMutableDictionary() }
            let dictionary = plist!

            let livingAlbumsXIDs = albums?.value(forKeyPath: "XID") as? NSArray
            for key in dictionary.allKeys {
                if !((key as? NSString)?.isEqual(to: "Database") ?? false) && !(livingAlbumsXIDs?.contains(key) ?? false) {
                    dictionary.removeObject(forKey: key)
                }
            }

            var key: String? = nil
            // The album may be the NSDictionary -_albumWithID: stands for the
            // database with: isKindOfClass: is asked of the object itself.
            if (album as AnyObject).isKind(of: DicomAlbum.self) {
                key = album.xid()
            } else { key = "Database" }

            let cols = NSMutableArray()
            for column in horos_databaseOutline?.tableColumns ?? [] {
                if !column.isHidden {
                    let col = objcArray(column.identifier.rawValue, NSNumber(value: Int(column.width)))
                    cols.add(col)
                }
            }

            if let key {
                dictionary.setObject(objcArray(albumSortDescriptors.map { NSKeyedArchiver.archivedData(withRootObject: $0) }, cols), forKey: key as NSString)
            }

            if let path = self.databaseAlbumSortDescriptorsPlistPath() {
                dictionary.write(toFile: path, atomically: true)
            }
        }
    }

    @objc(loadSortDescriptors:)
    func loadSortDescriptors(_ album: DicomAlbum!) {
        if NSApplication.shared.currentEvent?.modifierFlags.contains(.command) == true {
            return
        }

        if self.database != nil && album != nil {
            // load the sortDescriptor

            var key: String? = nil
            if (album as AnyObject).isKind(of: DicomAlbum.self) {
                key = album.xid()
            } else { key = "Database" }

            let plist = self.databaseAlbumSortDescriptorsPlistPath().flatMap { NSDictionary(contentsOfFile: $0) }

            let a = key.flatMap { plist?.object(forKey: $0) } as? NSArray
            if let a {
                let databaseOutline = horos_databaseOutline
                // -setSortDescriptors: with what was archived, nil included.
                _ = databaseOutline?.perform(#selector(setter: NSTableView.sortDescriptors), with: (a.object(at: 0) as? Data).flatMap { NSKeyedUnarchiver.unarchiveObject(with: $0) })
                let cols = a.object(at: 1) as? NSArray

                let tableColumns = databaseOutline?.tableColumns ?? []
                let unvisitedColumns = NSMutableArray(array: tableColumns)
                var index = 0
                for case let col as NSArray in cols ?? [] {
                    var column: NSTableColumn? = nil
                    for icolumn in tableColumns {
                        if let identifier = col.object(at: 0) as? String, (icolumn.identifier.rawValue as NSString).isEqual(to: identifier) {
                            column = icolumn
                            break
                        }
                    }
                    if let column {
                        unvisitedColumns.remove(column)
                        if databaseOutline?.column(withIdentifier: column.identifier) == -1 {
                            databaseOutline?.addTableColumn(column)
                        }
                        column.isHidden = false
                        column.width = CGFloat((col.object(at: 1) as AnyObject).integerValue ?? 0)
                        databaseOutline?.moveColumn(databaseOutline?.column(withIdentifier: column.identifier) ?? 0, toColumn: index)
                        index += 1
                    } else {
                        DLog("Warning: invalid column identifier %@", objcFormatArgument(col))
                    }
                }
                for case let column as NSTableColumn in unvisitedColumns {
                    column.isHidden = true
                }
            }
        }
    }

    @objc(_albumWithID:)
    func _album(withID theId: Any!) -> DicomAlbum! {
        if (theId as AnyObject?)?.isKind(of: NSManagedObjectID.self) == true {
            return self.database?.object(withID: theId) as? DicomAlbum
        }
        if theId != nil {
            // (id)[NSDictionary dictionary]: the stand-in for the database,
            // which is not a DicomAlbum; only Objective-C messages reach it.
            return unsafeBitCast(NSDictionary(), to: DicomAlbum.self)
        }
        return nil
    }

    @objc(saveLoadAlbumsSortDescriptors)
    func saveLoadAlbumsSortDescriptors() {
        if horos_databaseOutline == nil {
            return
        }

        let database = self.database.map { Unmanaged.passUnretained($0).toOpaque() }
        if database != previousDatabase {
            previousSelectedAlbumId = nil
        }
        previousDatabase = database

        let albums = self.albumArray() as NSArray?
        if (albums?.count ?? 0) == 0 {
            return
        }

        if let previousSelectedAlbumId {
            self.saveSortDescriptors(self._album(withID: previousSelectedAlbumId))
        }

        var selectedAlbum: AnyObject? = nil

        // The selected row's identifier, as previousSelectedAlbumId keeps it:
        // the album's objectID, or an empty dictionary for the Database row.
        // The album itself was compared with the identifier, which never
        // matched, and the sort descriptors were loaded again on every call
        // (#850).
        func albumID(_ album: AnyObject?) -> NSObject? {
            if album?.isKind(of: DicomAlbum.self) == true {
                return (album as? DicomAlbum)?.objectID
            }
            return NSDictionary()
        }

        // A selected row past the end of the albums, when the table has not
        // been reloaded since the albums changed, is taken as no selection:
        // -objectAtIndex: raised there (#872).
        let selection = horos_albumTable?.selectedRow ?? 0
        if selection >= 0 && selection < (albums?.count ?? 0) {
            selectedAlbum = albums?.object(at: selection) as AnyObject?
            if let previousSelectedAlbumId, albumID(selectedAlbum)?.isEqual(previousSelectedAlbumId) == true {
                return
            }
        }

        if self.database == nil {
            previousSelectedAlbumId = nil
        } else {
            previousSelectedAlbumId = albumID(selectedAlbum)
        }

        if let previousSelectedAlbumId {
            self.loadSortDescriptors(self._album(withID: previousSelectedAlbumId))
        }
    }

    @objc(comparativeRetrieve:)
    func comparativeRetrieve(_ study: DCMTKStudyQueryNode!) {
        autoreleasepool {
            if horos_comparativeRetrieveQueue == nil {
                horos_comparativeRetrieveQueue = NSMutableArray()
            }

            if sid == nil {
                sid = DispatchSemaphore(value: MAX_CONCURRENT_comparativeRetrieve)
            }
            let semaphore = sid!

            semaphore.wait()

            if Thread.current.isCancelled == false {
                let comparativeRetrieveQueue = horos_comparativeRetrieveQueue
                objcSynchronized(comparativeRetrieveQueue) {
                    // A nil study was an NSInvalidArgumentException of
                    // -addObject:; NSMutableArray.add cannot take nil.
                    if let study { comparativeRetrieveQueue?.add(study) }
                }

                // No time for decompression. The retrievals running at once share one save of the
                // setting, so that none of them restores the 0 another set (#849).
                ListenerCompressionSuspension.shared.begin()

                QueryController.retrieveStudies(study.map { [$0] } ?? [], showErrors: false, checkForPreviousAutoRetrieve: false)

                let idb = DicomDatabase.activeLocal()?.independentDatabase() as? DicomDatabase

                _ = idb?.importFilesFromIncomingDir()

                //Files in the decompress/compress thread?
                if idb?.waitForCompressThread() == true {
                    _ = idb?.importFilesFromIncomingDir()
                }

                ListenerCompressionSuspension.shared.end()

                let queue = horos_comparativeRetrieveQueue
                objcSynchronized(queue) {
                    if let study { queue?.remove(study) }
                }
            }
            semaphore.signal()
        }
    }

    @objc(retrieveComparativeStudy:select:open:)
    func retrieveComparativeStudy(_ study: DCMTKStudyQueryNode!, select: Bool, open: Bool) {
        self.retrieveComparativeStudy(study, select: select, open: open, showGUI: true)
    }

    @objc(retrieveComparativeStudy:select:open:showGUI:)
    func retrieveComparativeStudy(_ study: DCMTKStudyQueryNode!, select: Bool, open: Bool, showGUI: Bool) {
        self.retrieveComparativeStudy(study, select: select, open: open, showGUI: showGUI, viewer: nil)
    }

    @objc(retrieveComparativeStudy:select:open:showGUI:viewer:)
    func retrieveComparativeStudy(_ study: DCMTKStudyQueryNode!, select: Bool, open: Bool, showGUI: Bool, viewer: ViewerController!) {
        var retrieveStudy = true

        let comparativeRetrieveQueue = horos_comparativeRetrieveQueue
        objcSynchronized(comparativeRetrieveQueue) {
            if let study, comparativeRetrieveQueue?.contains(study) == true {
                retrieveStudy = false
            }
        }

        if retrieveStudy {
            var w: WaitRendering? = nil

            if showGUI {
                w = WaitRendering(NSLocalizedString("Retrieving...", comment: ""))
            }
            w?.showWindow(self)

            let t = Thread(target: self, selector: #selector(BrowserController.comparativeRetrieve(_:)), object: study)
            t.name = NSLocalizedString("Retrieving images...", comment: "")
            t.status = singularPluralCount(1, NSLocalizedString("study", comment: ""), NSLocalizedString("studies", comment: ""))
            t.supportsCancel = true
            ThreadsManager.default()?.addThreadAndStart(t)

            if showGUI {
                Thread.sleep(forTimeInterval: 0.5)
            }
            w?.close()
        }

        // see refreshComparativeStudiesIfNeeded timer
        if open || select {
            horos_comparativeStudyWaitedToOpen = open
            horos_comparativeStudyWaitedToSelect = select
            horos_comparativeStudyWaited = study
            horos_comparativeStudyWaitedTime = Date.timeIntervalSinceReferenceDate

            horos_comparativeStudyWaitedViewer = viewer
        }
    }

    @objc(doubleClickComparativeStudy:)
    func doubleClickComparativeStudy(_ sender: Any!) {
        self.checkIfLocalStudyHasMoreOrSameNumberOfImages(ofADistantStudy: nil)

        // The row that was double-clicked, not the one still selected: a double
        // click outside the rows (-1) opens nothing.
        let row = horos_comparativeTable?.clickedRow ?? -1
        let studies = horos_comparativeStudies as NSArray?
        let study = (row >= 0 && row < (studies?.count ?? 0)) ? studies?.object(at: row) : nil

        if let study {
            if objcIsDistant(study) {
                // Check to see if already in retrieving mode, if not download it
                self.retrieveComparativeStudy(study as? DCMTKStudyQueryNode, select: true, open: false)
            } else {
                _ = self.selectThisStudy(study)
                self.window?.makeFirstResponder(horos_databaseOutline)
                self.databaseOpenStudy(study as? NSManagedObject)
            }
        }
    }

    @objc(tableViewSelectionDidChange:)
    func tableViewSelectionDidChange(_ aNotification: Notification) {
        if let e = objcTry({
            if (aNotification.object as AnyObject?) === self.horos_albumTable {
                let albumArray = self.albumArray() as NSArray?
                let albumTable = self.horos_albumTable

                self.selectedAlbumName = nil

                if UInt(albumArray?.count ?? 0) > UInt(bitPattern: albumTable?.selectedRow ?? 0) {
                    self.selectedAlbumName = (albumArray?.object(at: albumTable?.selectedRow ?? 0) as AnyObject?)?.value(forKey: "name") as? String
                }

                if UserDefaults.standard.bool(forKey: "clearSearchAndTimeIntervalWhenSelectingAlbum") {
                    // Clear search field
                    self.searchString = nil

                    // Clear the time interval
                    if (CustomIntervalPanel.sharedCustomIntervalPanel()?.window?.isVisible ?? false) == false {
                        self.timeIntervalType = 0
                    }

                    self.modalityFilter = nil
                } else {
                    self.searchString = self.searchString
                }

                self.refreshAlbums()

                // Distant Smart Albums
                if UserDefaults.standard.bool(forKey: "searchForSmartAlbumStudiesOnDICOMNodes") && (albumTable?.selectedRow ?? 0) > 0 {
                    if UInt(albumArray?.count ?? 0) > UInt(bitPattern: albumTable?.selectedRow ?? 0) {
                        let album = albumArray?.object(at: albumTable?.selectedRow ?? 0) as? DicomAlbum

                        if objcBoolValue(album?.value(forKey: "smartAlbum")) == true {
                            Thread.detachNewThreadSelector(#selector(BrowserController.search(forSmartAlbumDistantStudies:)), toTarget: self, with: album?.name)
                        }
                    }
                }

                // outlineview sortdescriptors

                self.saveLoadAlbumsSortDescriptors()
            }

            if (aNotification.object as AnyObject?) === self.horos_comparativeTable {
                let comparativeTable = self.horos_comparativeTable
                let comparativeStudies = self.horos_comparativeStudies as NSArray?
                if (comparativeTable?.selectedRow ?? 0) >= 0 && (comparativeTable?.selectedRow ?? 0) < (comparativeStudies?.count ?? 0) {
                    let study = comparativeStudies?.object(at: comparativeTable?.selectedRow ?? 0)

                    if let study, self.horos_dontSelectStudyFromComparativeStudies == false {
                        //                    #ifndef OSIRIX_LIGHT
                        do {
                            if self.selectThisStudy(study) && self.window?.firstResponder !== self.horos_searchField && self.window?.firstResponder !== self.horos_searchField?.currentEditor() {
                                self.window?.makeFirstResponder(self.horos_databaseOutline)
                            }
                        }
                    }
                }
            }
        }) {
            NSLog("tableViewSelectionDidChange exception: %@", e)
            AppController.printStackTrace(e)
        }
    }
}
