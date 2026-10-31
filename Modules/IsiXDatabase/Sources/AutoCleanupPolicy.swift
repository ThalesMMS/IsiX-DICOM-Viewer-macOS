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

import Foundation
import IsiXPreferences

/// One study of a database, read once on the thread of its context, as far as
/// the rules of the automatic cleanup look at it.
public struct CleanupStudyRow: Equatable, Identifiable, Sendable {
    /// Which study this is, in the terms of whoever read the rows.
    public let id: Int
    public let patientUID: String?
    public let date: Date?
    public let dateOpened: Date?
    public let dateAdded: Date?
    public let isLocked: Bool
    public let isInAlbum: Bool
    public let comment: String?
    public let comment2: String?
    public let comment3: String?
    public let comment4: String?

    public init(id: Int, patientUID: String?, date: Date?, dateOpened: Date?, dateAdded: Date?,
                isLocked: Bool, isInAlbum: Bool,
                comment: String? = nil, comment2: String? = nil, comment3: String? = nil, comment4: String? = nil) {
        self.id = id
        self.patientUID = patientUID
        self.date = date
        self.dateOpened = dateOpened
        self.dateAdded = dateAdded
        self.isLocked = isLocked
        self.isInAlbum = isInAlbum
        self.comment = comment
        self.comment2 = comment2
        self.comment3 = comment3
        self.comment4 = comment4
    }

    /// Whether any of its four comments has text.
    var hasComments: Bool {
        [comment, comment2, comment3, comment4].contains { ($0 as NSString?)?.length ?? 0 != 0 }
    }
}

/// The preferences of the automatic cleanup, read once, with the keys the
/// preference pane writes. The conversions are those the cleanup always made:
/// each value keeps the type it was read with.
public struct AutoCleanupPreferences: Equatable, Sendable {
    /// LOGCLEANINGDAYS: the days a log entry is kept.
    public var logRetentionDays = 0
    /// AUTOCLEANINGDATEPRODUCEDDAYS as an integer, for the check of the period.
    public var producedRetentionDays = 0
    /// AUTOCLEANINGDATEOPENEDDAYS as an integer, for the check of the period.
    public var openedRetentionDays = 0
    /// AUTOCLEANINGDATEPRODUCEDDAYS as a 32-bit number, for the date it gives.
    public var producedDays: Int32 = 0
    /// AUTOCLEANINGDATEOPENEDDAYS as a 32-bit number, for the date it gives.
    public var openedDays: Int32 = 0
    /// AUTOCLEANINGDATE.
    public var dateRuleEnabled = false
    /// AUTOCLEANINGDATEPRODUCED.
    public var usesDateProduced = false
    /// AUTOCLEANINGDATEOPENED.
    public var usesDateOpened = false
    /// AUTOCLEANINGCOMMENTS: the date rule also looks at the first comment.
    public var commentFilterEnabled = false
    /// AUTOCLEANINGCOMMENTSTEXT.
    public var commentFilterText: String?
    /// AUTOCLEANINGDONTCONTAIN: 0 keeps the studies without the text, 1 those
    /// with it, and any other value keeps both.
    public var commentFilterMode = 0
    /// dontDeleteStudiesWithComments.
    public var keepsStudiesWithComments = false
    /// AUTOCLEANINGDELETEORIGINAL: linked originals are deleted too.
    public var deletesLinkedOriginals = false
    /// AUTOCLEANINGSPACE.
    public var spaceRuleEnabled = false
    /// AUTOCLEANINGSPACESIZE: megabytes, or a percentage of the volume when negative.
    public var spaceSizeSetting = 0.0
    /// AutocleanSpaceMode, which date orders the space rule; nil when the
    /// stored value is neither a number nor a string.
    public var spaceMode: Int32? = 0
    /// AutocleanSpaceMode as an integer, for the text of the preview.
    public var spaceModeSetting = 0

    public init() {}

    /// The days are read twice, as the cleanup always read them: as an integer
    /// for the check of the period, and as the leading number of their text
    /// for the date they give.
    public init(defaults: any PreferenceStore) {
        typealias Keys = DatabasePreferences
        logRetentionDays = defaults[Keys.logRetentionDays]
        producedRetentionDays = defaults[Keys.autoCleanProducedDays.reading(as: Int.self)]
        openedRetentionDays = defaults[Keys.autoCleanOpenedDays.reading(as: Int.self)]
        producedDays = (defaults[Keys.autoCleanProducedDays] as NSString?)?.intValue ?? 0
        openedDays = (defaults[Keys.autoCleanOpenedDays] as NSString?)?.intValue ?? 0
        dateRuleEnabled = defaults[Keys.autoCleanByDate]
        usesDateProduced = defaults[Keys.autoCleanByDateProduced]
        usesDateOpened = defaults[Keys.autoCleanByDateOpened]
        commentFilterEnabled = defaults[Keys.autoCleanCommentFilter]
        commentFilterText = defaults[Keys.autoCleanCommentText]
        commentFilterMode = defaults[Keys.autoCleanCommentMode]
        keepsStudiesWithComments = defaults[Keys.dontDeleteStudiesWithComments]
        deletesLinkedOriginals = defaults[Keys.autoCleanDeletesOriginals]
        spaceRuleEnabled = defaults[Keys.autoCleanBySpace]
        spaceSizeSetting = (defaults[Keys.autoCleanSpaceSize] as NSString?)?.doubleValue ?? 0
        // A number or its text says the order; nothing stored is the first
        // order, and a value of any other kind none.
        switch defaults[Keys.autocleanSpaceMode.reading(as: PropertyListValue?.self)] {
        case nil: spaceMode = 0
        case .string(let text)?: spaceMode = (text as NSString).intValue
        case .integer(let number)?: spaceMode = Int32(truncatingIfNeeded: number)
        case .real(let number)?: spaceMode = NSNumber(value: number).int32Value
        case .boolean(let flag)?: spaceMode = flag ? 1 : 0
        default: spaceMode = nil
        }
        spaceModeSetting = defaults[Keys.autocleanSpaceMode]
    }

    /// Whether every retention period is more than one day. Otherwise the
    /// scheduled cleanup does nothing at all.
    public var retentionPeriodsAreValid: Bool {
        logRetentionDays > 1 && producedRetentionDays > 1 && openedRetentionDays > 1
    }

    /// Whether the date rule runs: it is on, with at least one of its conditions.
    public var runsDateRule: Bool {
        dateRuleEnabled && (usesDateProduced || usesDateOpened)
    }
}

/// What the rules could not decide. Nothing is deleted by the rule that throws.
public enum AutoCleanupPolicyError: Error, Equatable {
    /// The date rule filters by comment, and no text is stored to look for.
    case missingCommentFilterText
    /// The stored order of the space rule is neither a number nor a string.
    case unreadableSpaceMode
}

/// What the free space of the database's volume asks of the space rule.
public enum SpaceCleanupTrigger: Equatable, Sendable {
    /// Enough space, and not near the limit.
    case enough
    /// Enough space, within 20% of the limit: time to warn, not to delete.
    case limitSoonReached
    /// Not enough space: delete.
    case clean
}

/// What the automatic cleanup deletes: the rules, on rows of values. Whoever
/// calls reads the rows and the preferences first, and deletes what comes back.
public enum AutoCleanupPolicy {
    /// At most this many studies are deleted per rule and per pass.
    public static let maximumStudiesPerRule = 50

    /// How long after it was added the date rule leaves a study alone.
    private static let dateRuleGrace: TimeInterval = 60 * 60 * 7 * 24
    /// How long after it was added the space rule leaves a study alone.
    private static let spaceRuleGrace: TimeInterval = 7200

    // MARK: Date rule

    /// The studies the date rule deletes, in order, at most
    /// `maximumStudiesPerRule`. Studies of a patient are judged together: the
    /// latest date of any of them decides for all of them. A study with no
    /// patient UID is judged alone, and a patient stays while one of its studies
    /// lacks a date the rule reads, whatever the order they were read in.
    public static func dateCandidates(in rows: [CleanupStudyRow], preferences: AutoCleanupPreferences, now: Date) throws -> [CleanupStudyRow] {
        // The former int arithmetic: -days*60*60*24, then converted to seconds.
        let producedDate = now.addingTimeInterval(TimeInterval((0 &- preferences.producedDays) &* 60 &* 60 &* 24))
        let openedDate = now.addingTimeInterval(TimeInterval((0 &- preferences.openedDays) &* 60 &* 60 &* 24))

        let studies = sortedByPatientUID(rows)
        var eligible: [CleanupStudyRow] = []
        var i = 0
        while i < studies.count {
            let patientUID = studies[i].patientUID
            let from = i

            while i < studies.count - 1 && isSamePatient(patientUID, studies[i + 1].patientUID) {
                i += 1
            }

            let group = studies[from...i]
            var dateProduced = true, dateOpened = true
            if preferences.usesDateProduced {
                dateProduced = isLater(producedDate, than: latestDate(of: group) { $0.date })
            }
            if preferences.usesDateOpened {
                dateOpened = isLater(openedDate, than: latestDate(of: group) { $0.dateOpened ?? $0.dateAdded })
            }

            if dateProduced && dateOpened {
                eligible += group.filter { study in
                    if study.isLocked { return false }
                    if preferences.keepsStudiesWithComments && study.hasComments { return false }
                    return true
                }
            }
            i += 1
        }

        // Studies in an album or added this week stay, whatever the preferences
        // say: there is no setting that lets the cleanup delete a study in an
        // album. A study with no date added counts as added now.
        var candidates = eligible.filter { study in
            !study.isInAlbum && (study.dateAdded?.timeIntervalSince(now) ?? 0) <= -dateRuleGrace
        }

        if preferences.commentFilterEnabled {
            candidates = try candidates.filter { study in
                guard let text = preferences.commentFilterText else { throw AutoCleanupPolicyError.missingCommentFilterText }
                let found = ((study.comment ?? "") as NSString).range(of: text, options: .caseInsensitive).location != NSNotFound
                return found ? preferences.commentFilterMode != 1 : preferences.commentFilterMode != 0
            }
        }

        return Array(candidates.prefix(maximumStudiesPerRule))
    }

    /// By `patientOrder`, no UID first, and the order they came in otherwise,
    /// so that all the studies of a patient are next to each other: the groups
    /// only look at the next study, and another UID may sort between two
    /// spellings of one patient under any stricter comparison.
    private static func sortedByPatientUID(_ rows: [CleanupStudyRow]) -> [CleanupStudyRow] {
        rows.enumerated().sorted { a, b in
            switch (a.element.patientUID, b.element.patientUID) {
            case let (uidA?, uidB?):
                let order = patientOrder(uidA, uidB)
                return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
            case (nil, nil): return a.offset < b.offset
            case (nil, _?): return true
            case (_?, nil): return false
            }
        }.map { $0.element }
    }

    /// How two UIDs compare, for the order of the studies and for their groups.
    private static func patientOrder(_ patientUID: String, _ other: String) -> ComparisonResult {
        (patientUID as NSString).compare(other, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
    }

    /// The latest `date` of `group`, or nil when one of its studies has none. A
    /// study with no date never goes on its own, and the date of the others says
    /// nothing about it, so its patient stays. Skipping it instead would delete
    /// it on those dates, and only when the order had put a dated study first.
    private static func latestDate(of group: ArraySlice<CleanupStudyRow>, _ date: (CleanupStudyRow) -> Date?) -> Date? {
        let dates = group.compactMap(date)
        return dates.count == group.count ? dates.max() : nil
    }

    /// A study with no UID says nothing about whose it is, so it is a patient
    /// of its own: its dates decide for it alone, and no other study joins it,
    /// another with no UID included. An empty UID is an identifier like any
    /// other.
    private static func isSamePatient(_ patientUID: String?, _ other: String?) -> Bool {
        guard let patientUID, let other else { return false }
        return patientOrder(patientUID, other) == .orderedSame
    }

    /// `date` is after `other`, which is false when `other` is nil.
    private static func isLater(_ date: Date, than other: Date?) -> Bool {
        guard let other = other else { return false }
        return date > other
    }

    // MARK: Space rule

    /// What the space rule may delete, and whether it left out a study only
    /// because it was just added.
    public struct SpaceCandidates: Equatable, Sendable {
        /// The studies it may delete, in the order it deletes them. The rule
        /// stops as soon as there is enough space.
        public let rows: [CleanupStudyRow]
        /// A study was left out only because it was added in the last two hours.
        public let leftOutRecentlyAdded: Bool
    }

    /// The studies the space rule may delete: oldest date first, for the date
    /// `preferences.spaceMode` chooses, and those without one last, in the
    /// order they came.
    public static func spaceCandidates(in rows: [CleanupStudyRow], preferences: AutoCleanupPreferences, now: Date) throws -> SpaceCandidates {
        guard let mode = preferences.spaceMode else { throw AutoCleanupPolicyError.unreadableSpaceMode }

        var leftOutRecentlyAdded = false
        var dated: [(row: CleanupStudyRow, date: Date?, position: Int)] = []
        for study in rows {
            if study.isLocked { continue }
            if preferences.keepsStudiesWithComments && study.hasComments { continue }
            // Like the date rule, never a study in an album.
            if study.isInAlbum { continue }
            // A study with no date added counts as added now.
            if (study.dateAdded?.timeIntervalSince(now) ?? 0) > -spaceRuleGrace {
                leftOutRecentlyAdded = true
                continue
            }
            dated.append((study, priorityDate(of: study, mode: mode), dated.count))
        }

        // Never an order where a study without a date equals every dated one:
        // those are not equal to each other, and the sort could then leave a
        // recent study ahead of an older one.
        dated.sort { a, b in
            switch (a.date, b.date) {
            case let (dateA?, dateB?): return dateA == dateB ? a.position < b.position : dateA < dateB
            case (nil, nil): return a.position < b.position
            case (_?, nil): return true
            case (nil, _?): return false
            }
        }
        return SpaceCandidates(rows: dated.map { $0.row }, leftOutRecentlyAdded: leftOutRecentlyAdded)
    }

    /// The date that orders `study` for the space rule. 0: oldest studies.
    /// 1: oldest unopened. 2: least recently added. Any other mode has none.
    private static func priorityDate(of study: CleanupStudyRow, mode: Int32) -> Date? {
        switch mode {
        case 0: return study.date
        case 1: return study.dateOpened ?? study.dateAdded ?? study.date
        case 2: return study.dateAdded ?? study.date
        default: return nil
        }
    }

    /// The studies the preview lists for the space rule: those the date rule
    /// does not take already, at most `maximumStudiesPerRule`.
    public static func previewSpaceCandidates(_ candidates: [CleanupStudyRow], leaving dateCandidates: [CleanupStudyRow]) -> [CleanupStudyRow] {
        let taken = Set(dateCandidates.map { $0.id })
        return Array(candidates.lazy.filter { !taken.contains($0.id) }.prefix(maximumStudiesPerRule))
    }

    /// The free megabytes the space rule asks for, on a volume of `capacity`
    /// bytes; 0, which never cleans, for a setting that means nothing.
    public static func cleanupThreshold(setting: Double, capacity: UInt64) -> Int {
        let megabytes = setting < 0 ? -setting / 100 * Double(capacity / 1048576) : setting
        if !megabytes.isFinite || megabytes <= 0 || megabytes >= Double(Int.max) { return 0 }
        return Int(megabytes)
    }

    /// What `free` megabytes ask of the space rule when it wants `requested`.
    public static func spaceTrigger(free: UInt64, requested: Int) -> SpaceCleanupTrigger {
        if free < UInt64(bitPattern: Int64(requested)) { return .clean }
        return Double(free) <= Double(requested) * 1.2 ? .limitSoonReached : .enough
    }

    /// Whether the space rule stops, with `free` megabytes now and `deleted`
    /// studies gone. To avoid a huge loop with a very large database, it never
    /// deletes more than `maximumStudiesPerRule`.
    public static func spaceRuleStops(free: UInt64, requested: Int, deleted: Int) -> Bool {
        free >= UInt64(bitPattern: Int64(requested)) || deleted >= maximumStudiesPerRule
    }

    // MARK: Logs

    /// The log entries started on or before this date are deleted.
    public static func logCutoff(preferences: AutoCleanupPreferences, now: Date) -> Date {
        now.addingTimeInterval(TimeInterval(0 &- preferences.logRetentionDays) * 86400.0)
    }
}
