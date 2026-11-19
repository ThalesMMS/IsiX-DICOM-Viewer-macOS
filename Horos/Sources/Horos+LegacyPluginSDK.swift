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
import IsiXDICOMFile

// The calendar helpers of the class in the plugin SDK of Horos and OsiriX,
// which forwarded to NSCalendarDate: a plugin built for that SDK still sends
// them. They answer through the DICOM date type, which kept that arithmetic
// and those formats, and what they answer is a date of that type, which has
// the accessors of a calendar date. The selectors whose first part has no name
// are the SDK's.
extension Horos {
    @objc(dateWithString:calendarFormat:)
    public static func legacyDate(with string: String?, calendarFormat format: String?) -> NSDate? {
        DICOMCalendarDate.date(with: string, calendarFormat: format ?? "")
    }

    @objc(dateWithYear:month:day:hour:minute:second:timeZone:)
    public static func legacyDate(withYear year: Int, month: UInt, day: UInt, hour: UInt, minute: UInt, second: UInt,
                                  timeZone zone: TimeZone?) -> NSDate? {
        DICOMCalendarDate.date(withYear: year, month: month, day: day, hour: hour, minute: minute, second: second, timeZone: zone)
    }

    @objc(:dateByAddingYears:months:days:hours:minutes:seconds:)
    public static func legacyDate(_ date: Date?, byAddingYears years: Int, months: Int, days: Int, hours: Int, minutes: Int,
                                  seconds: Int) -> NSDate? {
        guard let date else { return nil }
        return calendarDate(date).date(byAddingYears: years, months: months, days: days, hours: hours, minutes: minutes,
                                       seconds: seconds) as? NSDate
    }

    @objc(:years:months:days:hours:minutes:seconds:sinceDate:)
    public static func legacyDate(_ date: Date?, years: UnsafeMutablePointer<Int>?, months: UnsafeMutablePointer<Int>?,
                                  days: UnsafeMutablePointer<Int>?, hours: UnsafeMutablePointer<Int>?,
                                  minutes: UnsafeMutablePointer<Int>?, seconds: UnsafeMutablePointer<Int>?, since other: Date?) {
        guard let date, let other else { return }
        calendarDate(date).years(years, months: months, days: days, hours: hours, minutes: minutes, seconds: seconds, since: other)
    }

    @objc(components:fromDate:)
    public static func legacyComponents(_ flags: NSCalendar.Unit, from date: Date?) -> DateComponents? {
        guard let date else { return nil }
        return NSCalendar(calendarIdentifier: .gregorian)?.components(flags, from: date)
    }

    @objc(:descriptionWithCalendarFormat:)
    public static func legacyDescription(_ date: Date?, withCalendarFormat format: String?) -> String? {
        guard let date else { return nil }
        return calendarDate(date).description(withCalendarFormat: format ?? "")
    }

    private static func calendarDate(_ date: Date) -> DICOMCalendarDate {
        DICOMCalendarDate(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate)
    }
}
