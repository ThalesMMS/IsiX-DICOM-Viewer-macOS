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

// The albums of the browser: the list of the albums table, the cache of the
// database's albums, adding, renaming and deleting an album or a smart album,
// and the predicate of a smart album. The names an album is saved under and
// the dates a smart album names are IsiXDatabase's AlbumNaming and
// SmartAlbumDateVariables. The selectors are those of the former
// Objective-C methods, as the nib, the menus and the plugins send them.

extension BrowserController {

    // MARK: The albums of the database

    /// The database's albums, fetched once per context and then copied from
    /// the cache, which the album changes and a change of database clear.
    /// Asked on any thread.
    @discardableResult
    @objc(albumsInDatabase)
    nonisolated func albumsInDatabase() -> [Any]! {
        var albums = NSArray()
        guard let database = self.database, let context = database.managedObjectContext else {
            return albums as? [Any]
        }
        var cached: NSArray?
        if let exception = BrowserObjC.attempt({
            cached = BrowserObjC.synchronized(self) { () -> NSArray? in
                if let current = horos_cachedAlbums, let cachedContext = horos_cachedAlbumsContext, cachedContext === context {
                    return current as NSArray
                }
                return nil
            }
            if cached != nil { return }

            let fetched = (database.albums() as NSArray?) ?? NSArray()
            albums = fetched
            BrowserObjC.synchronized(self) {
                horos_cachedAlbums = fetched as? [Any]
                horos_cachedAlbumsIDs = fetched.value(forKey: "objectID") as? [Any]
                horos_cachedAlbumsContext = database.managedObjectContext
            }
        }) {
            BrowserObjC.log(exception, "-[BrowserController albumsInDatabase]")
        }
        return ((cached ?? albums).copy() as? NSArray) as? [Any]
    }

    @discardableResult
    @objc(albums)
    nonisolated func albums() -> [Any]! {
        return albumsInDatabase()
    }

    /// The rows of the albums table: "Database" first, then the albums.
    @discardableResult
    @objc(albumArray)
    func albumArray() -> [Any]! {
        guard let database = self.database, database.managedObjectContext != nil else { return [] }
        let all = NSDictionary(object: NSLocalizedString("Database", comment: ""), forKey: "name" as NSString)
        return ([all] as NSArray).addingObjects(from: albumsInDatabase() ?? []) as [Any]
    }

    /// Forgets the cached albums, so that the next request fetches them.
    nonisolated func forgetCachedAlbums() {
        BrowserObjC.synchronized(self) {
            horos_cachedAlbumsContext = nil
        }
    }

    /// The album selected in the table, found by name in `d`: the browser's
    /// database on the main thread, a private-queue one of it elsewhere when
    /// `d` is nil. Asked on any thread.
    @discardableResult
    @objc(currentAlbumID:)
    nonisolated func currentAlbumID(_ d: DicomDatabase!) -> NSManagedObjectID! {
        let database: DicomDatabase? = d ?? (Thread.isMainThread ? self.database : self.database?.privateQueueIndependentDatabase() as? DicomDatabase)
        guard let albumName = self.selectedAlbumName, let database else { return nil }

        var albumID: NSManagedObjectID?
        database.performBlockAndWait {
            let found = database.objects(forEntity: database.albumEntity(), predicate: NSPredicate(format: "name == %@", albumName)) as NSArray?
            albumID = (found?.lastObject as? NSManagedObject)?.objectID
        }
        return albumID
    }

    @objc(defaultAlbums:)
    func defaultAlbums(_ sender: Any!) {
        self.database?.addDefaultAlbums()
        forgetCachedAlbums()
        _ = albumsInDatabase()
        refreshAlbums()
    }

    @objc(selectNoAlbums:)
    func selectNoAlbums(_ sender: Any!) {
        // Selecting "Database" keeps the search and the time interval.
        let defaults = UserDefaults.standard
        let clears = defaults.bool(forKey: "clearSearchAndTimeIntervalWhenSelectingAlbum")
        defaults.set(false, forKey: "clearSearchAndTimeIntervalWhenSelectingAlbum")
        horos_albumTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        defaults.set(clears, forKey: "clearSearchAndTimeIntervalWhenSelectingAlbum")
    }

    @objc(selectAlbumWithName:)
    func selectAlbum(withName name: String!) {
        for case let album as DicomAlbum in ((self.database?.albums() as NSArray?) ?? []) where BrowserObjC.literallyEqual(album.name, name) {
            selectAlbumRow(album)
        }
    }

    /// Selects the album's row, when the table has it.
    private func selectAlbumRow(_ album: Any) {
        let index = ((albumArray() as NSArray?) ?? []).index(of: album)
        if index != NSNotFound {
            horos_albumTable?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    // MARK: Smart albums

    /// The predicate of a smart album's stored format, with its dates taken
    /// at the moment it is asked. An empty format keeps every study; a format
    /// that cannot be read raises, as it always did.
    @discardableResult
    @objc(smartAlbumPredicateString:)
    nonisolated func smartAlbumPredicateString(_ string: String!) -> NSPredicate! {
        guard let string, (string as NSString).length > 0 else { return NSPredicate(value: true) }

        let variables = SmartAlbumDateVariables(now: Date(), timeZone: NSTimeZone.default)
        var predicate: NSPredicate?
        if let exception = BrowserObjC.attempt({
            predicate = NSPredicate(format: variables.expandedFormat(string))
        }) {
            exception.raise()
        }
        return predicate?.withSubstitutionVariables(variables.substitutionVariables)
    }

    /// The album's predicate, or one that keeps nothing when its format
    /// cannot be read.
    @discardableResult
    @objc(smartAlbumPredicate:)
    nonisolated func smartAlbumPredicate(_ album: NSManagedObject!) -> NSPredicate! {
        var predicate: NSPredicate?
        if let exception = BrowserObjC.attempt({
            predicate = smartAlbumPredicateString(album?.value(forKey: "predicateString") as? String)
        }) {
            predicate = NSPredicate(value: false)
            BrowserObjC.log(exception, stack: true, "-[BrowserController smartAlbumPredicate:]")
        }
        return predicate
    }

    @objc(addSmartAlbum:)
    func addSmartAlbum(_ sender: Any!) {
        guard let controller = SmartWindowController(database: self.database), let sheet = controller.window else { return }
        self.window?.beginSheet(sheet) { returnCode in
            self.smartAlbumSheetDidEnd(sheet, returnCode: returnCode.rawValue, contextInfo: nil)
            _ = controller
        }
    }

    /// The end of the smart album sheet. `contextInfo` is the album being
    /// edited, retained when the sheet was shown and released here, or nil
    /// for a new one.
    @objc(smartAlbumSheetDidEnd:returnCode:contextInfo:)
    func smartAlbumSheetDidEnd(_ sheet: NSWindow!, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        sheet.orderOut(self)

        let existingAlbum = contextInfo.map { Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue() }
        guard returnCode == NSApplication.ModalResponse.stop.rawValue, let database = self.database else { return }

        let album = (existingAlbum as? DicomAlbum) ?? (database.newObject(forEntity: database.albumEntity()) as? DicomAlbum)
        let controller = sheet.windowController as? SmartWindowController

        album?.name = controller?.name
        album?.smartAlbum = NSNumber(value: true)
        album?.predicateString = controller?.predicate?.predicateFormat
        _ = database.save()

        horos_albumTable?.reloadData()
        if let album { selectAlbumRow(album) }
        forgetCachedAlbums()
        if let album { selectAlbumRow(album) }

        outlineViewRefresh()
        refreshAlbums()
    }

    // MARK: Albums

    /// The album name sheet, run modally on the browser: whether it ended with
    /// OK.
    private func runAlbumNameSheet() -> Bool {
        guard let sheet = horos_newAlbum else { return false }
        self.window?.beginSheet(sheet, completionHandler: nil)
        let result = NSApp.runModal(for: sheet)
        sheet.makeFirstResponder(nil)
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(self)
        return result == .stop
    }

    /// The names of the database's albums, as stored.
    private func albumNames(in context: NSManagedObjectContext) throws -> [String] {
        let request = NSFetchRequest<NSFetchRequestResult>()
        request.entity = self.database?.managedObjectModel?.entitiesByName["Album"]
        request.predicate = NSPredicate(value: true)
        let albums = try context.fetch(request) as NSArray
        return (albums.value(forKey: "name") as? [Any] ?? []).compactMap { $0 as? String }
    }

    @objc(addAlbum:)
    func addAlbum(_ sender: Any!) {
        guard runAlbumNameSheet(), let context = self.database?.managedObjectContext else { return }

        N2ManagedObjectContextPerformAndWait(context) {
            if let exception = BrowserObjC.attempt({
                let requested = horos_newAlbumName?.stringValue ?? ""
                let name = AlbumNaming.uniqueName(for: requested, existing: (try? albumNames(in: context)) ?? [])
                let album = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context)
                album.setValue(name, forKey: "name")
                _ = self.database?.save()
                refreshAlbums()
            }) {
                NSLog("***** exception in %@: %@", "-[BrowserController addAlbum:]", exception)
                exception.printStackTrace()
            }
        }
        outlineViewRefresh()
    }

    @objc(deleteAlbum:)
    func deleteAlbum(_ sender: Any!) {
        guard let row = horos_albumTable?.selectedRow, row > 0,
              let album = (albumArray() as NSArray?)?.object(at: row) as? DicomAlbum else { return }
        removeAlbumObject(album)
    }

    /// The albums table's contextual menu: the album clicked.
    @objc(removeAlbum:)
    func removeAlbum(_ sender: Any!) {
        guard let row = horos_albumTable?.clickedRow, row != 0,
              let album = (albumArray() as NSArray?)?.object(at: row) as? DicomAlbum else { return }
        removeAlbumObject(album)
    }

    /// Deletes the album; asks first unless it is an empty album.
    @objc(removeAlbumObject:)
    func removeAlbumObject(_ album: DicomAlbum!) {
        let emptyAlbum = (album.smartAlbum?.boolValue ?? false) == false && (album.studies?.count ?? 0) == 0
        if !emptyAlbum {
            let message = String(format: NSLocalizedString("Are you sure you want to delete the album named %@?", comment: ""), album.name ?? "(null)")
            guard HorosAlertPanel.runInformational(title: NSLocalizedString("Delete Album", comment: ""), message: message,
                                                   defaultButton: NSLocalizedString("OK", comment: ""),
                                                   alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                   otherButton: nil) == HorosAlertPanel.defaultResponse else { return }
        }
        guard let context = self.database?.managedObjectContext else { return }
        N2ManagedObjectContextPerformAndWait(context) {
            if let exception = BrowserObjC.attempt({
                context.delete(album)
                forgetCachedAlbums()
                BrowserObjC.synchronized(horos_albumNoOfStudiesCache) {
                    horos_albumNoOfStudiesCache?.removeAllObjects()
                    horos_distantAlbumNoOfStudiesCache?.removeAllObjects()
                    horos_albumTable?.reloadData()
                }
                _ = self.database?.save(nil)
                refreshAlbums()
                outlineViewRefresh()
            }) {
                BrowserObjC.log(exception, "-[BrowserController removeAlbumObject:]")
            }
        }
    }

    /// Edits the selected album: the smart album sheet for a smart album, the
    /// name sheet for the others.
    @objc(albumTableDoublePressed:)
    func albumTableDoublePressed(_ sender: Any!) {
        guard let row = horos_albumTable?.selectedRow, row > 0, let database = self.database, database.isLocal(),
              let album = (albumArray() as NSArray?)?.object(at: row) as? DicomAlbum else { return }

        if (album.value(forKey: "smartAlbum") as? NSNumber)?.boolValue == true {
            guard let controller = SmartWindowController(database: database), let sheet = controller.window else { return }
            controller.name = album.name
            controller.predicate = NSPredicate(format: album.predicateString ?? "")
            controller.album = album
            let albumContext = Unmanaged.passRetained(album as AnyObject).toOpaque()
            self.window?.beginSheet(sheet) { returnCode in
                self.smartAlbumSheetDidEnd(sheet, returnCode: returnCode.rawValue, contextInfo: albumContext)
                _ = controller
            }
            return
        }

        horos_newAlbumName?.stringValue = album.value(forKey: "name") as? String ?? ""
        guard runAlbumNameSheet() else { return }
        let requested = horos_newAlbumName?.stringValue ?? ""
        guard BrowserObjC.literallyEqual(requested, album.value(forKey: "name") as? String) == false, let context = database.managedObjectContext else { return }

        N2ManagedObjectContextPerformAndWait(context) {
            if let exception = BrowserObjC.attempt({
                let name = AlbumNaming.uniqueName(for: requested, existing: (try? albumNames(in: context)) ?? [])
                album.setValue(name, forKey: "name")
                _ = database.save(nil)
                // An album that is not listed raised before the table was reloaded.
                let index = ((albumArray() as NSArray?) ?? []).index(of: album)
                guard index != NSNotFound else { return }
                horos_albumTable?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                horos_albumTable?.reloadData()
            }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController albumTableDoublePressed:]")
            }
        }
    }
}
