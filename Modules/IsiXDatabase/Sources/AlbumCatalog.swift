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

import Foundation
import IsiXPreferences
import Synchronization

/// An album of a database, as the catalog keeps it: the identifier of its
/// stored object and what the albums table and the study list read of it.
public struct AlbumSummary<ID: Hashable & Sendable>: Sendable, Hashable {
    public let id: ID
    public let name: String?
    public let isSmart: Bool
    /// The stored format of a smart album's filter; nil for the others.
    public let predicateString: String?

    public init(id: ID, name: String?, isSmart: Bool, predicateString: String?) {
        self.id = id
        self.name = name
        self.isSmart = isSmart
        self.predicateString = predicateString
    }
}

/// The number of studies the albums table shows on a row.
public enum AlbumRowCount: Sendable, Equatable {
    /// Not counted yet: the row asks for a count and shows "#" meanwhile.
    case unknown
    /// The count failed: "#", without asking again.
    case failed
    case counted(Int)
}

/// The albums of the database the browser shows: the albums fetched last,
/// the number of studies of each row of the albums table (the database first,
/// then the albums), the studies the nodes found for each smart album, and the
/// rules that create, rename, delete and file the albums.
///
/// The browser reads the albums on any thread and a count runs on a thread of
/// its own, so the state is kept under a mutex: every read hands out a copy.
/// The rules read no Core Data: the app's adapter fetches and stores the
/// albums and hands their values here.
public final class AlbumCatalog<ID: Hashable & Sendable>: Sendable {

    private struct State {
        /// The albums fetched last, and the context they were fetched in
        /// (compared only); a nil context makes the next request fetch again.
        var albums: [AlbumSummary<ID>] = []
        var source: ObjectIdentifier?
        var counts: [Int?] = []
        var distantStudies: [String: [DistantStudySummary]] = [:]
        var lastDistantRecount: TimeInterval = 0
    }

    private let state = Mutex(State())

    public init() {}

    // MARK: The albums fetched last

    /// The albums fetched in `source`, when they are still those of `source`.
    public func albums(fetchedIn source: ObjectIdentifier) -> [AlbumSummary<ID>]? {
        state.withLock { $0.source == source ? $0.albums : nil }
    }

    /// Keeps the albums just fetched in `source`.
    public func remember(_ albums: [AlbumSummary<ID>], fetchedIn source: ObjectIdentifier) {
        state.withLock {
            $0.albums = albums
            $0.source = source
        }
    }

    /// Makes the next request fetch the albums again.
    public func forgetAlbums() {
        state.withLock { $0.source = nil }
    }

    // MARK: The counts of the albums table

    /// What the row at `row` shows: the database is row 0.
    public func count(atRow row: Int) -> AlbumRowCount {
        state.withLock { state in
            guard row >= 0, row < state.counts.count else { return .unknown }
            return state.counts[row].map { .counted($0) } ?? .failed
        }
    }

    /// Whether any row has been counted since the counts were forgotten.
    public var hasCounts: Bool {
        state.withLock { !$0.counts.isEmpty }
    }

    /// The counts of a finished count, which replace every row's; nil, a count
    /// interrupted because the database shown changed, leaves every row unknown.
    public func setCounts(_ counts: [Int?]?) {
        state.withLock { $0.counts = counts ?? [] }
    }

    /// The counts so far of a count that runs: they replace the rows that
    /// were counted before, and no others.
    public func updateCounts(_ counts: [Int?]) {
        state.withLock { state in
            let shared = min(state.counts.count, counts.count)
            state.counts.replaceSubrange(0..<shared, with: counts[0..<shared])
        }
    }

    /// The count of the list the album at `row` shows unfiltered, which is
    /// its number of studies. Answers whether the row was counted before.
    @discardableResult
    public func setCount(_ count: Int, atRow row: Int) -> Bool {
        state.withLock { state in
            guard row >= 0, row < state.counts.count else { return false }
            state.counts[row] = count
            return true
        }
    }

    /// Forgets the counts and the distant studies of the smart albums: another
    /// database is shown, or an album went.
    public func forgetCounts() {
        state.withLock {
            $0.counts = []
            $0.distantStudies = [:]
        }
    }

    // MARK: The studies the nodes found for the smart albums

    public func distantStudies(of album: String) -> [DistantStudySummary]? {
        state.withLock { $0.distantStudies[album] }
    }

    public func setDistantStudies(_ studies: [DistantStudySummary], of album: String) {
        state.withLock { $0.distantStudies[album] = studies }
    }

    /// Whether the nodes are asked again for the smart albums' studies: two
    /// minutes after they were last asked. Asking marks the time.
    public func distantStudiesAreStale(now: TimeInterval) -> Bool {
        state.withLock { now - $0.lastDistantRecount > Self.distantRecountInterval }
    }

    public func markDistantRecount(at now: TimeInterval) {
        state.withLock { $0.lastDistantRecount = now }
    }

    /// The time after which a count asks the nodes again.
    public static var distantRecountInterval: TimeInterval { 120 }

    // MARK: The rules of the albums

    /// The albums in the order of the albums table: by name, ignoring case,
    /// an album without a name first.
    public static func sortedByName(_ albums: [AlbumSummary<ID>]) -> [AlbumSummary<ID>] {
        albums.enumerated().sorted { a, b in
            switch compareNames(a.element.name, b.element.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// `-[NSString caseInsensitiveCompare:]` as the Objective-C sent it: to
    /// nil it is the same, and against nil it is descending.
    static func compareNames(_ name: String?, _ other: String?) -> ComparisonResult {
        guard let name else { return .orderedSame }
        guard let other else { return .orderedDescending }
        return name.caseInsensitiveCompare(other)
    }

    /// Whether deleting an album asks first: every album but an empty one
    /// that is not smart.
    public static func asksBeforeDeleting(isSmart: Bool, studyCount: Int) -> Bool {
        isSmart || studyCount > 0
    }

    /// The name a renamed album is saved under, or nil when the name did not
    /// change: the requested one, numbered when another album has it.
    public static func renamedName(requested: String, current: String?, existing: [String]) -> String? {
        if let current, Array(current.utf16) == Array(requested.utf16) { return nil }
        return AlbumNaming.uniqueName(for: requested, existing: existing)
    }

    /// The albums a new database is given: their names, which the app
    /// localizes, and the filters of the smart ones (nil for an album).
    public static var defaultAlbums: [(name: String, predicate: String?)] { [
        ("Just Added (last hour)", "(dateAdded >= $NSDATE_LASTHOUR)"),
        ("Just Acquired (last hour)", "(date >= $NSDATE_LASTHOUR)"),
        ("Just Opened", "(dateOpened >= $NSDATE_LAST6HOURS)"),

        ("Today MR", "(modality CONTAINS[cd] 'MR') AND (date >= $NSDATE_TODAY)"),
        ("Today CT", "(modality CONTAINS[cd] 'CT') AND (date >= $NSDATE_TODAY)"),
        ("Today US", "(modality CONTAINS[cd] 'US') AND (date >= $NSDATE_TODAY)"),
        ("Today MG", "(modality CONTAINS[cd] 'MG') AND (date >= $NSDATE_TODAY)"),
        ("Today CR", "(modality CONTAINS[cd] 'CR') AND (date >= $NSDATE_TODAY)"),
        ("Today XA", "(modality CONTAINS[cd] 'XA') AND (date >= $NSDATE_TODAY)"),
        ("Today RF", "(modality CONTAINS[cd] 'RF') AND (date >= $NSDATE_TODAY)"),

        ("Yesterday MR", "(modality CONTAINS[cd] 'MR') AND (date >= $NSDATE_YESTERDAY AND date <= $NSDATE_TODAY)"),
        ("Yesterday CT", "(modality CONTAINS[cd] 'CT') AND (date >= $NSDATE_YESTERDAY AND date <= $NSDATE_TODAY)"),
        ("Yesterday US", "(modality CONTAINS[cd] 'US') AND (date >= $NSDATE_YESTERDAY AND date <= $NSDATE_TODAY)"),
        ("Yesterday MG", "(modality CONTAINS[cd] 'MG') AND (date >= $NSDATE_YESTERDAY AND date <= $NSDATE_TODAY)"),
        ("Yesterday CR", "(modality CONTAINS[cd] 'CR') AND (date >= $NSDATE_YESTERDAY AND date <= $NSDATE_TODAY)"),
        ("Yesterday XA", "(modality CONTAINS[cd] 'XA') AND (date >= $NSDATE_YESTERDAY AND date <= $NSDATE_TODAY)"),
        ("Yesterday RF", "(modality CONTAINS[cd] 'RF') AND (date >= $NSDATE_YESTERDAY AND date <= $NSDATE_TODAY)"),

        ("Interesting Cases", nil),

        ("Cases with comments", "(comment != '' AND comment != NIL)"),
    ] }

    /// The filter of a default album of a former version, as it is stored
    /// now; nil when it needs no change.
    public static func modifiedDefaultPredicate(_ predicate: String?) -> String? {
        guard var predicate else { return nil }
        var changed = false
        if predicate == "(ANY series.comment != '' AND ANY series.comment != NIL) OR (comment != '' AND comment != NIL)" {
            predicate = "(comment != '' AND comment != NIL)"
            changed = true
        }
        if predicate.contains("ANY series.modality") {
            predicate = predicate.replacingOccurrences(of: "ANY series.modality", with: "modality")
            changed = true
        }
        return changed ? predicate : nil
    }

    /// Whether a smart album retrieves the studies the nodes find for it by
    /// itself: an entry of the "smartAlbumStudiesDICOMNodes" preference with
    /// its name, as it is stored, says "autoretrieve".
    public static func retrievesAutomatically(_ entries: [PropertyListValue]?, album: String?) -> Bool {
        (entries ?? []).contains { entry in
            guard case .dictionary(let entry) = entry, let album, let name = entry["name"]?.stringValue else { return false }
            return (entry["autoretrieve"]?.boolValue ?? false) && Array(album.utf16) == Array(name.utf16)
        }
    }

    // MARK: The filter of a smart album

    /// The predicate of a smart album's stored filter, with its dates taken
    /// from `now` and the start of today: each `$LASTHOUR`, `$TODAY` … of the
    /// format becomes the seconds since the reference date of its date, and
    /// each `$NSDATE_…` variable that date. The dates keep the class of
    /// `now` and `start`, which the app gives as NSCalendarDate. An empty
    /// filter keeps every study; one that cannot be read raises, as it always did.
    public static func predicate(forSmartAlbumFilter string: String?, now: NSDate, start: NSDate, timeZone: TimeZone) -> NSPredicate {
        guard let string, !string.isEmpty else { return NSPredicate(value: true) }

        // A previous calendar day keeps midnight across daylight-saving changes.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func previousDay(_ days: Int) -> NSDate {
            calendar.date(byAdding: .day, value: -days, to: start as Date)! as NSDate
        }

        let dates: [(name: String, date: NSDate)] = [
            ("LASTHOUR", now.addingTimeInterval(-60*60*1)),
            ("LAST6HOURS", now.addingTimeInterval(-60*60*6)),
            ("LAST12HOURS", now.addingTimeInterval(-60*60*12)),
            ("TODAY", start),
            ("YESTERDAY", previousDay(1)),
            ("2DAYS", previousDay(2)),
            ("WEEK", previousDay(7)),
            ("MONTH", start.addingTimeInterval(-60*60*24*31)),
            ("2MONTHS", start.addingTimeInterval(-60*60*24*31*2)),
            ("3MONTHS", start.addingTimeInterval(-60*60*24*31*3)),
            ("YEAR", start.addingTimeInterval(-60*60*24*365)),
        ]

        var format = string
        for (name, date) in dates {
            format = format.replacingOccurrences(of: "$" + name, with: String(format: "%lf", date.timeIntervalSinceReferenceDate),
                                                 options: .caseInsensitive)
        }
        let parsed = NSPredicate(format: format, argumentArray: nil)
        var variables: [String: Any] = [:]
        for (name, date) in dates {
            variables["NSDATE_" + name] = date
        }
        return parsed.withSubstitutionVariables(variables)
    }

    // MARK: The albums file

    /// The index in `candidates` of the album an entry of the albums file
    /// stands for, or nil when it is to be created. The entry is looked up by
    /// name, and a nil name finds an album without one.
    ///
    /// Several albums of the entry's name (a file with two entries of the same
    /// name, or two without one, creates two albums) are told apart by what the
    /// entry holds: an album of the same kind, smart or not, first, then the one
    /// holding more of the entry's studies, then the one with fewer others, then
    /// the first. The reader takes each album it finds out of the candidates, so
    /// that the next entry of the same name finds the next album and a repeated
    /// import leaves the same albums with the same studies.
    public static func indexOfAlbum(for entry: AlbumsFileEntry, among candidates: [AlbumsFileCandidate]) -> Int? {
        let named = candidates.indices.filter { candidates[$0].name == entry.name }
        guard named.count > 1 else { return named.first }

        let uids = Set(entry.studies.compactMap(\.studyInstanceUID))
        var best: Int?
        var bestScore = (0, 0, 0)
        for index in named {
            let held = candidates[index].studyInstanceUIDs
            let shared = held.intersection(uids).count
            let score = (candidates[index].isSmart == entry.isSmart ? 1 : 0, shared, -(held.count - shared))
            if best == nil || score > bestScore {
                best = index
                bestScore = score
            }
        }
        return best
    }
}

/// An album of the database, as an entry of the albums file is matched
/// against it.
public struct AlbumsFileCandidate: Sendable, Equatable {
    public let name: String?
    public let isSmart: Bool
    public let studyInstanceUIDs: Set<String>

    public init(name: String?, isSmart: Bool, studyInstanceUIDs: Set<String>) {
        self.name = name
        self.isSmart = isSmart
        self.studyInstanceUIDs = studyInstanceUIDs
    }
}

/// A study of an album in the albums file: what is needed to find it again
/// or to stand for it when the database does not have it.
public struct AlbumsFileStudy: Sendable, Equatable {
    public var studyInstanceUID: String?
    public var patientName: String?
    public var patientID: String?
    public var patientUID: String?
    public var dateOfBirth: Date?
    public var name: String?
    public var date: Date?
    public var modality: String?
    public var accessionNumber: String?

    public init(studyInstanceUID: String? = nil, patientName: String? = nil, patientID: String? = nil, patientUID: String? = nil,
                dateOfBirth: Date? = nil, name: String? = nil, date: Date? = nil, modality: String? = nil,
                accessionNumber: String? = nil) {
        self.studyInstanceUID = studyInstanceUID
        self.patientName = patientName
        self.patientID = patientID
        self.patientUID = patientUID
        self.dateOfBirth = dateOfBirth
        self.name = name
        self.date = date
        self.modality = modality
        self.accessionNumber = accessionNumber
    }
}

/// An album in the albums file, which a rebuild restores the albums from and
/// "Save Albums" exports: a property list array of dictionaries whose keys
/// and values older versions read too.
public struct AlbumsFileEntry: Sendable, Equatable {
    public var name: String?
    public var isSmart: Bool
    /// A smart album's filter; nil for the others and when it has none.
    public var predicateString: String?
    /// The studies of an album that is not smart.
    public var studies: [AlbumsFileStudy]

    public init(name: String?, isSmart: Bool, predicateString: String?, studies: [AlbumsFileStudy]) {
        self.name = name
        self.isSmart = isSmart
        self.predicateString = predicateString
        self.studies = studies
    }

    /// The keys of a study in the file, beside its value.
    private static var studyKeys: [(key: String, value: WritableKeyPath<AlbumsFileStudy, String?>)] {
        [("studyInstanceUID", \.studyInstanceUID), ("patientName", \.patientName), ("patientID", \.patientID),
         ("patientUID", \.patientUID), ("name", \.name), ("modality", \.modality), ("accessionNumber", \.accessionNumber)]
    }
    private static var studyDateKeys: [(key: String, value: WritableKeyPath<AlbumsFileStudy, Date?>)] {
        [("dateOfBirth", \.dateOfBirth), ("date", \.date)]
    }

    /// The entry of the file: a nil name or predicate is left out, as is a
    /// study's nil value; the reader reads a missing key as nil.
    public var propertyList: [String: Any] {
        var entry: [String: Any] = [:]
        if let name { entry["name"] = name }
        if isSmart {
            entry["smartAlbum"] = true
            if let predicateString { entry["predicateString"] = predicateString }
        } else {
            entry["studies"] = studies.map { study -> [String: Any] in
                var values: [String: Any] = [:]
                for (key, path) in Self.studyKeys { if let value = study[keyPath: path] { values[key] = value } }
                for (key, path) in Self.studyDateKeys { if let value = study[keyPath: path] { values[key] = value } }
                return values
            }
        }
        return entry
    }

    /// An entry read from the file, nil when it is not a dictionary. A key of
    /// another type is read as missing; "smartAlbum" is a number or a string.
    public init?(propertyList: Any) {
        guard let entry = propertyList as? [String: Any] else { return nil }
        name = entry["name"] as? String
        isSmart = Self.boolValue(entry["smartAlbum"])
        predicateString = entry["predicateString"] as? String
        studies = ((entry["studies"] as? [Any]) ?? []).map { item in
            var study = AlbumsFileStudy()
            let values = item as? [String: Any] ?? [:]
            for (key, path) in Self.studyKeys { study[keyPath: path] = values[key] as? String }
            for (key, path) in Self.studyDateKeys { study[keyPath: path] = values[key] as? Date }
            return study
        }
    }

    /// `[object boolValue]` of a number or a string, false for the rest.
    static func boolValue(_ object: Any?) -> Bool {
        if let flag = object as? Bool { return flag }
        if let number = object as? Int { return number != 0 }
        if let string = object as? String {
            // -[NSString boolValue]: Y, y, T, t or a non-zero digit after spaces and zeros.
            let trimmed = string.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "+" || $0 == "-" || $0 == "0" }
            guard let first = trimmed.first else { return false }
            return "YyTt123456789".contains(first)
        }
        return false
    }

    /// The entries of the file's array; nil when it is not an array.
    public static func entries(ofPropertyList propertyList: Any?) -> [AlbumsFileEntry]? {
        guard let items = propertyList as? [Any] else { return nil }
        return items.compactMap { AlbumsFileEntry(propertyList: $0) }
    }
}
