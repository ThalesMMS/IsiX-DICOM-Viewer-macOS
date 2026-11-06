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
import CoreData
import IsiXDatabase

/// The catalog of a database's albums, keyed by the object IDs of the albums.
typealias DatabaseAlbumCatalog = AlbumCatalog<NSManagedObjectID>

/// The albums of a database, stored as DicomAlbum objects in its context:
/// fetching them, creating, renaming and deleting them, the smart albums'
/// predicates, the default albums and the albums file. The rules are
/// IsiXDatabase's AlbumCatalog; this adapter reads and writes Core Data with
/// them. Everything runs in the database's context, inside its block where the
/// former code took it. DicomDatabase+Albums.swift and the browser's album
/// methods forward here.
struct CoreDataAlbumStore {
    let database: DicomDatabase

    // MARK: Fetching

    /// The value the catalog keeps of an album.
    static func summary(of album: DicomAlbum) -> AlbumSummary<NSManagedObjectID> {
        AlbumSummary(id: album.objectID, name: album.name, isSmart: album.smartAlbum?.boolValue ?? false,
                     predicateString: album.predicateString)
    }

    /// The database's albums, sorted by name ignoring case. An album that
    /// cannot be read leaves them unsorted, as before.
    func fetchAlbums() -> [DicomAlbum] {
        let albums = (database.objects(forEntity: database.albumEntity()) ?? []).compactMap { $0 as? DicomAlbum }
        var sorted = albums
        if let exception = HorosObjCException.caught({
            let order = DatabaseAlbumCatalog.sortedByName(albums.map(Self.summary))
            let byID = Dictionary(albums.map { ($0.objectID, $0) }, uniquingKeysWith: { first, _ in first })
            sorted = order.compactMap { byID[$0.id] }
        }) {
            DicomDatabaseObjC.log(exception, stack: false, "-[DicomDatabase albums]")
        }
        return sorted
    }

    /// The albums, fetched once per context and then taken from `catalog`,
    /// which an album change and a change of database make forget them. Asked
    /// on any thread.
    func albums(cachedIn catalog: DatabaseAlbumCatalog) -> [DicomAlbum] {
        guard let context = database.managedObjectContext else { return [] }
        let source = ObjectIdentifier(context)
        if let cached = catalog.albums(fetchedIn: source) {
            return cached.compactMap { database.object(withID: $0.id) as? DicomAlbum }
        }
        var albums: [DicomAlbum] = []
        if let exception = HorosObjCException.caught({
            albums = (database.albums() ?? []).compactMap { $0 as? DicomAlbum }
            catalog.remember(albums.map(Self.summary), fetchedIn: source)
        }) {
            BrowserObjC.log(exception, "-[BrowserController albumsInDatabase]")
        }
        return albums
    }

    /// The object ID of the album named `name`, read in the database's block.
    func albumID(named name: String) -> NSManagedObjectID? {
        var albumID: NSManagedObjectID?
        database.performBlockAndWait {
            let found = database.objects(forEntity: database.albumEntity(), predicate: NSPredicate(format: "name == %@", name))
            albumID = (found?.last as? NSManagedObject)?.objectID
        }
        return albumID
    }

    /// The names of the database's albums, as stored.
    private func albumNames(in context: NSManagedObjectContext) -> [String] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Album")
        request.predicate = NSPredicate(value: true)
        return ((try? context.fetch(request)) ?? []).compactMap { ($0 as? DicomAlbum)?.name }
    }

    // MARK: Changing the albums

    /// Adds an album under the name asked, numbered when another album has it.
    func addAlbum(named requested: String) {
        guard let context = database.managedObjectContext else { return }
        N2ManagedObjectContextPerformAndWait(context) {
            if let exception = HorosObjCException.caught({
                let name = AlbumNaming.uniqueName(for: requested, existing: albumNames(in: context))
                let album = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context) as? DicomAlbum
                album?.name = name
                _ = database.save()
            }) {
                NSLog("***** exception in %@: %@", "-[BrowserController addAlbum:]", exception)
                exception.printStackTrace()
            }
        }
    }

    /// Renames `album`, numbered when another album has the name. Answers
    /// whether it was renamed.
    func rename(_ album: DicomAlbum, to requested: String) -> Bool {
        guard let context = database.managedObjectContext else { return false }
        var renamed = false
        N2ManagedObjectContextPerformAndWait(context) {
            if let exception = HorosObjCException.caught({
                guard let name = DatabaseAlbumCatalog.renamedName(requested: requested, current: album.name,
                                                                  existing: albumNames(in: context)) else { return }
                album.name = name
                _ = database.save(nil)
                renamed = true
            }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController albumTableDoublePressed:]")
            }
        }
        return renamed
    }

    /// Deletes `album`; `forget` runs inside the database's block, before the save.
    func delete(_ album: DicomAlbum, forgetting forget: () -> Void) {
        guard let context = database.managedObjectContext else { return }
        N2ManagedObjectContextPerformAndWait(context) {
            if let exception = HorosObjCException.caught({
                context.delete(album)
                forget()
                _ = database.save(nil)
            }) {
                BrowserObjC.log(exception, "-[BrowserController removeAlbumObject:]")
            }
        }
    }

    /// Stores the smart album the editor ended with: `album`, or a new one.
    func saveSmartAlbum(_ album: DicomAlbum?, name: String?, predicateFormat: String?) -> DicomAlbum? {
        let stored = album ?? (NSEntityDescription.insertNewObject(forEntityName: "Album", into: database.managedObjectContext) as? DicomAlbum)
        stored?.name = name
        stored?.smartAlbum = NSNumber(value: true)
        stored?.predicateString = predicateFormat
        _ = database.save()
        return stored
    }

    /// Adds `studies` to `album`, one by one.
    func addStudies(_ studies: [Any], to album: DicomAlbum?) {
        for case let study as DicomStudy in studies {
            album?.addStudiesObject(study)
        }
    }

    /// Creates the default albums the database lacks.
    func addDefaultAlbums() {
        let names = Set(fetchAlbums().map { $0.name ?? "" })
        guard let context = database.managedObjectContext else { return }
        for (key, predicate) in DatabaseAlbumCatalog.defaultAlbums {
            let name = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
            guard !names.contains(name) else { continue }
            N2ManagedObjectContextPerformAndWait(context) {
                let album = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context) as? DicomAlbum
                album?.name = name
                if let predicate {
                    album?.predicateString = predicate
                    album?.smartAlbum = NSNumber(value: true)
                }
            }
        }
        _ = database.save(nil)
    }

    /// The filters of the default albums of a former version, as they are
    /// stored now.
    func modifyDefaultAlbums() {
        if let exception = HorosObjCException.caught({
            for album in fetchAlbums() {
                if let predicate = DatabaseAlbumCatalog.modifiedDefaultPredicate(album.predicateString) {
                    album.predicateString = predicate
                }
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase modifyDefaultAlbums]")
        }
    }

    // MARK: The filter of a smart album

    /// The predicate of a smart album's stored filter, with its dates taken
    /// at the moment it is asked (the database's form, whose date variables are
    /// NSCalendarDate objects). An empty filter keeps every study; one that
    /// cannot be read raises, as it always did.
    static func predicate(forSmartAlbumFilter string: String?) -> NSPredicate {
        guard let string, !string.isEmpty else { return NSPredicate(value: true) }
        // NSCalendarDate objects, which Swift cannot name: NSDate is their class here.
        let now = (DicomDatabaseSmartAlbumNow() as? NSDate) ?? NSDate()
        let start = (DicomDatabaseSmartAlbumStartOfToday(now) as? NSDate) ?? now
        var predicate: NSPredicate?
        if let exception = HorosObjCException.caught({
            predicate = DatabaseAlbumCatalog.predicate(forSmartAlbumFilter: string, now: now, start: start, timeZone: NSTimeZone.default)
        }) {
            exception.raise()
        }
        return predicate ?? NSPredicate(value: true)
    }

    /// The predicate of a smart album's stored format, the browser's form,
    /// with its dates taken at the moment it is asked. An empty format keeps
    /// every study; a format that cannot be read raises, as it always did.
    static func filterPredicate(_ string: String?) -> NSPredicate? {
        guard let string, !string.isEmpty else { return NSPredicate(value: true) }
        let variables = SmartAlbumDateVariables(now: Date(), timeZone: NSTimeZone.default)
        var predicate: NSPredicate?
        if let exception = HorosObjCException.caught({
            predicate = NSPredicate(format: variables.expandedFormat(string))
        }) {
            exception.raise()
        }
        return predicate?.withSubstitutionVariables(variables.substitutionVariables)
    }

    /// The album's predicate, or one that keeps nothing when its format
    /// cannot be read.
    static func filterPredicate(of album: DicomAlbum?) -> NSPredicate? {
        var predicate: NSPredicate?
        if let exception = HorosObjCException.caught({ predicate = filterPredicate(album?.predicateString) }) {
            predicate = NSPredicate(value: false)
            BrowserObjC.log(exception, stack: true, "-[BrowserController smartAlbumPredicate:]")
        }
        return predicate
    }

    // MARK: The albums file

    /// An album of the database, as an entry of the file is matched against it.
    private static func candidate(_ album: DicomAlbum) -> AlbumsFileCandidate {
        let uids = (album.studies ?? []).compactMap { ($0 as? DicomStudy)?.studyInstanceUID }
        return AlbumsFileCandidate(name: album.name, isSmart: album.smartAlbum?.boolValue ?? false, studyInstanceUIDs: Set(uids))
    }

    /// Restores the albums of the file at `path`: an entry finds the album it
    /// stands for or creates it, and a study the database does not have is
    /// created as a marker study, with a series of marker, which hold only
    /// what the file says of it.
    func importAlbumsFile(atPath path: String?) {
        guard let path, let data = FileManager.default.contents(atPath: path),
              let entries = AlbumsFileEntry.entries(ofPropertyList: try? PropertyListSerialization.propertyList(from: data, format: nil)),
              let context = database.managedObjectContext else { return }

        N2ManagedObjectContextPerformAndWait(context) {
            if let exception = HorosObjCException.caught({
                let request = NSFetchRequest<NSManagedObject>(entityName: "Album")
                request.predicate = NSPredicate(value: true)
                var remaining = ((try? context.fetch(request)) ?? []).compactMap { $0 as? DicomAlbum }

                for entry in entries {
                    let album: DicomAlbum?
                    if let index = DatabaseAlbumCatalog.indexOfAlbum(for: entry, among: remaining.map(Self.candidate)) {
                        // Found once: the next entry of the same name finds another album.
                        album = remaining.remove(at: index)
                    } else {
                        album = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context) as? DicomAlbum
                        album?.name = entry.name
                        if entry.isSmart {
                            album?.smartAlbum = NSNumber(value: true)
                            album?.predicateString = entry.predicateString
                        }
                    }
                    guard let album, !(album.smartAlbum?.boolValue ?? false) else { continue }
                    album.smartAlbum = NSNumber(value: false)
                    for study in entry.studies {
                        importStudy(study, into: album, in: context)
                    }
                }

                try? context.save()
            }) {
                DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase loadAlbumsFromPath:]")
            }
        }
    }

    /// Adds the study of the file to `album`: the database's studies of its
    /// instance UID, or a marker study when there are none.
    private func importStudy(_ study: AlbumsFileStudy, into album: DicomAlbum, in context: NSManagedObjectContext) {
        let predicate = study.studyInstanceUID.map { NSPredicate(format: "studyInstanceUID = %@", $0) }
            ?? NSPredicate(format: "studyInstanceUID = nil")
        let found = (database.objects(forEntity: database.studyEntity(), predicate: predicate) ?? []).compactMap { $0 as? DicomStudy }
        if !found.isEmpty {
            found.forEach { album.addStudiesObject($0) }
            return
        }
        guard let marker = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context) as? DicomStudy else { return }
        marker.studyInstanceUID = study.studyInstanceUID
        marker.name = study.patientName
        marker.patientID = study.patientID
        marker.patientUID = study.patientUID
        marker.dateOfBirth = study.dateOfBirth
        marker.studyName = study.name
        marker.date = study.date
        marker.modality = study.modality
        marker.accessionNumber = study.accessionNumber
        album.addStudiesObject(marker)
        if let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context) as? DicomSeries {
            series.name = SelectionImages.noAutodeletionName
            series.id = NSNumber(value: SelectionImages.noAutodeletionID)
            marker.addSeriesObject(series)
        }
    }

    /// Writes the albums to the file at `path`, whole and atomically. An
    /// album that cannot be read is left out, and the others are saved.
    func exportAlbumsFile(toPath path: String?) {
        guard let context = database.managedObjectContext else { return }
        N2ManagedObjectContextPerformAndWait(context) {
            if let exception = HorosObjCException.caught({
                try? context.save()

                let request = NSFetchRequest<NSManagedObject>(entityName: "Album")
                request.predicate = NSPredicate(value: true)
                let albums = (try? context.fetch(request)) ?? []
                var entries: [Any] = []
                for album in albums {
                    if let exception = HorosObjCException.caught({ entries.append(albumsFileEntry(album).propertyList) }) {
                        DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase saveAlbumsToPath:] album left out")
                    }
                }

                if entries.isEmpty {
                    NSLog("--- no albums to save")
                } else if let path, !Self.write(entries, toFile: path) {
                    NSLog("--- albums could not be saved to %@", path as NSString)
                }
            }) {
                DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase saveAlbumsToPath:]")
            }
        }
    }

    /// Writes the entries of the albums file as the XML property list it
    /// always was, atomically.
    static func write(_ entries: [Any], toFile path: String) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}
