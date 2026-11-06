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

// The rules of the browser's study list that need neither AppKit nor the
// app's classes: the predicate of the list, which distant studies of the PACS
// On-Demand nodes join it and which local studies they replace, the order of
// the list and of a patient's other studies, the files a selection gives, the
// filters sent to the nodes and the nodes asked. The app reads the database,
// the defaults and the views, and gives these rules plain values.
//
// Strings are compared as NSString compares them, code unit by code unit, as
// -isEqualToString:, -containsObject: and NSSet did.

/// NSString's -isEqualToString:, with nil never equal.
@inline(__always)
private func same(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}

/// -[NSArray containsObject:] of a string: nil is never found.
private func contains(_ values: [String?], _ value: String?) -> Bool {
    guard let value else { return false }
    return values.contains { same($0, value) }
}

/// -[NSArray indexOfObject:] of a string.
private func firstIndex(_ values: [String?], _ value: String?) -> Int? {
    guard let value else { return nil }
    return values.firstIndex { same($0, value) }
}

// MARK: - The result in the entire database

/// The "results in entire DB" button under a filtered album.
public enum EntireDatabaseResult {
    /// The count the button shows, or nil when it is hidden: shown when the
    /// nodes or the whole local database found more studies than the list
    /// shows. The counts are compared as the int and the NSUInteger were.
    public static func shownCount(distant: Int32, local: Int32, displayed: Int) -> Int32? {
        let list = UInt(bitPattern: displayed)
        if UInt(bitPattern: Int(distant)) > list || UInt(bitPattern: Int(local)) > list {
            return distant > local ? distant : local
        }
        return nil
    }
}

// MARK: - The predicate of the list

/// The predicate the studies of the list are filtered with.
public enum StudyListPredicate {
    /// The studies of the time interval: from the start to the end, or from
    /// the start on. An interval with an end and no start starts at the
    /// reference date.
    public static func timeInterval(start: Date?, end: Date?) -> NSPredicate? {
        if start == nil && end == nil { return nil }
        if let start, let end {
            return NSPredicate(format: "date >= CAST(%lf, \"NSDate\") AND date <= CAST(%lf, \"NSDate\")",
                               start.timeIntervalSinceReferenceDate, end.timeIntervalSinceReferenceDate)
        }
        return NSPredicate(format: "date >= CAST(%lf, \"NSDate\")", start?.timeIntervalSinceReferenceDate ?? 0)
    }

    /// The studies of a modality.
    public static func modality(_ modality: String) -> NSPredicate {
        return NSPredicate(format: "modality CONTAINS %@", modality)
    }

    /// `predicate` and `previous`, or `predicate` alone.
    public static func adding(_ predicate: NSPredicate, to previous: NSPredicate?) -> NSPredicate {
        return NSCompoundPredicate(andPredicateWithSubpredicates: previous.map { [predicate, $0] } ?? [predicate])
    }

    /// The predicate of the list and whether it filters: the time interval,
    /// then the modality (when one is chosen), then the search field's
    /// predicate; a test predicate replaces them all, and without any the
    /// list has every study.
    public static func make(start: Date?, end: Date?, modality: String?, filter: NSPredicate?,
                            test: NSPredicate?) -> (predicate: NSPredicate, filtered: Bool) {
        var predicate: NSPredicate?
        var filtered = false
        if let interval = timeInterval(start: start, end: end) {
            predicate = adding(interval, to: predicate)
            filtered = true
        }
        if let modality {
            predicate = adding(self.modality(modality), to: predicate)
            filtered = true
        }
        if let filter {
            predicate = adding(filter, to: predicate)
            filtered = true
        }
        if let test { predicate = test }
        return (predicate ?? NSPredicate(value: true), filtered)
    }
}

// MARK: - Distant studies in the list

/// Whether the distant studies last found join the list.
public enum DistantStudiesInList {
    /// They do for the smart album they were found for, or, with no smart
    /// album, for the time interval or the search they were found for.
    public static func apply(hasDistantStudies: Bool, smartAlbum: String?, distantAlbum: String?,
                             start: Date?, end: Date?, distantStart: Date?, distantEnd: Date?, hasFilter: Bool,
                             searchType: Int32, distantSearchType: Int32,
                             searchString: String?, distantSearchString: String?) -> Bool {
        if hasDistantStudies && smartAlbum != nil && same(distantAlbum, smartAlbum) {
            return true
        }
        guard start != nil || end != nil || hasFilter else { return false }
        var apply = false
        if start != nil || end != nil {
            let sameStart = distantStart != nil && start != nil && distantStart == start
            if sameStart && (end == nil || (distantEnd != nil && distantEnd == end)) {
                apply = true
            }
        }
        if distantSearchType == searchType && same(distantSearchString, searchString) {
            apply = true
        }
        return apply
    }
}

/// How the distant studies of the PACS On-Demand nodes join local studies.
/// The studies are given by their UIDs; their numbers of images are asked
/// only when compared, as [[study rawNoFiles] intValue] and
/// [[study noFiles] intValue] were.
public enum DistantStudyMerge {
    /// The list's merge: which distant studies are added at its end, which
    /// replace a local study, and which are retrieved.
    public struct ListMerge: Equatable, Sendable {
        /// Distant studies added at the end of the list, in order.
        public var added: [Int] = []
        /// The rows replaced, in order.
        public var replaced: [Replacement] = []
        /// Distant studies to retrieve, in order.
        public var retrieved: [Int] = []
    }

    public struct Replacement: Equatable, Sendable {
        public var row: Int
        public var distant: Int
    }

    /// The merge of the list. A distant study the list does not have is
    /// added (and retrieved for an album that retrieves automatically). With
    /// `preferMoreImages`, a distant study with more images than the local
    /// one of the same UID, which is not being retrieved already, is
    /// retrieved when the album or the defaults retrieve automatically, and
    /// otherwise takes its row. The UIDs of the list are those before the
    /// merge; a row already replaced compares with the distant study in it.
    public static func list(localUIDs: [String?], distantUIDs: [String?], preferMoreImages: Bool,
                            autoretrieve: Bool, retrievePartial: Bool,
                            inRetrieveQueue: (Int) -> Bool, localRawFiles: (Int) -> Int32,
                            distantRawFiles: (Int) -> Int32, distantFiles: (Int) -> Int32) -> ListMerge {
        var merge = ListMerge()
        var replacedBy: [Int: Int] = [:]
        for (d, uid) in distantUIDs.enumerated() {
            if !contains(localUIDs, uid) {
                merge.added.append(d)
                if autoretrieve { merge.retrieved.append(d) }
            } else if preferMoreImages {
                if !inRetrieveQueue(d), let row = firstIndex(localUIDs, uid) {
                    let raw = replacedBy[row].map(distantRawFiles) ?? localRawFiles(row)
                    if raw < distantFiles(d) {
                        if autoretrieve || retrievePartial {
                            merge.retrieved.append(d)
                        } else {
                            merge.replaced.append(Replacement(row: row, distant: d))
                            replacedBy[row] = d
                        }
                    }
                }
            }
        }
        return merge
    }

    /// A member of a patient's history: a local study or a distant one.
    public enum Member: Equatable, Sendable {
        case local(Int)
        case distant(Int)
    }

    /// The merge of a patient's history: a distant study the history does
    /// not have yet is added to it at once; with `preferMoreImages`, one with
    /// more images than the study of the same UID, which is not being
    /// retrieved already, takes its place, and is retrieved when the defaults
    /// retrieve partial studies.
    public static func history(localUIDs: [String?], distantUIDs: [String?], preferMoreImages: Bool,
                               retrievePartial: Bool, inRetrieveQueue: (Int) -> Bool,
                               localRawFiles: (Int) -> Int32, distantRawFiles: (Int) -> Int32,
                               distantFiles: (Int) -> Int32) -> (members: [Member], retrieved: [Int]) {
        var members = localUIDs.indices.map { Member.local($0) }
        var uids = localUIDs
        var retrieved: [Int] = []
        for (d, uid) in distantUIDs.enumerated() {
            if !contains(uids, uid) {
                members.append(.distant(d))
                uids.append(uid)
            } else if preferMoreImages {
                if !inRetrieveQueue(d), let row = firstIndex(uids, uid) {
                    let raw: Int32
                    switch members[row] {
                    case .local(let i): raw = localRawFiles(i)
                    case .distant(let j): raw = distantRawFiles(j)
                    }
                    if raw < distantFiles(d) {
                        members[row] = .distant(d)
                        uids[row] = uid
                        if retrievePartial { retrieved.append(d) }
                    }
                }
            }
        }
        return (members, retrieved)
    }

    /// The studies of other databases a search adds to the list: those whose
    /// identity is neither in the list nor added before.
    public static func federated(localKeys: [String?], federatedKeys: [String?]) -> [Int] {
        let seen = NSMutableSet()
        for key in localKeys {
            if let key { seen.add(key as NSString) }
        }
        var added: [Int] = []
        for (index, key) in federatedKeys.enumerated() {
            if let key, !seen.contains(key as NSString) {
                added.append(index)
                seen.add(key as NSString)
            }
        }
        return added
    }

    /// The studies a second patient-name query adds: those whose UID the
    /// first query did not find.
    public static func missing(from found: [String?], in more: [String?]) -> [Int] {
        return more.indices.filter { !contains(found, more[$0]) }
    }
}

// MARK: - The order of the list

/// The order of the list.
public enum StudyListOrder {
    /// The outline's sort descriptors: by name then the latest date first
    /// without any, the name's then the latest date first when the name
    /// comes first, the outline's otherwise.
    public static func descriptors(_ current: [NSSortDescriptor]?) -> [NSSortDescriptor] {
        let byDate = NSSortDescriptor(key: "date", ascending: false)
        guard let current, let first = current.first else {
            let byName = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.caseInsensitiveCompare(_:)))
            return [byName, byDate]
        }
        if same(first.key, "name") {
            return [first, byDate]
        }
        return current
    }

    /// A row of a list grouped by patient.
    public enum Row: Equatable, Sendable {
        /// A study of the list.
        case study(Int)
        /// The `related` study of the patient of the list's study `of`.
        case related(of: Int, Int)
    }

    /// The list with each study followed by the other studies of its patient
    /// it does not have yet, the latest first, at most `limit` per study (no
    /// limit at 0 or less). `related` gives the UIDs of a study's other
    /// studies, already sorted, or nil when asking for them failed. A
    /// related study without a UID still takes its place, and ends the
    /// study's turn, as the exception it raised did.
    public static func groupedByPatient(uids: [String?], limit: Int,
                                        related: (Int) -> [String?]?) -> [Row] {
        var rows = uids.indices.map { Row.study($0) }
        var rowUIDs = uids
        var studyIndex = 0
        for study in uids.indices {
            if let others = related(study) {
                var listed = rowUIDs
                var expanded = 0
                for (r, uid) in others.enumerated() {
                    if limit > 0 && expanded >= limit { break }
                    if !contains(listed, uid) {
                        studyIndex += 1
                        expanded += 1
                        rows.insert(.related(of: study, r), at: studyIndex)
                        rowUIDs.insert(uid, at: studyIndex)
                        guard uid != nil else { break }
                        listed.insert(uid, at: studyIndex)
                    }
                }
            }
            studyIndex += 1
        }
        return rows
    }
}

// MARK: - The images of a selection

/// Which image of each series a study's selection takes.
public enum SelectionImages {
    /// enum dbObjectSelection of BrowserController.h.
    public static let any: Int32 = 0, middle: Int32 = 1, firstForFirst: Int32 = 2

    /// The image taken from each series of a study, series after series:
    /// `preferred` for the first; with `firstForFirst`, the second also takes
    /// the first image and the others any. A series without a thumbnail
    /// takes its middle image, unless the middle is preferred already (its
    /// thumbnail is then not asked).
    public struct Walk: Sendable {
        private var preferred: Int32
        private var first = true

        public init(preferred: Int32) {
            self.preferred = preferred
        }

        public mutating func next(hasThumbnail: () -> Bool) -> Int32 {
            var which = preferred
            if preferred == SelectionImages.firstForFirst && !first { preferred = SelectionImages.any }
            first = false
            if preferred != SelectionImages.middle && !hasThumbnail() { which = SelectionImages.middle }
            return which
        }
    }

    /// The middle image of `count`, the one before the middle for an even
    /// count; nil without images.
    public static func middleIndex(count: Int) -> Int? {
        if count <= 0 { return nil }
        return count > 1 ? count / 2 - 1 : count / 2
    }

    /// The name and number of the series that keeps an empty study from
    /// being deleted.
    public static let noAutodeletionName = "OsiriX No Autodeletion", noAutodeletionID: Int32 = 5005

    public static func isNoAutodeletionSeries(name: String?, id: Int32) -> Bool {
        return same(name, noAutodeletionName) && id == noAutodeletionID
    }

    /// What a selected study loses: its "No Autodeletion" series once it has
    /// images, the study itself when it has neither images nor that series
    /// (only when every object, not only images, is asked).
    public static func studyCleanup(imageCount: Int, hasNoAutodeletionSeries: Bool,
                                    onlyImages: Bool) -> (deleteSeries: Bool, deleteStudy: Bool) {
        return (imageCount != 0 && hasNoAutodeletionSeries,
                !onlyImages && imageCount == 0 && !hasNoAutodeletionSeries)
    }
}

// MARK: - The PACS On-Demand nodes

/// The nodes asked for distant studies and what they are asked.
public enum DistantSearch {
    /// The search type of "Series Description", which a study query cannot ask.
    public static let seriesDescriptionType: Int32 = 11

    /// The nodes of `candidates` the comparative search uses, in the order of
    /// `chosen` (the "comparativeSearchDICOMNodes" default, each with a
    /// "server" holding its "Description" and "Address"); none when a chosen
    /// node lacks one of them.
    public static func comparativeServers(chosen: [NSDictionary], candidates: [NSDictionary]) -> (servers: [Int], incomplete: Bool) {
        var descriptions: [Any] = [], addresses: [Any] = []
        for node in chosen {
            let server = node.value(forKey: "server") as AnyObject?
            if let description = server?.value(forKey: "Description") { descriptions.append(description) }
            if let address = server?.value(forKey: "Address") { addresses.append(address) }
        }
        if descriptions.count != addresses.count { return ([], true) }
        var servers: [Int] = []
        for x in descriptions.indices {
            for (index, candidate) in candidates.enumerated() {
                if equalStrings(descriptions[x], candidate.object(forKey: "Description"))
                    && equalStrings(addresses[x], candidate.object(forKey: "Address")) {
                    servers.append(index)
                }
            }
        }
        return (servers, false)
    }

    private static func equalStrings(_ a: Any, _ b: Any?) -> Bool {
        guard let a = a as? NSString, let b = b as? NSString else { return false }
        return a.isEqual(to: b as String)
    }

    /// The name of a search type, to localize; nil for a type without one.
    public static func searchTypeName(_ type: Int32) -> String? {
        switch type {
        case 7, 0: return "Patient Name"
        case 1: return "Patient ID"
        case 2: return "Study ID"
        case 3: return "Comments"
        case 4: return "Study Description"
        case 11: return "Series Description"
        case 5: return "Modality"
        case 6: return "AccessionNumber"
        default: return nil
        }
    }

    /// The filters of a search of the search field: a patient name (the
    /// field's "All fields" asks the name too) without its commas and ending
    /// in a wildcard, comments and descriptions ending in one, the other
    /// fields as typed. The modality filter replaces a modality searched.
    /// Also the patient name as searched, which a second query asks with its
    /// last space made the component separator.
    public static func searchFilters(_ search: String, type: Int32, modality: String?) -> (filters: NSMutableDictionary, name: String) {
        let filters = NSMutableDictionary()
        var search = search as NSString
        switch type {
        case 7, 0:
            search = search.replacingOccurrences(of: ", ", with: " ") as NSString
            search = search.replacingOccurrences(of: ",", with: " ") as NSString
            filters["PatientsName"] = search.appending("*")
        case 1:
            filters["PatientID"] = search
        case 2:
            filters["StudyID"] = search
        case 3:
            filters["Comments"] = search.appending("*")
        case 4:
            filters["StudyDescription"] = search.appending("*")
        case 5:
            filters["modality"] = [search]
        case 6:
            filters["AccessionNumber"] = search
        default:
            break
        }
        if let modality { filters["modality"] = [modality] }
        return (filters, search as String)
    }

    /// The patient name of the second query: for a name search of several
    /// words, the last space becomes "^"; nil otherwise.
    public static func alternatePatientName(_ name: String, type: Int32) -> String? {
        guard type == 0 || type == 7, (name as NSString).components(separatedBy: " ").count > 1 else { return nil }
        let wildcard = (name as NSString).appending("*") as NSString
        let last = wildcard.range(of: " ", options: .backwards)
        return wildcard.replacingCharacters(in: last, with: "^")
    }

    /// The date codes of the Query window (QueryDateFilter of IsiXDICOMNetwork).
    public static let dateBetween: Int32 = 5, dateAfter: Int32 = 12

    /// The filters of a time interval: between both dates, or after the
    /// start. Nil without a start, which the filters cannot hold.
    public static func intervalFilters(from: Date?, to: Date?, modality: String?) -> NSMutableDictionary? {
        let filters = NSMutableDictionary()
        if from != nil && to != nil {
            filters["date"] = NSNumber(value: dateBetween)
        } else if from != nil {
            filters["date"] = NSNumber(value: dateAfter)
        }
        guard let from else { return nil }
        filters["fromDate"] = from
        if let to { filters["toDate"] = to }
        if let modality { filters["modality"] = [modality] }
        return filters
    }

    /// The filters of the "smartAlbumStudiesDICOMNodes" entry of a smart
    /// album: the first activated one with its name.
    public static func smartAlbumFilters(_ entries: [NSDictionary], album: String?) -> NSDictionary? {
        for entry in entries {
            let activated = (entry.value(forKey: "activated") as AnyObject?)?.boolValue ?? false
            if activated && same(album, entry.value(forKey: "name") as? String) {
                return entry
            }
        }
        return nil
    }

    /// Whether a smart album retrieves its distant studies automatically.
    public static func albumRetrievesAutomatically(_ entries: [NSDictionary], album: String?) -> Bool {
        var retrieves = false
        for entry in entries {
            if ((entry.value(forKey: "autoretrieve") as AnyObject?)?.boolValue ?? false) && same(album, entry.value(forKey: "name") as? String) {
                retrieves = true
            }
        }
        return retrieves
    }

    /// Whether the history shown is still the patient's: the same patient UID,
    /// ignoring case, diacritics and width.
    public static func samePatient(_ shown: String?, _ patientUID: String?) -> Bool {
        guard let shown, let patientUID else { return false }
        return (shown as NSString).compare(patientUID, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
    }
}

// MARK: - Locks of dead processes

/// The lock files the DICOM processes leave in their folder, named
/// "lock_process-" and the process number.
public enum ProcessLocks {
    public static let prefix = "lock_process-"

    /// The process of a lock file, or nil for another file (0 for a name
    /// without a number).
    public static func pid(forFileName name: String) -> Int32? {
        let name = name as NSString
        guard name.hasPrefix(prefix) else { return nil }
        return (name.replacingOccurrences(of: prefix, with: "") as NSString).intValue
    }

    /// The seconds from now of a lock's creation (negative for the past),
    /// counted as an int: -timeIntervalSinceNow assigned to an int.
    public static func seconds(sinceNow: TimeInterval) -> Int32 {
        if sinceNow.isNaN { return 0 }
        if sinceNow >= Double(Int32.max) { return Int32.max }
        if sinceNow <= Double(Int32.min) { return Int32.min }
        return Int32(sinceNow)
    }

    /// Whether a lock created `sinceNow` seconds ago is older than an hour.
    public static func isStale(sinceNow: TimeInterval) -> Bool {
        return seconds(sinceNow: sinceNow) < -60 * 60 * 1
    }
}
