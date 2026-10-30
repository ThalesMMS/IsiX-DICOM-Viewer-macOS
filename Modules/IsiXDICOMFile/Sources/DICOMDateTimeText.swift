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

/// A date and a time of day written as DICOM DA and TM values, in the
/// Gregorian calendar of the default time zone, as the exports and reports
/// have always written them: the second that contains the instant, and, for
/// a time, a fraction of six digits.
public enum DICOMDateTimeText {

    private static func formatter(_ pattern: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter
    }

    /// The default time zone, which the app may set apart from the system's.
    public static var defaultTimeZone: TimeZone { NSTimeZone.default }

    /// YYYYMMDD.
    public static func date(_ date: Date, timeZone: TimeZone = defaultTimeZone) -> String {
        let second = Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
        return formatter("yyyyMMdd", timeZone: timeZone).string(from: second)
    }

    /// HHMMSS.FFFFFF. With `fraction` the microseconds of the instant;
    /// without, zeros, as a time read back from its whole seconds has.
    public static func time(_ date: Date, fraction: Bool, timeZone: TimeZone = defaultTimeZone) -> String {
        let interval = date.timeIntervalSinceReferenceDate
        let second = Date(timeIntervalSinceReferenceDate: interval.rounded(.down))
        // llround((interval - floor(interval)) * 1e6) % 1000000.
        let microseconds = fraction
            ? Int64(((interval - interval.rounded(.down)) * 1e6).rounded(.toNearestOrAwayFromZero)) % 1_000_000 : 0
        return formatter("HHmmss", timeZone: timeZone).string(from: second) + String(format: ".%06lld", microseconds)
    }

    /// The date a DA value starts with (YYYYMMDD, anything after it left), at
    /// midnight, as the reports have always read it: the formatter reads from
    /// the start of the text, and a text it reads nothing of (empty, or not a
    /// date) gives its default date, January 1 of the current year.
    public static func parseDate(_ text: String, timeZone: TimeZone = defaultTimeZone) -> Date? {
        let reader = formatter("yyyyMMdd", timeZone: timeZone)
        reader.isLenient = false
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        reader.defaultDate = calendar.date(from: DateComponents(year: calendar.component(.year, from: Date()),
                                                                month: 1, day: 1))
        var value: AnyObject?
        var range = NSRange(location: 0, length: (text as NSString).length)
        do {
            try reader.getObjectValue(&value, for: text, range: &range)
        } catch {
            return nil
        }
        return range.location == 0 ? value as? Date : nil
    }
}
