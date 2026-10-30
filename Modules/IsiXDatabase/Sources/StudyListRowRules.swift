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

// The rules of the rows of the browser's study list that need neither AppKit
// nor the app's classes: what a column shows for a study, a series or a study
// of a DICOM node, how a row is drawn (font, same-patient background, recency
// icon, report icon, grey "unknown"), what an edit writes, which columns the
// header menu shows, a patient's history when the selection or the database
// changes, merging and deleting. The app reads the rows, the defaults and the
// views, and gives these rules plain values or closures that read them, in the
// order the former Objective-C read them.
//
// Values follow Objective-C's messages: -intValue of anything else than a
// number or a string is 0, a message to nil answers 0, NO or nil, and strings
// compare code unit by code unit, as -isEqualToString: did.

private func same(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}

private func sameText(_ a: Any?, _ b: String) -> Bool {
    guard let a = a as? NSString else { return false }
    return a.isEqual(to: b)
}

/// The Objective-C reading of the values the rows answer.
public enum RowValues {
    /// [value intValue]: 0 for nil and for what is neither a number nor a string.
    public static func int(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let string = value as? NSString { return string.intValue }
        return 0
    }

    /// An int given where a BOOL is expected: a bool on arm64, a signed char
    /// that keeps the low byte on x86_64.
    public static func bool(fromInt value: Int32) -> Bool {
        #if arch(x86_64)
        return Int8(truncatingIfNeeded: value) != 0
        #else
        return value != 0
        #endif
    }

    /// No value, or an empty string.
    public static func isBlank(_ value: Any?) -> Bool {
        guard let value else { return true }
        if let string = value as? NSString { return string.length == 0 }
        return false
    }

    /// [collection count], 0 for nil.
    public static func count(_ collection: Any?) -> Int {
        switch collection {
        case let set as NSSet: return set.count
        case let array as NSArray: return array.count
        case let ordered as NSOrderedSet: return ordered.count
        case let dictionary as NSDictionary: return dictionary.count
        default: return 0
        }
    }

    /// [receiver timeIntervalSinceDate: other]: 0 when the receiver is nil, NaN
    /// when the other date is.
    public static func interval(_ receiver: Double?, since other: Double?) -> Double {
        guard let receiver else { return 0 }
        guard let other else { return .nan }
        return receiver - other
    }
}

// MARK: - The value of a cell

/// What a row of the study list answers, read when a rule needs it. The app
/// answers it from the row's object without building anything per cell.
public protocol StudyListRowSource {
    /// [item valueForKey:].
    func rowValue(_ key: String) -> Any?
    /// [item isDistant].
    func rowIsDistant() -> Bool
    /// [item isKindOfClass: [DicomStudy class]].
    func rowIsStudyObject() -> Bool
    /// The date the report plugin gives a study; nil without the plugin.
    func rowReportPluginDate() -> Any?
    /// The date of the latest report image of a study.
    func rowLatestReportDate() -> Any?
    /// The study's note, on one line.
    func rowNote() -> Any?
    /// A local study's name, with the database it comes from when that is
    /// not the one shown.
    func rowDisplayName(_ name: Any?) -> Any?
    /// [study numberOfImageSeries].
    func rowNumberOfImageSeries() -> Int
    /// NSLocalizedString of a key.
    func rowLocalized(_ key: String) -> String
}

/// What a column of the study list shows for a row.
public enum StudyListCell {
    /// The columns a series or a study of a node leaves empty.
    public static let blankUnlessStudy = ["dateOfBirth", "referringPhysician", "performingPhysician", "institutionName",
                                          "patientID", "yearOld", "accessionNumber", "noSeries"]
    /// The columns of a series that say "unknown" when empty.
    public static let unknownWhenEmpty = ["name", "studyName", "modality"]

    /// What a row answers, given as closures.
    public struct Row: StudyListRowSource {
        /// [item valueForKey:].
        public var value: (String) -> Any?
        /// [item isDistant].
        public var isDistant: () -> Bool
        /// [item isKindOfClass: [DicomStudy class]].
        public var isStudyObject: () -> Bool
        /// The date the report plugin gives a study; nil without the plugin.
        public var reportPluginDate: () -> Any?
        /// The date of the latest report image of a study.
        public var latestReportDate: () -> Any?
        /// The study's note, on one line.
        public var note: () -> Any?
        /// A local study's name, with the database it comes from when that is
        /// not the one shown.
        public var displayName: (Any?) -> Any?
        /// [study numberOfImageSeries].
        public var numberOfImageSeries: () -> Int
        /// NSLocalizedString of a key.
        public var localized: (String) -> String

        public init(value: @escaping (String) -> Any?, isDistant: @escaping () -> Bool, isStudyObject: @escaping () -> Bool,
                    reportPluginDate: @escaping () -> Any?, latestReportDate: @escaping () -> Any?, note: @escaping () -> Any?,
                    displayName: @escaping (Any?) -> Any?, numberOfImageSeries: @escaping () -> Int,
                    localized: @escaping (String) -> String) {
            self.value = value
            self.isDistant = isDistant
            self.isStudyObject = isStudyObject
            self.reportPluginDate = reportPluginDate
            self.latestReportDate = latestReportDate
            self.note = note
            self.displayName = displayName
            self.numberOfImageSeries = numberOfImageSeries
            self.localized = localized
        }

        public func rowValue(_ key: String) -> Any? { value(key) }
        public func rowIsDistant() -> Bool { isDistant() }
        public func rowIsStudyObject() -> Bool { isStudyObject() }
        public func rowReportPluginDate() -> Any? { reportPluginDate() }
        public func rowLatestReportDate() -> Any? { latestReportDate() }
        public func rowNote() -> Any? { note() }
        public func rowDisplayName(_ name: Any?) -> Any? { displayName(name) }
        public func rowNumberOfImageSeries() -> Int { numberOfImageSeries() }
        public func rowLocalized(_ key: String) -> String { localized(key) }
    }

    /// One of blankUnlessStudy, without searching the array per cell.
    static func isBlankUnlessStudy(_ identifier: String) -> Bool {
        switch identifier {
        case "dateOfBirth", "referringPhysician", "performingPhysician", "institutionName",
             "patientID", "yearOld", "accessionNumber", "noSeries": return true
        default: return false
        }
    }

    /// One of unknownWhenEmpty, without searching the array per cell.
    static func isUnknownWhenEmpty(_ identifier: String) -> Bool {
        switch identifier {
        case "name", "studyName", "modality": return true
        default: return false
        }
    }

    /// The key a column reads: a series shows its description as the study
    /// description.
    public static func valueKey(type: Any?, identifier: String) -> String {
        sameText(type, "Series") && identifier == "studyName" ? "seriesDescription" : identifier
    }

    /// A series' name, description or modality that is empty: drawn grey.
    public static func showsUnknown(type: Any?, identifier: String, value: () -> Any?) -> Bool {
        sameText(type, "Series") && isUnknownWhenEmpty(identifier) && RowValues.isBlank(value())
    }

    /// The age column: at the study (0), at the acquisition (1), or both when
    /// they differ ("45/46 y").
    public static func age(display: Int, yearOld: () -> Any?, acquisition: () -> Any?, suffix: String) -> Any? {
        switch display {
        case 0: return yearOld()
        case 1: return acquisition()
        default:
            let old = yearOld(), atAcquisition = acquisition()
            let a = old as? NSString, b = atAcquisition as? NSString
            if let a, let b, a.isEqual(to: b as String) { return old }
            if let a, let b, a.hasSuffix(suffix), b.hasSuffix(suffix) {
                let length = (suffix as NSString).length
                return "\(a.substring(to: a.length - length))/\(b.substring(to: b.length - length))\(suffix)"
            }
            return "\(describe(old))/\(describe(atAcquisition))"
        }
    }

    private static func describe(_ value: Any?) -> String {
        guard let value else { return "(null)" }
        return (value as AnyObject).description ?? "(null)"
    }

    /// -intOutlineView:objectValueForTableColumn:byItem:.
    public static func objectValue<Source: StudyListRowSource>(identifier: String, reportsMode: Int32, hidePatientName: () -> Bool,
                                                               ageDisplay: () -> Int, row: Source) -> Any? {
        if reportsMode == 3 && identifier == "reportURL" {
            return sameText(row.rowValue("type"), "Study") ? row.rowReportPluginDate() : nil
        } else if identifier == "reportURL" {
            guard sameText(row.rowValue("type"), "Study") else { return nil }
            return row.rowValue("reportURL") != nil ? row.rowLatestReportDate() : nil
        }

        if identifier == "stateText" {
            return RowValues.int(row.rowValue("stateText")) == 0 ? nil : row.rowValue("stateText")
        }
        if identifier == "lockedStudy" && !sameText(row.rowValue("type"), "Study") {
            return nil
        }
        if identifier == "note" {
            return row.rowIsStudyObject() ? row.rowNote() : nil
        }
        if identifier == "modality" {
            return row.rowValue("modality")
        }
        if identifier == "name" && sameText(row.rowValue("type"), "Study") {
            let name: Any? = hidePatientName() ? row.rowLocalized("Name hidden") : row.rowValue("name")
            if row.rowIsDistant() { return name }
            return row.rowDisplayName(name)
        }
        if !sameText(row.rowValue("type"), "Study") && isBlankUnlessStudy(identifier) {
            return ""
        }
        if identifier == "yearOld" {
            return age(display: ageDisplay(), yearOld: { row.rowValue("yearOld") }, acquisition: { row.rowValue("yearOldAcquisition") },
                       suffix: row.rowLocalized(" y"))
        }
        if identifier == "noSeries" {
            if row.rowIsStudyObject() { return String(Int32(truncatingIfNeeded: row.rowNumberOfImageSeries())) }
            if let series = row.rowValue("imageSeries") { return String(Int32(truncatingIfNeeded: RowValues.count(series))) }
            return ""
        }

        let value = row.rowValue(valueKey(type: row.rowValue("type"), identifier: identifier))
        if showsUnknown(type: row.rowValue("type"), identifier: identifier, value: { value }) {
            return row.rowLocalized("unknown")
        }
        return value
    }

    /// A series of a study that holds its report: series 5003 named
    /// "OsiriX Report SR", of a structured report class.
    public static func isReportSeries(id: Any?, name: Any?, isStructuredReport: () -> Bool) -> Bool {
        RowValues.int(id) == 5003 && sameText(name, "OsiriX Report SR") && isStructuredReport()
    }

    /// A report image's date that is later than the latest found so far.
    public static func isLater(_ date: Date?, than latest: Date?) -> Bool {
        guard let date else { return false }
        guard let latest else { return true }
        return date.compare(latest) == .orderedDescending
    }
}

// MARK: - Drawing a row

public enum StudyListRowStyle {
    public enum Font: Equatable, Sendable {
        /// A study of a DICOM node.
        case distant
        /// A study of the list itself, or any study when the list shows no
        /// patient's other studies.
        case bold
        /// A patient's other study, listed after the one the list found.
        case regular
        /// A series.
        case series
    }

    /// The font of a row. `listed` is nil when the list shows no patient's
    /// other studies, and otherwise whether the study is one the list found.
    public static func font(isStudy: Bool, isDistant: () -> Bool, listed: () -> Bool?) -> Font {
        guard isStudy else { return .series }
        if isDistant() { return .distant }
        guard let found = listed() else { return .bold }
        return found ? .bold : .regular
    }

    /// The name of a study drawn on a background, as the other studies of the
    /// patient of the selected study are.
    public static func samePatientBackground(enabled: Bool, selectionIsStudy: () -> Bool, isSelection: Bool,
                                             patientUID: () -> Any?, selectedPatientUID: () -> Any?) -> Bool {
        guard enabled, selectionIsStudy() else { return false }
        let patientUID = patientUID()
        guard !isSelection, let uid = patientUID as? NSString, uid.length > 1 else { return false }
        guard let other = selectedPatientUID() as? String else { return false }
        return uid.compare(other, options: samePatientOptions) == .orderedSame
    }

    /// Made once: building the option set is dearer than the comparison.
    private static let samePatientOptions: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    public enum Recency: Equatable, Sendable {
        case tenMinutes, hour, fourHours, today, received
    }

    /// The icon before a study's name: acquired within 10 minutes, the hour,
    /// 4 hours or today, or received within the minute. A study without a date
    /// reads as acquired now, as the messages to nil answered 0.
    /// `added` gives whether the study has a date added and, if so, how long
    /// ago from now (negative); it is read only without another icon.
    public static func recency(dateSinceNow: Double?, date: Double?, todayStart: () -> Double,
                               added: () -> (exists: Bool, sinceNow: Double?)) -> Recency? {
        let sinceNow = dateSinceNow ?? 0
        if sinceNow > -24 * 60 * 60 {
            let today = todayStart()
            if sinceNow > -60 * 10 { return .tenMinutes }
            if sinceNow > -60 * 60 { return .hour }
            if sinceNow > -4 * 60 * 60 { return .fourHours }
            if (date ?? 0) > today { return .today }
        }
        let dateAdded = added()
        if dateAdded.exists && (dateAdded.sinceNow ?? 0) > -60 { return .received }
        return nil
    }

    public enum ReportIcon: Equatable, Sendable {
        case file, web
    }

    /// The icon of the report column: a link to a web page of a local
    /// database, or a file.
    public static func reportIcon(url: Any?, databaseIsLocal: Bool) -> ReportIcon? {
        guard let url = url as? NSString, url.length > 0 else { return nil }
        return databaseIsLocal && (url.hasPrefix("http://") || url.hasPrefix("https://")) ? .web : .file
    }

    public enum ToolTip: Equatable, Sendable {
        case tenMinutes, hour, fourHours, today, addedMinute
    }

    /// The tool tip of the icon before a study's name. `now`, `acquired` and
    /// `added` are seconds since the reference date; the day starts at
    /// midnight GMT, as the former code computed it.
    public static func toolTip(now: Double, acquired: Double?, added: Double?) -> ToolTip? {
        let day = 60.0 * 60 * 24
        let today0 = (now / day).rounded(.down) * day
        let acquiredAgo = RowValues.interval(now, since: acquired)
        let addedAgo = RowValues.interval(now, since: added)
        if acquiredAgo <= 60 * 10 { return .tenMinutes }
        if acquiredAgo <= 60 * 60 { return .hour }
        if acquiredAgo <= 4 * 60 * 60 { return .fourHours }
        if RowValues.interval(acquired, since: today0) >= 0 { return .today }
        if addedAgo <= 60 { return .addedMinute }
        return nil
    }
}

// MARK: - Editing a row

public enum StudyListEdit {
    public enum Write: Equatable, Sendable {
        case skip
        case value
        /// lockedStudy, written as a boolean.
        case locked(Bool)
    }

    /// What an edit of a column writes in each selected row: a status that is
    /// not negative, the lock of studies only, any other value as it is.
    public static func write(key: String, value: Any?, rowType: () -> Any?) -> Write {
        switch key {
        case "stateText": return RowValues.int(value) >= 0 ? .value : .skip
        case "lockedStudy": return sameText(rowType(), "Study") ? .locked(RowValues.bool(fromInt: RowValues.int(value))) : .skip
        default: return .value
        }
    }
}

// MARK: - The tree

public enum StudyListTree {
    /// Whether a row has children: not a surgical procedure row, a study of a
    /// node but not its series, a local study but not a series.
    public static func isExpandable(surgicalRow: Bool, isDistant: () -> Bool, isStudyNode: () -> Bool, type: () -> Any?) -> Bool {
        if surgicalRow { return false }
        if isDistant() { return isStudyNode() }
        return !sameText(type(), "Series")
    }

    /// The children of a local row: the images of a series, the image series
    /// of a study.
    public static func childCount(type: Any?, noFiles: () -> Any?, imageSeries: () -> Any?) -> Int {
        if sameText(type, "Image") { return 0 }
        if sameText(type, "Series") { return Int(RowValues.int(noFiles())) }
        if sameText(type, "Study") { return Int(Int32(truncatingIfNeeded: RowValues.count(imageSeries()))) }
        return 0
    }

    /// A study of a node whose children are not its series any more is asked
    /// again.
    public static func nodeChildrenAreStale(count: Int, lastIsQueryNode: () -> Bool) -> Bool {
        count > 0 && !lastIsQueryNode()
    }
}

// MARK: - The columns menu

public enum StudyListColumns {
    /// The order of the columns in the header's menu: by title, as
    /// -sortUsingComparator: with -compare: put them.
    public static func menuOrder(titles: [String]) -> [Int] {
        let pairs = NSMutableArray()
        for (index, title) in titles.enumerated() { pairs.add([index, title] as NSArray) }
        pairs.sort(comparator: { a, b in
            let x = (a as! NSArray)[1] as! NSString, y = (b as! NSArray)[1] as! NSString
            return x.compare(y as String)
        })
        return pairs.map { (($0 as! NSArray)[0] as! NSNumber).intValue }
    }

    /// Whether a column's menu item is checked: the patient's name unless it
    /// is hidden, any other column when it is shown.
    public static func isChecked(identifier: Any?, hidePatientName: Bool, identifiers: [Any?], hidden: (Int) -> Bool) -> Bool {
        if sameText(identifier, "name") { return !hidePatientName }
        guard let identifier = identifier as? NSObject,
              let index = identifiers.firstIndex(where: { ($0 as? NSObject)?.isEqual(identifier) ?? false }) else { return false }
        return !hidden(index)
    }

    /// The COLUMNSDATABASE preference: the state of each item, by title,
    /// leaving out the items without one.
    public static func saved(titles: [String], states: [Int]) -> NSMutableDictionary {
        let dictionary = NSMutableDictionary()
        for (title, state) in zip(titles, states) where (title as NSString).length > 0 {
            dictionary.setValue(NSNumber(value: Int32(truncatingIfNeeded: state)), forKey: title)
        }
        return dictionary
    }

    public struct Change: Equatable, Sendable {
        public var visible: Bool
        /// The column hidden is the selected one: select the first.
        public var selectFirstColumn: Bool
        public var scrollToColumn: Bool
    }

    /// What the saved state of a column changes: nothing when it matches.
    public static func change(visible: Bool, saved: Any?, isSelectedColumn: () -> Bool) -> Change? {
        let state = RowValues.int(saved)
        guard Int32(visible ? 1 : 0) != state else { return nil }
        return Change(visible: RowValues.bool(fromInt: state), selectFirstColumn: state == 0 && isSelectedColumn(),
                      scrollToColumn: state == 1)
    }
}

// MARK: - A patient's history

public enum ComparativeHistory {
    /// The history and the studies of a smart album are asked to the nodes
    /// again after 3 minutes.
    public static let refreshInterval: TimeInterval = 3 * 60

    public static func refreshDue(now: TimeInterval, last: TimeInterval) -> Bool {
        now - last > refreshInterval
    }

    /// A study retrieved from the history is waited for 10 seconds.
    public static func stillWaiting(now: TimeInterval, since: TimeInterval) -> Bool {
        now - since < 10
    }

    /// Whether the selected study is another patient's than the history's:
    /// [selected compare: shown options:] != NSOrderedSame, where a nil
    /// selected UID answered the same and a nil shown one did not.
    public static func patientChanged(selected: Any?, shown: Any?) -> Bool {
        guard let selected = selected as? NSString else { return false }
        guard let shown = shown as? String else { return true }
        return selected.compare(shown, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != .orderedSame
    }

    /// Whether a study is of the patient the history shows:
    /// [shown compare: patientUID options:] == NSOrderedSame.
    public static func isShownPatient(shown: Any?, patientUID: Any?) -> Bool {
        guard let shown = shown as? NSString, let uid = patientUID as? String else { return false }
        return shown.compare(uid, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
    }

    /// The row of a study in the history, by UID; nil when it is not there.
    /// Without a history the row is 0, as the message to nil answered.
    public static func row(of uid: Any?, in uids: [Any?]?) -> Int? {
        guard let uids else { return 0 }
        guard let uid = uid as? NSObject else { return nil }
        return uids.firstIndex { ($0 as? NSObject)?.isEqual(uid) ?? false }
    }

    /// The studies of the history a new local study stands for, by UID, and
    /// those of them that are studies of a node, which it replaces.
    public static func newStudy(_ uid: Any?, uids: [Any?], isQueryNode: (Int) -> Bool) -> (found: Bool, replaced: [Int]) {
        var found = false, replaced: [Int] = []
        for (index, other) in uids.enumerated() where same(other as? String, uid as? String) {
            found = true
            if isQueryNode(index) { replaced.append(index) }
        }
        return (found, replaced)
    }
}

// MARK: - The matrix of the selection

public enum OutlineSelection {
    /// The thumbnails are built again unless the same row is selected with
    /// as many files.
    public static func matrixNeedsRefresh(sameItem: Bool, files: Int, previousFiles: Int) -> Bool {
        !(sameItem && files == previousFiles)
    }

    /// A series of one multi-frame image shows its frames.
    public static func showsFrames(type: Any?, imageCount: () -> Int, frames: () -> Any?) -> Bool {
        sameText(type, "Series") && imageCount() == 1 && RowValues.int(frames()) > 1
    }

    /// The thumbnails of the series of a study are made on the main thread
    /// when fewer than 5 are missing: faster, and no blinking. The missing
    /// ones are counted only for a study.
    public static func iconsOnSeparateThread(imageLevel: Bool, missingThumbnails: () -> Int) -> Bool {
        imageLevel || missingThumbnails() >= 5
    }
}

// MARK: - Merging and unifying

public enum StudyMerge {
    /// The series the others merge into: the last one whose image is a DICOM
    /// file, or nil to keep the first.
    public static func destinationSeries(count: Int, isSeries: (Int) -> Bool, imageExtension: (Int) -> Any?) -> Int? {
        var destination: Int?
        for index in 0..<count where isSeries(index) && sameText(imageExtension(index), "dcm") {
            destination = index
        }
        return destination
    }

    /// The names and IDs a study's files held besides their own, with the
    /// study's present name and ID added.
    public static func formerIdentity(otherNames: Any?, otherIDs: Any?, name: Any?, patientID: Any?) -> (names: String, ids: String) {
        func prefix(_ value: Any?) -> String {
            guard let value = value as? NSString, value.length > 0 else { return "" }
            return (value as String) + " - "
        }
        return (prefix(otherNames) + ((name as? String) ?? ""), prefix(otherIDs) + ((patientID as? String) ?? ""))
    }

    /// Whether merging a study changes its patient: a different ID or name.
    public static func changesPatient(destinationID: Any?, destinationName: Any?, studyID: Any?, studyName: Any?) -> Bool {
        !same(destinationID as? String, studyID as? String) || !same(destinationName as? String, studyName as? String)
    }

    /// Patient ID, name, birth date, other IDs and other names.
    public static let patientTags = ["(0010,0020)", "(0010,0010)", "(0010,0030)", "(0010,1000)", "(0010,1001)"]
    /// Study ID, study instance UID and study description.
    public static let studyTags = ["(0020,0010)", "(0020,000D)", "(0008,1030)"]
    /// The character set a file declares before it takes text it cannot hold.
    public static let characterSetTag = "(0008,0005)"
    public static let unicodeCharacterSet = "ISO_IR 192"

    /// The edits of the files: each tag with its value, empty for none.
    public static func edits(tags: [String], values: [Any?]) -> [(tag: String, value: Any)] {
        zip(tags, values).map { ($0, $1 ?? "") }
    }
}

// MARK: - Deleting

public enum StudyDeletion {
    public enum Locked: Equatable, Sendable {
        case none, some, all
    }

    /// Whether the images to delete are in locked studies: all of them, some
    /// or none.
    public static func locked(_ count: Int, of total: Int) -> Locked {
        if count == total && count > 0 { return .all }
        return count > 0 ? .some : .none
    }

    /// Whether the thumbnails are deleted rather than the selected rows: not
    /// without a sender, and not from the list's menu or with the list or the
    /// history focused. A thumbnail's menu, the thumbnails focused or any
    /// other sender delete the thumbnails.
    public static func deletesThumbnails(hasSender: Bool, listAsked: () -> Bool) -> Bool {
        hasSender && !listAsked()
    }

    public enum Question: Equatable, Sendable {
        /// Delete, or only remove from the album.
        case deleteOrRemove
        case delete
    }

    /// The question asked: a selection of rows in an album that is not smart
    /// can also only leave the album.
    public static func question(albumRow: Int, thumbnails: Bool, smartAlbum: () -> Bool) -> Question {
        guard albumRow > 0 && !thumbnails else { return .delete }
        return smartAlbum() ? .delete : .deleteOrRemove
    }

    /// The file that goes with a deleted one: the .img of an ANALYZE .hdr.
    public static func companionFile(of path: String) -> String? {
        let path = path as NSString
        guard (path.pathExtension as NSString).isEqual(to: "hdr") else { return nil }
        return (path.deletingPathExtension as NSString).appendingPathExtension("img")
    }

    /// The folder of a deleted file goes when it is left empty, or holds only
    /// a .DS_Store.
    public static func removesFolder(contents: [String]?) -> Bool {
        let contents = contents ?? []
        if contents.isEmpty { return true }
        return contents.count == 1 && (contents[0] as NSString).uppercased.hasSuffix(".DS_STORE")
    }
}
