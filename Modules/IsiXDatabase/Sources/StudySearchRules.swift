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

/// When the search field also asks the PACS On-Demand nodes.
public enum StudySearchRules {
    /// The tag of the search menu's "Modality" item, which already asks with
    /// two characters.
    public static let modalitySearchType = 5

    /// A search of three characters or more, or two for a modality. `length`
    /// counts UTF-16 code units, as the field's string does.
    public static func queriesDistantNodes(searchLength length: Int, searchType: Int) -> Bool {
        return length > 2 || (length >= 2 && searchType == modalitySearchType)
    }
}
