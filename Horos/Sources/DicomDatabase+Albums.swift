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

// The "Albums" methods of DicomDatabase are implemented in Swift: a
// Swift extension of DicomDatabase, which stays Objective-C, with the
// selectors of the former methods. DicomDatabase.h imports
// DicomDatabase+Albums.h, so that plugins still see them.
//
// The smart album predicates are built as before: the same substitutions, in
// the same order, from the NSCalendarDate the former code took (which Swift
// cannot name, so DicomDatabase (SwiftIvars) gives it), and the same
// substitution variables, NSCalendarDate and NSDate objects. The albums file is
// written with the same keys and values. -newObjectForEntity: answers an
// autoreleased object although its name puts it in the "new" family, whose
// result Swift would release: it is sent by selector.

/// `[object boolValue]` of an NSNumber or an NSString, NO for nil.
private func boolValue(_ object: Any?) -> Bool {
    if let number = object as? NSNumber { return number.boolValue }
    if let string = object as? NSString { return string.boolValue }
    return false
}

/// `[[array valueForKey:@"name"] indexOfObject:object]`. A nil name finds an
/// album without one, whose name the array of names holds as NSNull.
private func indexOfName(_ object: Any?, in array: NSArray?) -> Int {
    guard let names = array?.value(forKey: "name") as? NSArray else { return NSNotFound }
    return names.index(of: object ?? NSNull())
}

/// The index in `array` of the album that an entry of the albums file stands
/// for, or NSNotFound when it is to be created. The entry is looked up by
/// name, and a nil name finds an album without one, which the array of names
/// holds as NSNull: a missing name never matched, and an album saved without
/// one was created again on every import.
///
/// Several albums of the entry's name (a file with two entries of the same
/// name, or two without one, creates two albums) are told apart by what the
/// entry holds: an album of the same kind, smart or not, first, then the one
/// holding more of the entry's studies, then the one with fewer others, then
/// the first. -loadAlbumsFromPath: takes each album it finds out of the array,
/// so that the next entry of the same name finds the next album and a repeated
/// import leaves the same albums with the same studies.
private func indexOfAlbum(forEntry entry: Any?, in array: NSArray?) -> Int {
    guard let array, let names = array.value(forKey: "name") as? NSArray else { return NSNotFound }
    let dict = entry as? NSDictionary
    let name: Any = dict?["name"] ?? NSNull()
    let candidates = (0..<names.count).filter { (names.object(at: $0) as AnyObject).isEqual(name) }
    guard candidates.count > 1 else { return candidates.first ?? NSNotFound }

    func isSmart(_ object: Any?) -> Bool {
        if let number = object as? NSNumber { return number.boolValue }
        if let string = object as? NSString { return string.boolValue }
        return false
    }
    let smart = isSmart(dict?["smartAlbum"])
    let uids = Set(((dict?["studies"] as? NSArray) ?? []).compactMap { ($0 as? NSDictionary)?["studyInstanceUID"] as? NSObject })

    var best = NSNotFound
    var bestScore = (0, 0, 0)
    for index in candidates {
        let album = array.object(at: index) as AnyObject
        let held = Set((((album.value(forKey: "studies") as? NSSet)?.value(forKey: "studyInstanceUID") as? NSSet) ?? NSSet())
                        .compactMap { $0 as? NSObject }.filter { !($0 is NSNull) })
        let shared = held.intersection(uids).count
        let score = (isSmart(album.value(forKey: "smartAlbum")) == smart ? 1 : 0, shared, -(held.count - shared))
        if best == NSNotFound || score > bestScore {
            best = index
            bestScore = score
        }
    }
    return best
}

/// `-[NSString caseInsensitiveCompare:]` sent as the Objective-C sent it: to
/// nil it is NSOrderedSame, and against nil it is NSOrderedDescending.
private func caseInsensitiveCompare(_ string: NSString?, _ other: NSString?) -> ComparisonResult {
    guard let string else { return .orderedSame }
    guard let other else { return .orderedDescending }
    return string.caseInsensitiveCompare(other as String)
}

/// The entry of `album` in the albums file. A nil name or predicate is
/// left out instead of raising: -loadAlbumsFromPath: reads a missing key
/// as nil, as it always did. The other keys and values are the
/// ones the file always had. It reads nothing of the database, so that the
/// albums of an index the database has not opened are written the same way.
private func albumsFileEntry(_ album: NSManagedObject) -> NSMutableDictionary {
    let entry = NSMutableDictionary()
    if let name = album.value(forKey: "name") {
        entry.setObject(name, forKey: "name" as NSString)
    }

    if (album.value(forKey: "smartAlbum") as? NSNumber)?.boolValue ?? false {
        entry.setObject(NSNumber(value: true), forKey: "smartAlbum" as NSString)
        if let predicateString = album.value(forKey: "predicateString") {
            entry.setObject(predicateString, forKey: "predicateString" as NSString)
        }
    } else {
        let studies = NSMutableArray()
        for case let study as NSManagedObject in DicomDatabaseObjC.set(album, "studies") ?? NSSet() {
            let entry = NSMutableDictionary()
            for (key, attribute) in [("studyInstanceUID", "studyInstanceUID"), ("patientName", "name"), ("patientID", "patientID"),
                                     ("patientUID", "patientUID"), ("dateOfBirth", "dateOfBirth"), ("name", "studyName"),
                                     ("date", "date"), ("modality", "modality"), ("accessionNumber", "accessionNumber")] {
                // A study of a former model may not have them all.
                guard study.entity.propertiesByName[attribute] != nil else { continue }
                if let value = study.value(forKey: attribute) {
                    entry.setObject(value, forKey: key as NSString)
                }
            }
            studies.add(entry)
        }

        entry.setObject(studies, forKey: "studies" as NSString)
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
    let albums: NSMutableArray? = context.performAndWait {
        var result: NSMutableArray? = nil
        let raised = DicomDatabaseObjC.attempt {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Album")
            guard let fetched = try? context.fetch(request) else { return }
            let entries = NSMutableArray()
            for case let album as NSManagedObject in fetched {
                if let exception = DicomDatabaseObjC.attempt({ entries.add(albumsFileEntry(album)) }) {
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
    return albums
}

public extension DicomDatabase {

    // MARK: - Albums

    /// `[self newObjectForEntity:entity]`.
    private func newObject(_ entity: NSEntityDescription?) -> NSManagedObject? {
        return self.perform(#selector(N2ManagedDatabase.newObject(forEntity:)), with: entity)?.takeUnretainedValue() as? NSManagedObject
    }

    @objc(loadAlbumsFromPath:)
    dynamic func loadAlbums(fromPath path: String!) {
        guard let path, let albums = NSArray(contentsOfFile: path) else { return }

        N2ManagedObjectContextPerformAndWait(self.managedObjectContext) {
        if let exception = DicomDatabaseObjC.attempt({
            let dbRequest = NSFetchRequest<NSFetchRequestResult>()
            dbRequest.entity = self.managedObjectModel.entitiesByName["Album"]
            dbRequest.predicate = NSPredicate(value: true)
            let albumArray = NSMutableArray(array: ((try? self.managedObjectContext?.fetch(dbRequest)) ?? nil) ?? [])

            for dict in albums {
                var a: NSManagedObject? = nil

                let index = indexOfAlbum(forEntry: dict, in: albumArray)
                if index == NSNotFound {
                    a = self.newObject(self.albumEntity())

                    a?.setValue(DicomDatabaseObjC.objectForKey(dict, "name"), forKey: "name")

                    if boolValue(DicomDatabaseObjC.objectForKey(dict, "smartAlbum")) {
                        a?.setValue(NSNumber(value: true), forKey: "smartAlbum")
                        a?.setValue((dict as AnyObject).value(forKey: "predicateString"), forKey: "predicateString")
                    }
                } else {
                    // Found once: the next entry of the same name finds another album.
                    a = albumArray.object(at: index) as? NSManagedObject
                    albumArray.removeObject(at: index)
                }

                if !((a?.value(forKey: "smartAlbum") as? NSNumber)?.boolValue ?? false) {
                    a?.setValue(NSNumber(value: false), forKey: "smartAlbum")
                    for case let entry as AnyObject in (DicomDatabaseObjC.objectForKey(dict, "studies") as? NSArray) ?? [] {
                        let studyInstanceUID = DicomDatabaseObjC.objectForKey(entry, "studyInstanceUID")
                        let predicate: NSPredicate
                        if let studyInstanceUID = studyInstanceUID as? NSObject {
                            predicate = NSPredicate(format: "studyInstanceUID = %@", studyInstanceUID)
                        } else {
                            predicate = NSPredicate(format: "studyInstanceUID = nil")
                        }
                        let qr = self.objects(forEntity: self.studyEntity(), predicate: predicate) as NSArray?
                        if let qr, qr.count != 0 {
                            a?.mutableSetValue(forKey: "studies").addObjects(from: qr as! [Any])
                        } else {
                            let s = self.newObject(self.studyEntity())
                            s?.setValue(DicomDatabaseObjC.objectForKey(entry, "studyInstanceUID"), forKey: "studyInstanceUID")
                            s?.setValue(DicomDatabaseObjC.objectForKey(entry, "patientName"), forKey: "name")
                            s?.setValue(DicomDatabaseObjC.objectForKey(entry, "patientID"), forKey: "patientID")
                            s?.setValue(DicomDatabaseObjC.objectForKey(entry, "patientUID"), forKey: "patientUID")
                            s?.setValue(DicomDatabaseObjC.objectForKey(entry, "dateOfBirth"), forKey: "dateOfBirth")
                            s?.setValue(DicomDatabaseObjC.objectForKey(entry, "name"), forKey: "studyName")
                            s?.setValue(DicomDatabaseObjC.objectForKey(entry, "date"), forKey: "date")
                            s?.setValue(DicomDatabaseObjC.objectForKey(entry, "modality"), forKey: "modality")
                            s?.setValue(DicomDatabaseObjC.objectForKey(entry, "accessionNumber"), forKey: "accessionNumber")
                            if let s { a?.mutableSetValue(forKey: "studies").add(s) }
                            let se = self.newObject(self.seriesEntity())
                            se?.setValue("OsiriX No Autodeletion", forKey: "name")
                            se?.setValue(NSNumber(value: Int32(5005)), forKey: "id")
                            if let se { s?.mutableSetValue(forKey: "series").add(se) }
                        }
                    }
                }
            }

            try? self.managedObjectContext?.save()
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase loadAlbumsFromPath:]")
        }
        }
    }

    @objc(saveAlbumsToPath:)
    dynamic func saveAlbums(toPath path: String!) {
        N2ManagedObjectContextPerformAndWait(self.managedObjectContext) {

        if let exception = DicomDatabaseObjC.attempt({
            try? self.managedObjectContext?.save()

            let albums = NSMutableArray()
            let dbRequest = NSFetchRequest<NSFetchRequestResult>()
            dbRequest.entity = self.managedObjectModel.entitiesByName["Album"]
            dbRequest.predicate = NSPredicate(value: true)
            let albumArray = ((try? self.managedObjectContext?.fetch(dbRequest)) ?? nil) as NSArray?

            if (albumArray?.count ?? 0) != 0, let albumArray {
                // The whole list is built first and written once, atomically:
                // the file used to be deleted and rewritten after every
                // album, and an album that raised left it with only the albums
                // before it. An album that raises is now left out, and the
                // others are saved.
                for case let album as NSManagedObject in albumArray {
                    if let exception = DicomDatabaseObjC.attempt({ albums.add(albumsFileEntry(album)) }) {
                        DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase saveAlbumsToPath:] album left out")
                    }
                }

                if albums.count == 0 {
                    NSLog("--- no albums to save")
                } else if let path, !albums.write(toFile: path, atomically: true) {
                    NSLog("--- albums could not be saved to %@", path as NSString)
                }
            } else {
                NSLog("--- no albums to save")
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase saveAlbumsToPath:]")
        }

        }
    }

    @objc(albums)
    dynamic func albums() -> [Any]! {
        var albums = self.objects(forEntity: self.albumEntity()) as NSArray?
        if let exception = DicomDatabaseObjC.attempt({
            albums = albums?.sortedArray(comparator: { a, b in
                var result = ComparisonResult.orderedSame
                _ = DicomDatabaseObjC.attempt {
                    result = caseInsensitiveCompare((a as AnyObject).value(forKey: "name") as? NSString, (b as AnyObject).value(forKey: "name") as? NSString)
                }
                return result
            }) as NSArray?
        }) {
            DicomDatabaseObjC.log(exception, stack: false, "-[DicomDatabase albums]")
        }

        return albums as? [Any]
    }

    @objc(predicateForSmartAlbumFilter:)
    dynamic class func predicate(forSmartAlbumFilter string: String!) -> NSPredicate! {
        if ((string as NSString?)?.length ?? 0) == 0 {
            return NSPredicate(value: true)
        }

        let pred = NSMutableString(string: string)

        // DATES
        let now = DicomDatabaseSmartAlbumNow() as! NSDate
        let start = DicomDatabaseSmartAlbumStartOfToday(now) as! NSDate

        // A previous calendar day keeps midnight across daylight-saving changes.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = NSTimeZone.default
        func previousDay(_ days: Int) -> NSDate {
            calendar.date(byAdding: .day, value: -days, to: start as Date)! as NSDate
        }

        func seconds(_ date: NSDate) -> NSString {
            return NSString(format: "%lf", date.timeIntervalSinceReferenceDate)
        }

        let sub = NSDictionary(objects: [seconds(now.addingTimeInterval(-60*60*1)),
                                         seconds(now.addingTimeInterval(-60*60*6)),
                                         seconds(now.addingTimeInterval(-60*60*12)),
                                         seconds(start),
                                         seconds(previousDay(1)),
                                         seconds(previousDay(2)),
                                         seconds(previousDay(7)),
                                         seconds(start.addingTimeInterval(-60*60*24*31)),
                                         seconds(start.addingTimeInterval(-60*60*24*31*2)),
                                         seconds(start.addingTimeInterval(-60*60*24*31*3)),
                                         seconds(start.addingTimeInterval(-60*60*24*365))],
                               forKeys: ["$LASTHOUR", "$LAST6HOURS", "$LAST12HOURS", "$TODAY", "$YESTERDAY", "$2DAYS",
                                         "$WEEK", "$MONTH", "$2MONTHS", "$3MONTHS", "$YEAR"] as [NSString])

        let enumerator = sub.keyEnumerator()
        while let key = enumerator.nextObject() as? String {
            pred.replaceOccurrences(of: key, with: sub.value(forKey: key) as! String, options: .caseInsensitive, range: NSRange(location: 0, length: pred.length))
        }

        // -predicateWithFormat: raises on a filter it cannot parse; the
        // exception goes on to the caller, as before.
        var parsed: NSPredicate? = nil
        if let exception = DicomDatabaseObjC.attempt({ parsed = NSPredicate(format: pred as String, argumentArray: nil) }) {
            exception.raise()
        }
        let variables: [String: Any] = ["NSDATE_LASTHOUR": now.addingTimeInterval(-60*60*1),
                                        "NSDATE_LAST6HOURS": now.addingTimeInterval(-60*60*6),
                                        "NSDATE_LAST12HOURS": now.addingTimeInterval(-60*60*12),
                                        "NSDATE_TODAY": start,
                                        "NSDATE_YESTERDAY": previousDay(1),
                                        "NSDATE_2DAYS": previousDay(2),
                                        "NSDATE_WEEK": previousDay(7),
                                        "NSDATE_MONTH": start.addingTimeInterval(-60*60*24*31),
                                        "NSDATE_2MONTHS": start.addingTimeInterval(-60*60*24*31*2),
                                        "NSDATE_3MONTHS": start.addingTimeInterval(-60*60*24*31*3),
                                        "NSDATE_YEAR": start.addingTimeInterval(-60*60*24*365)]
        var predicate: NSPredicate? = nil
        if let exception = DicomDatabaseObjC.attempt({ predicate = parsed?.withSubstitutionVariables(variables) }) {
            exception.raise()
        }
        if predicate == nil {
            predicate = NSPredicate(value: true)
        }

        return predicate
    }

    @objc(addDefaultAlbums)
    dynamic func addDefaultAlbums() {
        let descriptors: [(Any, String)] = [
            ("(dateAdded >= $NSDATE_LASTHOUR)", NSLocalizedString("Just Added (last hour)", comment: "")),
            ("(date >= $NSDATE_LASTHOUR)", NSLocalizedString("Just Acquired (last hour)", comment: "")),
            ("(dateOpened >= $NSDATE_LAST6HOURS)", NSLocalizedString("Just Opened", comment: "")),

            ("(modality CONTAINS[cd] 'MR') AND (date >= $NSDATE_TODAY)", NSLocalizedString("Today MR", comment: "")),
            ("(modality CONTAINS[cd] 'CT') AND (date >= $NSDATE_TODAY)", NSLocalizedString("Today CT", comment: "")),
            ("(modality CONTAINS[cd] 'US') AND (date >= $NSDATE_TODAY)", NSLocalizedString("Today US", comment: "")),
            ("(modality CONTAINS[cd] 'MG') AND (date >= $NSDATE_TODAY)", NSLocalizedString("Today MG", comment: "")),
            ("(modality CONTAINS[cd] 'CR') AND (date >= $NSDATE_TODAY)", NSLocalizedString("Today CR", comment: "")),
            ("(modality CONTAINS[cd] 'XA') AND (date >= $NSDATE_TODAY)", NSLocalizedString("Today XA", comment: "")),
            ("(modality CONTAINS[cd] 'RF') AND (date >= $NSDATE_TODAY)", NSLocalizedString("Today RF", comment: "")),

            ("(modality CONTAINS[cd] 'MR') AND (date >= $NSDATE_YESTERDAY AND date <= $NSDATE_TODAY)", NSLocalizedString("Yesterday MR", comment: "")),
            ("(modality CONTAINS[cd] 'CT') AND (date >= $NSDATE_YESTERDAY AND date <= $NSDATE_TODAY)", NSLocalizedString("Yesterday CT", comment: "")),
            ("(modality CONTAINS[cd] 'US') AND (date >= $NSDATE_YESTERDAY AND date <= $NSDATE_TODAY)", NSLocalizedString("Yesterday US", comment: "")),
            ("(modality CONTAINS[cd] 'MG') AND (date >= $NSDATE_YESTERDAY AND date <= $NSDATE_TODAY)", NSLocalizedString("Yesterday MG", comment: "")),
            ("(modality CONTAINS[cd] 'CR') AND (date >= $NSDATE_YESTERDAY AND date <= $NSDATE_TODAY)", NSLocalizedString("Yesterday CR", comment: "")),
            ("(modality CONTAINS[cd] 'XA') AND (date >= $NSDATE_YESTERDAY AND date <= $NSDATE_TODAY)", NSLocalizedString("Yesterday XA", comment: "")),
            ("(modality CONTAINS[cd] 'RF') AND (date >= $NSDATE_YESTERDAY AND date <= $NSDATE_TODAY)", NSLocalizedString("Yesterday RF", comment: "")),

            (NSNull(), NSLocalizedString("Interesting Cases", comment: "")),

            ("(comment != '' AND comment != NIL)", NSLocalizedString("Cases with comments", comment: "")),
        ]
        let albumDescriptors = NSDictionary(objects: descriptors.map { $0.0 }, forKeys: descriptors.map { $0.1 as NSString })

        let albums = self.albums() as NSArray?

        for case let localizedName as String in albumDescriptors.keyEnumerator() {
            if indexOfName(localizedName, in: albums) == NSNotFound {
                let album = self.newObject(self.albumEntity())
                album?.setValue(localizedName, forKey: "name")
                let predicate = albumDescriptors.object(forKey: localizedName)

                if let predicate = predicate as? NSString {
                    album?.setValue(predicate, forKey: "predicateString")
                    album?.setValue(NSNumber(value: true), forKey: "smartAlbum")
                }
            }
        }

        _ = self.save(nil)
    }

    @objc(modifyDefaultAlbums)
    dynamic func modifyDefaultAlbums() {
        if let exception = DicomDatabaseObjC.attempt({
            for case let album as NSManagedObject in (self.albums() as NSArray?) ?? [] {
                if DicomDatabaseObjC.isEqual(album.value(forKey: "predicateString") as? String, "(ANY series.comment != '' AND ANY series.comment != NIL) OR (comment != '' AND comment != NIL)") {
                    album.setValue("(comment != '' AND comment != NIL)", forKey: "predicateString")
                }

                if let previousString = album.value(forKey: "predicateString") as? NSString, previousString.range(of: "ANY series.modality").location != NSNotFound {
                    album.setValue(previousString.replacingOccurrences(of: "ANY series.modality", with: "modality"), forKey: "predicateString")
                }
            }
        }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase modifyDefaultAlbums]")
        }
    }

    @objc(addStudies:toAlbum:)
    dynamic func addStudies(_ dicomStudies: [Any]!, to dicomAlbum: DicomAlbum!) {
        for study in dicomStudies ?? [] {
            _ = dicomAlbum?.perform(#selector(DicomAlbum.addStudiesObject(_:)), with: study)
        }
    }
}
