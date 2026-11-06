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

// The "Albums" methods of DicomDatabase, with the selectors of the former
// methods: DicomDatabase.h imports DicomDatabase+Albums.h, so that plugins
// still see them. Each one forwards to CoreDataAlbumStore, the app's adapter
// of IsiXDatabase's AlbumCatalog; RemoteDicomDatabase overrides some of them.
//
// What stays here reads an album of any model: the entry of the albums file,
// which a rebuild also reads from an index the database has not opened.

/// The entry of `album` in the albums file. It reads the album and its
/// studies by key, as the albums of a former model have no class of their
/// own, and only the attributes their model has. It reads nothing of the
/// database, so that the albums of an index the database has not opened are
/// written the same way.
func albumsFileEntry(_ album: NSManagedObject) -> AlbumsFileEntry {
    let isSmart = (album.value(forKey: "smartAlbum") as? NSNumber)?.boolValue ?? false
    var entry = AlbumsFileEntry(name: album.value(forKey: "name") as? String, isSmart: isSmart,
                                predicateString: isSmart ? album.value(forKey: "predicateString") as? String : nil, studies: [])
    guard !isSmart else { return entry }
    for case let study as NSManagedObject in DicomDatabaseObjC.set(album, "studies") ?? NSSet() {
        // A study of a former model may not have them all.
        func read<Value>(_ attribute: String) -> Value? {
            study.entity.propertiesByName[attribute] != nil ? study.value(forKey: attribute) as? Value : nil
        }
        entry.studies.append(AlbumsFileStudy(studyInstanceUID: read("studyInstanceUID"), patientName: read("name"),
                                             patientID: read("patientID"), patientUID: read("patientUID"),
                                             dateOfBirth: read("dateOfBirth"), name: read("studyName"), date: read("date"),
                                             modality: read("modality"), accessionNumber: read("accessionNumber")))
    }
    return entry
}

/// The albums of the index at `path`, as -saveAlbumsToPath: writes them to the
/// albums file, or nil when they cannot be read: no file, not an index, or an
/// index of none of `models`.
///
/// -rebuild: saves the albums from the context of the database, and a rebuild
/// started while the database opens its index (an upgrade that failed) has
/// none yet: it read no album, and the rebuilt index had none, not even the
/// default ones. It reads them here from its verified copy of the
/// index instead. The copy is opened read-only, with the first of `models` its
/// store is of, and closed again; nothing is written beside it.
func albumsFileEntries(ofIndexAtPath path: String, models: [NSManagedObjectModel]) -> NSArray? {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path),
          let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url, options: nil),
          let model = models.first(where: { $0.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) }),
          model.entitiesByName["Album"] != nil else { return nil }

    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let options: [String: Any] = [NSReadOnlyPersistentStoreOption: true,
                                  NSSQLitePragmasOption: ["journal_mode": "delete"]]
    guard let store = try? coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: options) else { return nil }
    defer { try? coordinator.remove(store) }

    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    context.undoManager = nil

    // The value is returned from the context's queue rather than written to a
    // variable captured by its block.
    let albums: [Any]? = context.performAndWait {
        var result: [Any]? = nil
        let raised = HorosObjCException.caught {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Album")
            guard let fetched = try? context.fetch(request) else { return }
            var entries: [Any] = []
            for case let album as NSManagedObject in fetched {
                if let exception = HorosObjCException.caught({ entries.append(albumsFileEntry(album).propertyList) }) {
                    DicomDatabaseObjC.log(exception, stack: true, "albumsFileEntries(ofIndexAtPath:models:) album left out")
                }
            }
            result = entries
        }
        if let raised {
            DicomDatabaseObjC.log(raised, stack: true, "albumsFileEntries(ofIndexAtPath:models:)")
            result = nil
        }
        context.reset()
        return result
    }
    // The rebuild writes the file with the array's own writer.
    return albums.map { $0 as NSArray }
}

public extension DicomDatabase {

    // MARK: - Albums

    @objc(loadAlbumsFromPath:)
    dynamic func loadAlbums(fromPath path: String!) {
        CoreDataAlbumStore(database: self).importAlbumsFile(atPath: path)
    }

    @objc(saveAlbumsToPath:)
    dynamic func saveAlbums(toPath path: String!) {
        CoreDataAlbumStore(database: self).exportAlbumsFile(toPath: path)
    }

    @objc(albums)
    dynamic func albums() -> [Any]! {
        CoreDataAlbumStore(database: self).fetchAlbums()
    }

    @objc(predicateForSmartAlbumFilter:)
    dynamic class func predicate(forSmartAlbumFilter string: String!) -> NSPredicate! {
        CoreDataAlbumStore.predicate(forSmartAlbumFilter: string)
    }

    @objc(addDefaultAlbums)
    dynamic func addDefaultAlbums() {
        CoreDataAlbumStore(database: self).addDefaultAlbums()
    }

    @objc(modifyDefaultAlbums)
    dynamic func modifyDefaultAlbums() {
        CoreDataAlbumStore(database: self).modifyDefaultAlbums()
    }

    @objc(addStudies:toAlbum:)
    dynamic func addStudies(_ dicomStudies: [Any]!, to dicomAlbum: DicomAlbum!) {
        CoreDataAlbumStore(database: self).addStudies(dicomStudies ?? [], to: dicomAlbum)
    }
}
