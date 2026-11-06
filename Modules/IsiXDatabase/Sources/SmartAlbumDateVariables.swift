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

/// The dates a smart album's predicate may name relative to now.
///
/// A smart album is stored as a predicate format. It can name a moment
/// relative to the time it is evaluated in two ways, both kept for the albums
/// already saved: as `$TODAY`, `$WEEK`, ... written into the text, replaced by
/// the number of seconds since the reference date before the format is
/// parsed (`date >= CAST($TODAY, "NSDate")`), and as `$NSDATE_TODAY`, ...
/// substitution variables bound to dates after it is parsed.
///
/// "Today" starts at midnight in `timeZone`; yesterday, two days and a week
/// before are calendar days back from it, so a change of daylight saving time
/// does not shift them. The last hours count back from now, and a month, two,
/// three and a year back count 31, 62, 93 and 365 days of 24 hours from
/// midnight.
public struct SmartAlbumDateVariables: Sendable {
    /// The moment the album is evaluated.
    public let now: Date
    /// Midnight at the start of `now`'s day in the time zone.
    public let today: Date

    private let calendar: Calendar

    public init(now: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.now = now
        let midnight = DateComponents(year: calendar.component(.year, from: now),
                                      month: calendar.component(.month, from: now),
                                      day: calendar.component(.day, from: now),
                                      hour: 0, minute: 0, second: 0)
        // A day the calendar cannot form leaves the reference date, as an
        // absent date answered zero seconds.
        today = calendar.date(from: midnight) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    /// `days` calendar days from midnight, counted in the time zone.
    private func midnight(addingDays days: Int) -> Date {
        let step = DateComponents(year: 0, month: 0, day: days, hour: 0, minute: 0, second: 0)
        return calendar.date(byAdding: step, to: today) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    /// Each placeholder with the date it stands for, in the order they are
    /// replaced. No name is part of another, so the order does not change the
    /// result.
    public var dates: [(name: String, date: Date)] {
        return [
            ("LASTHOUR", now.addingTimeInterval(-60 * 60 * 1)),
            ("LAST6HOURS", now.addingTimeInterval(-60 * 60 * 6)),
            ("LAST12HOURS", now.addingTimeInterval(-60 * 60 * 12)),
            ("TODAY", today),
            ("YESTERDAY", midnight(addingDays: -1)),
            ("2DAYS", midnight(addingDays: -2)),
            ("WEEK", midnight(addingDays: -7)),
            ("MONTH", today.addingTimeInterval(-60 * 60 * 24 * 31)),
            ("2MONTHS", today.addingTimeInterval(-60 * 60 * 24 * 31 * 2)),
            ("3MONTHS", today.addingTimeInterval(-60 * 60 * 24 * 31 * 3)),
            ("YEAR", today.addingTimeInterval(-60 * 60 * 24 * 365)),
        ]
    }

    /// The format with every `$NAME` written as its seconds since the
    /// reference date (`%lf`), matched without regard to case.
    public func expandedFormat(_ format: String) -> String {
        let text = NSMutableString(string: format)
        for (name, date) in dates {
            text.replaceOccurrences(of: "$" + name, with: String(format: "%lf", date.timeIntervalSinceReferenceDate),
                                    options: .caseInsensitive, range: NSRange(location: 0, length: text.length))
        }
        return text as String
    }

    /// The substitution variables, `NSDATE_NAME`, bound to their dates.
    public var substitutionVariables: [String: Any] {
        var variables: [String: Any] = [:]
        for (name, date) in dates {
            variables["NSDATE_" + name] = date
        }
        return variables
    }
}
