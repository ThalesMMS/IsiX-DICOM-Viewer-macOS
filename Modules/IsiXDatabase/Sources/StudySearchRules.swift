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

/// The browser's time interval filter: the study dates it keeps.
///
/// The interval is chosen by the tag of an item of the time interval menu,
/// stored in the browser's `timeIntervalType`. The presets keep every study
/// from a moment until now; the custom interval comes from its own panel.
public enum StudyDateInterval {
    /// What a tag does to the interval in force.
    public enum Change: Equatable, Sendable {
        /// No interval: every date.
        case clear
        /// Studies from this moment on, with no end.
        case since(Date)
        /// The custom interval's panel gives both ends.
        case custom
        /// A tag the menu does not have leaves the interval as it was.
        case unchanged
    }

    public static let none = 0, lastHour = 1, last6Hours = 2, last12Hours = 3, today = 4,
                      lastWeek = 5, lastMonth = 6, last24Hours = 7, last48Hours = 8, custom = 100

    /// The interval for `tag` at `now`. Today starts at midnight in
    /// `timeZone`; a week and a month back are calendar steps in it.
    public static func change(forTag tag: Int, now: Date, timeZone: TimeZone) -> Change {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // A start computed from a moment, then taken back to now: the offset
        // from now, as the interval was always stored.
        func back(to start: Date?) -> Change {
            let offset = start.map { $0.timeIntervalSinceReferenceDate - now.timeIntervalSinceReferenceDate } ?? 0
            return .since(Date(timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate + offset))
        }
        func step(_ components: DateComponents) -> Date {
            let sum = calendar.date(byAdding: components, to: now)
            return sum ?? Date(timeIntervalSinceReferenceDate: 0)
        }

        switch tag {
        case none:
            return .clear
        case lastHour:
            return .since(now.addingTimeInterval(-60 * 60))
        case last6Hours:
            return .since(now.addingTimeInterval(-60 * 60 * 6))
        case last12Hours:
            return .since(now.addingTimeInterval(-60 * 60 * 12))
        case last24Hours:
            return .since(now.addingTimeInterval(-60 * 60 * 24))
        case last48Hours:
            return .since(now.addingTimeInterval(-60 * 60 * 48))
        case today:
            let midnight = DateComponents(year: calendar.component(.year, from: now),
                                          month: calendar.component(.month, from: now),
                                          day: calendar.component(.day, from: now),
                                          hour: 0, minute: 0, second: 0)
            return back(to: calendar.date(from: midnight))
        case lastWeek:
            return back(to: step(DateComponents(year: 0, month: 0, day: -7, hour: 0, minute: 0, second: 0)))
        case lastMonth:
            return back(to: step(DateComponents(year: 0, month: -1, day: 0, hour: 0, minute: 0, second: 0)))
        case custom:
            return .custom
        default:
            return .unchanged
        }
    }

    /// Whether the PACS On-Demand nodes must be asked again for an interval:
    /// the start differs from the one last asked (an interval without a start
    /// always does), or it has an end that differs from the last one asked.
    public static func needsDistantQuery(start: Date?, end: Date?, askedStart: Date?, askedEnd: Date?) -> Bool {
        let sameStart = start != nil && askedStart != nil && start == askedStart
        if sameStart == false { return true }
        if let end, (askedEnd == nil || end != askedEnd) { return true }
        return false
    }
}

/// What the browser's search field searches, the predicate of the study list
/// it makes, and when it also asks the PACS On-Demand nodes.
public enum StudySearchRules {
    /// The tag of the search menu's "Modality" item, which already asks with
    /// two characters.
    public static let modalitySearchType = 5

    /// A search of three characters or more, or two for a modality. `length`
    /// counts UTF-16 code units, as the field's string does.
    public static func queriesDistantNodes(searchLength length: Int, searchType: Int) -> Bool {
        return length > 2 || (length >= 2 && searchType == modalitySearchType)
    }

    /// The items of the search field's menu, by their tag (the browser's
    /// `searchType`, saved as the "searchType" preference).
    public enum Field: Int, Sendable, CaseIterable {
        case patientName = 0
        case patientID = 1
        case studyID = 2
        case comments = 3
        case studyDescription = 4
        case modality = 5
        case accessionNumber = 6
        case allFields = 7
        case comments2 = 8
        case comments3 = 9
        case comments4 = 10
        case seriesDescription = 11
        /// The advanced search makes its predicate elsewhere.
        case advanced = 100
    }

    /// The field a search of `searchType` looks in for a string the field
    /// holds: nil without a string (no UTF-16 code unit) or for a tag the menu
    /// does not have.
    public static func field(searchType: Int, searchString: String?) -> Field? {
        guard let searchString, (searchString as NSString).length > 0 else { return nil }
        return Field(rawValue: searchType)
    }

    /// The study attribute that holds the string, in any case and with any
    /// diacritics, for the fields that compare one attribute.
    static func attribute(of field: Field) -> String? {
        switch field {
        case .patientID: return "patientID"
        case .studyID: return "id"
        case .comments: return "comment"
        case .studyDescription: return "studyName"
        // A Core Data relationship: the studies with a matching series, which
        // the list shows whole.
        case .seriesDescription: return "ANY series.name"
        case .modality: return "modality"
        case .accessionNumber: return "accessionNumber"
        case .comments2: return "comment2"
        case .comments3: return "comment3"
        case .comments4: return "comment4"
        case .patientName, .allFields, .advanced: return nil
        }
    }

    /// The attributes "All fields" looks in, once its string has three
    /// characters.
    static let allFieldsAttributes = ["name", "patientID", "id", "comment", "comment2", "comment3", "comment4", "studyName",
                                      "modality", "accessionNumber", "performingPhysician", "referringPhysician",
                                      "institutionName", "note"]

    /// The predicate of the study list for the search field's string, nil
    /// for none (no string, the advanced search, a tag the menu does not
    /// have). The patient's name is matched by `namePredicate`, which knows
    /// the names that sound alike; "All fields" matches only the name with
    /// fewer than three characters.
    public static func filterPredicate(searchString: String?, searchType: Int,
                                       namePredicate: (String) -> NSPredicate?) -> NSPredicate? {
        guard let searchString, let field = field(searchType: searchType, searchString: searchString) else { return nil }
        let string = searchString as NSString
        switch field {
        case .patientName:
            return namePredicate(searchString)
        case .allFields:
            guard string.length >= 3 else { return namePredicate(searchString) }
            let format = allFieldsAttributes.map { "(\($0) CONTAINS[cd] %@)" }.joined(separator: " OR ")
            return NSPredicate(format: format, argumentArray: Array(repeating: string, count: allFieldsAttributes.count))
        case .advanced:
            return nil
        default:
            guard let attribute = attribute(of: field) else { return nil }
            return NSPredicate(format: attribute + " CONTAINS[cd] %@", string)
        }
    }

    /// Whether the field's text is drawn in the colour of its background: the
    /// patient's name is searched while the names are hidden.
    public static func hidesSearchText(searchType: Int, hidePatientName: Bool) -> Bool {
        searchType == Field.patientName.rawValue && hidePatientName
    }
}
