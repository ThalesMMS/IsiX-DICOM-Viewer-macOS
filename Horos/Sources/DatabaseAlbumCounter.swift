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
import IsiXPreferences

/// Counts the studies of the database the browser shows and of its albums,
/// the adapter of IsiXDatabase's AlbumStudyCounting: on a thread the Activity
/// window lists ("Compute Albums..."), with its Cancel button, in a
/// private-queue context of the database, inside its block. A smart album
/// that asks the nodes counts the studies they found too, which the local
/// database lacks, and retrieves them when its entry says so.
///
/// Made for each count, with the database shown when it was asked: a count
/// whose database is no longer shown stops and answers nil. It keeps the
/// browser itself, never a weak or unowned reference, to compare databases.
final class DatabaseAlbumCounter: AlbumStudyCounting, @unchecked Sendable {
    private let database: DicomDatabase
    private let browser: BrowserController
    private let catalog: DatabaseAlbumCatalog
    private let preferences: any PreferenceStore
    private let search: PACSOnDemandSearch<QueryControllerDistantStudies>
    private let retrieves: DistantStudyRetrieves

    init(database: DicomDatabase, browser: BrowserController, catalog: DatabaseAlbumCatalog, preferences: any PreferenceStore,
         search: PACSOnDemandSearch<QueryControllerDistantStudies>, retrieves: DistantStudyRetrieves) {
        self.database = database
        self.browser = browser
        self.catalog = catalog
        self.preferences = preferences
        self.search = search
        self.retrieves = retrieves
    }

    func countStudies(progress: @escaping @Sendable ([Int?]) -> Void) async -> [Int?]? {
        await ActivityThread.run(name: NSLocalizedString("Compute Albums...", comment: "")) {
            self.countNow(progress: progress)
        }
    }

    /// Whether the browser still shows the database counted.
    private var isShown: Bool { browser.database === database }

    private func countNow(progress: @escaping @Sendable ([Int?]) -> Void) -> [Int?]? {
        guard let idatabase = database.privateQueueIndependentDatabase() as? DicomDatabase else { return nil }
        var counts: [Int?]?
        // Counted on a private-queue context, on its queue.
        idatabase.performBlockAndWait {
            var counted: [Int?] = []
            if let raised = HorosObjCException.caught({
                // The albums as the table lists them, read now: those of a
                // request made before an album was added or removed would give
                // its row's count to another.
                let albums = CoreDataAlbumStore(database: idatabase).fetchAlbums().map(\.objectID)
                counts = self.count(albums, in: idatabase, into: &counted, progress: progress)
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController _computeNumberOfStudiesForAlbumsThread]")
                counts = counted
            }
        }
        return counts
    }

    /// The counts of the database and of each album; `counted` holds them as
    /// they come, so that an exception leaves what was counted.
    private func count(_ albumObjectIDs: [NSManagedObjectID], in idatabase: DicomDatabase, into counted: inout [Int?],
                       progress: @Sendable ([Int?]) -> Void) -> [Int?]? {
        // compute number of studies in database
        var count = -1
        if let raised = HorosObjCException.caught({ count = Int(bitPattern: idatabase.countObjects(forEntity: idatabase.studyEntity())) }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController _computeNumberOfStudiesForAlbumsThread]")
        }
        counted.append(count >= 0 ? count : nil)

        // compute every album's studies count
        var lastTime = Date.timeIntervalSinceReferenceDate
        let recomputeDistantStudies = catalog.distantStudiesAreStale(now: Date.timeIntervalSinceReferenceDate)

        for objectID in albumObjectIDs {
            if !isShown { return nil } // We switched the main database...

            // An album deleted while this thread runs leaves a fault that
            // throws on the first access; existingObjectWithID: answers nil
            // instead, and the count simply skips it.
            guard let ialbum = (try? idatabase.managedObjectContext.existingObject(with: objectID)) as? DicomAlbum,
                  !ialbum.isDeleted else { continue }

            Thread.current.status = ialbum.name

            count = -1
            if ialbum.smartAlbum?.boolValue == true {
                if let raised = HorosObjCException.caught({
                    self.countSmartAlbum(ialbum, in: idatabase, recomputeDistantStudies: recomputeDistantStudies, count: &count)
                }) {
                    BrowserObjC.log(raised, stack: true, "-[BrowserController _computeNumberOfStudiesForAlbumsThread]")
                }
            } else {
                count = ialbum.studies?.count ?? 0
            }
            counted.append(count >= 0 ? count : nil)

            if Date.timeIntervalSinceReferenceDate - lastTime >= 1 {
                lastTime = Date.timeIntervalSinceReferenceDate
                progress(counted)
            }

            if Thread.current.isCancelled { break }
        }

        return isShown ? counted : nil // Did we switch the main database...
    }

    /// The studies of a smart album: the local ones, and the distant ones the
    /// local database lacks when the smart albums ask the nodes, retrieved
    /// when the album retrieves automatically. `count` is counted as it
    /// goes, so that an exception leaves it where it got to.
    private func countSmartAlbum(_ ialbum: DicomAlbum, in idatabase: DicomDatabase, recomputeDistantStudies: Bool, count: inout Int) {
        let found = idatabase.objects(forEntity: idatabase.studyEntity(), predicate: CoreDataAlbumStore.filterPredicate(of: ialbum)) ?? []
        let localStudies = found.map { ($0 as? DicomStudy)?.studyInstanceUID }
        count = 0

        if preferences[NetworkPreferences.searchesSmartAlbumStudiesOnDICOMNodes] {
            var autoretrieve = false
            if !retrieves.isAutoretrieving {
                autoretrieve = DatabaseAlbumCatalog.retrievesAutomatically(preferences[WebPortalPreferences.smartAlbumStudiesDICOMNodes],
                                                                           album: ialbum.name)
            }

            // Merge local and distant studies
            let albumName = ialbum.name
            var distantStudies = albumName.flatMap { catalog.distantStudies(of: $0) }

            if recomputeDistantStudies || distantStudies == nil {
                distantStudies = self.distantStudies(forSmartAlbum: albumName)
                if let found = distantStudies, let albumName, isShown { // Did we switch the main database...
                    catalog.setDistantStudies(found, of: albumName)
                }
                catalog.markDistantRecount(at: Date.timeIntervalSinceReferenceDate)
            }

            var studyToAutoretrieve: [DistantStudySummary] = []
            for distantStudy in distantStudies ?? [] {
                if !(distantStudy.studyInstanceUID.map { localStudies.contains($0) } ?? false) {
                    count += 1
                    if autoretrieve { studyToAutoretrieve.append(distantStudy) }
                }
            }

            if !retrieves.isAutoretrieving && !studyToAutoretrieve.isEmpty {
                retrieves.startAutoretrieve(QueryControllerDistantStudies.nodes(of: studyToAutoretrieve),
                                            name: NSLocalizedString("Auto-Retrieving Album...", comment: ""))
            }
        }

        count += localStudies.count
    }

    /// The studies the nodes find for a smart album, with the filters of its
    /// "smartAlbumStudiesDICOMNodes" entry, asked on the calling thread; none
    /// on a read-only or remote database or when the smart albums do not ask
    /// the nodes, nil without an activated entry.
    private func distantStudies(forSmartAlbum albumName: String?) -> [DistantStudySummary]? {
        guard !database.isReadOnly, database.isLocal(),
              preferences[NetworkPreferences.searchesComparativeStudiesOnDICOMNodes],
              preferences[NetworkPreferences.searchesSmartAlbumStudiesOnDICOMNodes] else { return [] }
        guard let filters = search.smartAlbumFilters(albumName) else { return nil }
        return search.nodes.studiesNow(matching: filters)
    }
}
