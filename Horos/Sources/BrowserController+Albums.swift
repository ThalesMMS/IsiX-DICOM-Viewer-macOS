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
import IsiXPreferences

// The albums of the browser, with the selectors of the former Objective-C
// methods, which the nib, the menus, the tools and the plugins send. Each one
// forwards: the albums and their rules are IsiXDatabase's AlbumCatalog, stored
// by CoreDataAlbumStore, and the albums table is StudyListContent's.

extension BrowserController {

    // MARK: The albums of the database

    /// The database's albums, fetched once per context and then taken from
    /// the catalog, which the album changes and a change of database make
    /// forget them. Asked on any thread.
    @discardableResult
    @objc(albumsInDatabase)
    nonisolated func albumsInDatabase() -> [Any]! {
        guard let database = self.database else { return [] }
        return CoreDataAlbumStore(database: database).albums(cachedIn: albumState.catalog)
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
        studyList.albumRows()
    }

    /// Forgets the albums fetched, so that the next request fetches them.
    nonisolated func forgetCachedAlbums() {
        albumState.catalog.forgetAlbums()
    }

    /// The album selected in the table, found by name in `d`: the browser's
    /// database on the main thread, a private-queue one of it elsewhere when
    /// `d` is nil. Asked on any thread.
    @discardableResult
    @objc(currentAlbumID:)
    nonisolated func currentAlbumID(_ d: DicomDatabase!) -> NSManagedObjectID! {
        StudyListContent.currentAlbumID(of: self, in: d)
    }

    @objc(defaultAlbums:)
    func defaultAlbums(_ sender: Any!) {
        studyList.addDefaultAlbums()
    }

    /// The search and the time interval kept, whatever the Database settings
    /// say of an album selected, while -selectNoAlbums: selects "Database":
    /// the change of selection asks this, and the setting is not written.
    nonisolated static let searchKeptForDatabase = ForcedPreference(DatabasePreferences.clearsSearchWhenSelectingAlbum, to: false)

    @objc(selectNoAlbums:)
    func selectNoAlbums(_ sender: Any!) {
        BrowserController.searchKeptForDatabase.whileWorking {
            horos_albumTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc(selectAlbumWithName:)
    func selectAlbum(withName name: String!) {
        studyList.selectAlbum(named: name)
    }

    // MARK: Smart albums

    /// The predicate of a smart album's stored format, with its dates taken
    /// at the moment it is asked. An empty format keeps every study; a format
    /// that cannot be read raises, as it always did.
    @discardableResult
    @objc(smartAlbumPredicateString:)
    nonisolated func smartAlbumPredicateString(_ string: String!) -> NSPredicate! {
        CoreDataAlbumStore.filterPredicate(string)
    }

    /// The album's predicate, or one that keeps nothing when its format
    /// cannot be read.
    @discardableResult
    @objc(smartAlbumPredicate:)
    nonisolated func smartAlbumPredicate(_ album: NSManagedObject!) -> NSPredicate! {
        CoreDataAlbumStore.filterPredicate(of: album as? DicomAlbum)
    }

    @objc(addSmartAlbum:)
    func addSmartAlbum(_ sender: Any!) {
        studyList.addSmartAlbum()
    }

    // MARK: Albums

    @objc(addAlbum:)
    func addAlbum(_ sender: Any!) {
        studyList.addAlbum()
    }

    @objc(deleteAlbum:)
    func deleteAlbum(_ sender: Any!) {
        guard let row = horos_albumTable?.selectedRow, row > 0, let album = studyList.album(atRow: row) else { return }
        studyList.remove(album)
    }

    /// The albums table's contextual menu: the album clicked.
    @objc(removeAlbum:)
    func removeAlbum(_ sender: Any!) {
        guard let row = horos_albumTable?.clickedRow, row != 0, let album = studyList.album(atRow: row) else { return }
        studyList.remove(album)
    }

    /// Deletes the album; asks first unless it is an empty album.
    @objc(removeAlbumObject:)
    func removeAlbumObject(_ album: DicomAlbum!) {
        guard let album else { return }
        studyList.remove(album)
    }

    /// Edits the selected album: the smart album sheet for a smart album, the
    /// name sheet for the others.
    @objc(albumTableDoublePressed:)
    func albumTableDoublePressed(_ sender: Any!) {
        studyList.editSelectedAlbum()
    }
}
