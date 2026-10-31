//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import IsiXPreferences
import Testing
@testable import IsiXDatabase

@Suite struct AlbumCatalogTests {

    private func album(_ id: Int, _ name: String?, smart: Bool = false) -> AlbumSummary<Int> {
        AlbumSummary(id: id, name: name, isSmart: smart, predicateString: smart ? "(modality == 'CT')" : nil)
    }

    @Test func albumsAreKeptForTheContextTheyWereFetchedIn() {
        let catalog = AlbumCatalog<Int>()
        let context = NSObject(), other = NSObject()
        #expect(catalog.albums(fetchedIn: ObjectIdentifier(context)) == nil)
        catalog.remember([album(1, "A"), album(2, "B")], fetchedIn: ObjectIdentifier(context))
        #expect(catalog.albums(fetchedIn: ObjectIdentifier(context))?.map(\.id) == [1, 2])
        #expect(catalog.albums(fetchedIn: ObjectIdentifier(other)) == nil)

        // Forgotten, they are fetched again.
        catalog.forgetAlbums()
        #expect(catalog.albums(fetchedIn: ObjectIdentifier(context)) == nil)
    }

    @Test func rowCountsAreUnknownUntilCountedAndProgressOnlyReplacesCountedRows() {
        let catalog = AlbumCatalog<Int>()
        #expect(catalog.count(atRow: 0) == .unknown)
        #expect(!catalog.hasCounts)

        catalog.setCounts([10, nil, 3])
        #expect(catalog.count(atRow: 0) == .counted(10))
        #expect(catalog.count(atRow: 1) == .failed)
        #expect(catalog.count(atRow: 3) == .unknown)
        #expect(catalog.count(atRow: -1) == .unknown)

        // A count that runs replaces the rows counted before, and no others.
        catalog.updateCounts([11, 2, 4, 5])
        #expect(catalog.count(atRow: 1) == .counted(2))
        #expect(catalog.count(atRow: 3) == .unknown)

        // The list of an unfiltered album is its count.
        #expect(catalog.setCount(7, atRow: 2))
        #expect(catalog.count(atRow: 2) == .counted(7))
        #expect(!catalog.setCount(7, atRow: 9))

        // An interrupted count leaves every row unknown.
        catalog.setCounts(nil)
        #expect(catalog.count(atRow: 0) == .unknown)
    }

    @Test func forgettingTheCountsForgetsTheDistantStudies() {
        let catalog = AlbumCatalog<Int>()
        catalog.setCounts([1])
        catalog.setDistantStudies([], of: "Today CT")
        #expect(catalog.distantStudies(of: "Today CT") != nil)
        catalog.forgetCounts()
        #expect(!catalog.hasCounts)
        #expect(catalog.distantStudies(of: "Today CT") == nil)

        #expect(catalog.distantStudiesAreStale(now: 121))
        catalog.markDistantRecount(at: 100)
        #expect(!catalog.distantStudiesAreStale(now: 200))
        #expect(catalog.distantStudiesAreStale(now: 221))
    }

    @Test func albumsSortByNameIgnoringCase() {
        let sorted = AlbumCatalog<Int>.sortedByName([album(1, "beta"), album(2, "Alpha"), album(3, "ALPHA"), album(4, "Gamma")])
        #expect(sorted.map(\.id) == [2, 3, 1, 4])
    }

    @Test func deletingAsksUnlessTheAlbumIsEmptyAndNotSmart() {
        #expect(!AlbumCatalog<Int>.asksBeforeDeleting(isSmart: false, studyCount: 0))
        #expect(AlbumCatalog<Int>.asksBeforeDeleting(isSmart: false, studyCount: 2))
        #expect(AlbumCatalog<Int>.asksBeforeDeleting(isSmart: true, studyCount: 0))
    }

    @Test func aRenamedAlbumKeepsAUniqueName() {
        #expect(AlbumCatalog<Int>.renamedName(requested: "Teaching", current: "Teaching", existing: ["Teaching"]) == nil)
        #expect(AlbumCatalog<Int>.renamedName(requested: "Follow-up", current: "Teaching", existing: ["Teaching", "Follow-up"]) == "Follow-up #2")
        #expect(AlbumCatalog<Int>.renamedName(requested: "New", current: nil, existing: []) == "New")
    }

    @Test func theDefaultAlbumsAndTheirFormerFilters() {
        let defaults = AlbumCatalog<Int>.defaultAlbums
        #expect(defaults.count == 19)
        #expect(defaults.filter { $0.predicate == nil }.map(\.name) == ["Interesting Cases"])
        #expect(Set(defaults.map(\.name)).count == defaults.count)

        #expect(AlbumCatalog<Int>.modifiedDefaultPredicate(
            "(ANY series.comment != '' AND ANY series.comment != NIL) OR (comment != '' AND comment != NIL)") == "(comment != '' AND comment != NIL)")
        #expect(AlbumCatalog<Int>.modifiedDefaultPredicate("(ANY series.modality CONTAINS[cd] 'CT')") == "(modality CONTAINS[cd] 'CT')")
        #expect(AlbumCatalog<Int>.modifiedDefaultPredicate("(modality CONTAINS[cd] 'CT')") == nil)
        #expect(AlbumCatalog<Int>.modifiedDefaultPredicate(nil) == nil)
    }

    @Test func aSmartAlbumRetrievesByItselfWhenItsEntrySaysSo() {
        let entries: [PropertyListValue] = [
            .dictionary(["name": .string("Today CT"), "autoretrieve": .boolean(true)]),
            .dictionary(["name": .string("Today MR"), "autoretrieve": .boolean(false)]),
            .string("not an entry"),
        ]
        #expect(AlbumCatalog<Int>.retrievesAutomatically(entries, album: "Today CT"))
        #expect(!AlbumCatalog<Int>.retrievesAutomatically(entries, album: "Today MR"))
        #expect(!AlbumCatalog<Int>.retrievesAutomatically(entries, album: "today ct"))
        #expect(!AlbumCatalog<Int>.retrievesAutomatically(entries, album: nil))
        #expect(!AlbumCatalog<Int>.retrievesAutomatically(nil, album: "Today CT"))
    }

    @Test func aSmartAlbumFilterTakesItsDatesWhenAsked() throws {
        var calendar = Calendar(identifier: .gregorian)
        let zone = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        calendar.timeZone = zone
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 15)))
        let start = calendar.startOfDay(for: now)

        #expect(AlbumCatalog<Int>.predicate(forSmartAlbumFilter: nil, now: now as NSDate, start: start as NSDate, timeZone: zone)
                == NSPredicate(value: true))
        #expect(AlbumCatalog<Int>.predicate(forSmartAlbumFilter: "", now: now as NSDate, start: start as NSDate, timeZone: zone)
                == NSPredicate(value: true))

        let variables = AlbumCatalog<Int>.predicate(forSmartAlbumFilter: "date >= $NSDATE_YESTERDAY AND date <= $NSDATE_TODAY",
                                                   now: now as NSDate, start: start as NSDate, timeZone: zone)
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: start))
        #expect(variables.evaluate(with: ["date": yesterday.addingTimeInterval(60)]))
        #expect(!variables.evaluate(with: ["date": yesterday.addingTimeInterval(-60)]))

        // The `$NAME` form becomes the seconds of its date, ignoring case.
        let seconds = AlbumCatalog<Int>.predicate(forSmartAlbumFilter: "dateAdded >= $lasthour", now: now as NSDate,
                                                 start: start as NSDate, timeZone: zone)
        #expect(seconds.evaluate(with: ["dateAdded": now.timeIntervalSinceReferenceDate - 60]))
        #expect(!seconds.evaluate(with: ["dateAdded": now.timeIntervalSinceReferenceDate - 3700]))
    }

    @Test func anEntryOfTheAlbumsFileKeepsItsKeys() {
        let date = Date(timeIntervalSinceReferenceDate: 1000)
        let album = AlbumsFileEntry(name: "Teaching", isSmart: false, predicateString: nil,
                                    studies: [AlbumsFileStudy(studyInstanceUID: "1.2", patientName: "A^B", date: date)])
        let plist = album.propertyList
        #expect(plist["name"] as? String == "Teaching")
        #expect(plist["smartAlbum"] == nil)
        let studies = plist["studies"] as? [[String: Any]]
        #expect(studies?.count == 1)
        #expect(studies?.first?["studyInstanceUID"] as? String == "1.2")
        #expect(studies?.first?["patientName"] as? String == "A^B")
        #expect(studies?.first?["date"] as? Date == date)
        #expect(studies?.first?["modality"] == nil)
        #expect(AlbumsFileEntry(propertyList: plist) == album)

        // A smart album keeps its filter and no studies; a nil name is left out.
        let smart = AlbumsFileEntry(name: nil, isSmart: true, predicateString: "(date >= $NSDATE_TODAY)", studies: [])
        #expect(smart.propertyList["name"] == nil)
        #expect(smart.propertyList["smartAlbum"] as? Bool == true)
        #expect(smart.propertyList["studies"] == nil)
        #expect(AlbumsFileEntry(propertyList: smart.propertyList) == smart)

        // The file goes through a property list as before.
        let data = try? PropertyListSerialization.data(fromPropertyList: [plist, smart.propertyList], format: .xml, options: 0)
        let read = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) }
        #expect(AlbumsFileEntry.entries(ofPropertyList: read) == [album, smart])
        #expect(AlbumsFileEntry.entries(ofPropertyList: "not an array") == nil)

        // "smartAlbum" may be a string.
        #expect(AlbumsFileEntry(propertyList: ["smartAlbum": "YES"])?.isSmart == true)
        #expect(AlbumsFileEntry(propertyList: ["smartAlbum": "0"])?.isSmart == false)
        #expect(AlbumsFileEntry(propertyList: "an album") == nil)
    }

    @Test func anEntryFindsItsAlbumOnceAndByWhatItHolds() {
        let entry = AlbumsFileEntry(name: "Teaching", isSmart: false, predicateString: nil,
                                    studies: [AlbumsFileStudy(studyInstanceUID: "1"), AlbumsFileStudy(studyInstanceUID: "2")])
        let other = AlbumsFileCandidate(name: "Other", isSmart: false, studyInstanceUIDs: [])
        let smart = AlbumsFileCandidate(name: "Teaching", isSmart: true, studyInstanceUIDs: [])
        let partial = AlbumsFileCandidate(name: "Teaching", isSmart: false, studyInstanceUIDs: ["1", "9"])
        let exact = AlbumsFileCandidate(name: "Teaching", isSmart: false, studyInstanceUIDs: ["1", "2"])

        #expect(AlbumCatalog<Int>.indexOfAlbum(for: entry, among: [other]) == nil)
        #expect(AlbumCatalog<Int>.indexOfAlbum(for: entry, among: [other, smart]) == 1)
        #expect(AlbumCatalog<Int>.indexOfAlbum(for: entry, among: [smart, partial, exact]) == 2)
        #expect(AlbumCatalog<Int>.indexOfAlbum(for: entry, among: [exact, partial]) == 0)

        // A nameless entry finds a nameless album.
        let nameless = AlbumsFileEntry(name: nil, isSmart: false, predicateString: nil, studies: [])
        #expect(AlbumCatalog<Int>.indexOfAlbum(for: nameless, among: [other, AlbumsFileCandidate(name: nil, isSmart: false, studyInstanceUIDs: [])]) == 1)
        #expect(AlbumCatalog<Int>.indexOfAlbum(for: nameless, among: [other]) == nil)
    }
}
