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
/*ISO8601DateFormatter.m
 *
 *Created by Peter Hosey on 2009-04-11.
 *Copyright 2009 Peter Hosey. All rights reserved.
 */

import Foundation

/// The implementation of ISO8601DateFormatter, declared in
/// ISO8601DateFormatter.h and named LegacyISO8601DateFormatter in Swift: the
/// formatter of the plugin SDK of Horos and OsiriX, which reads an ISO 8601
/// date in any of the forms the standard allows and writes one in the calendar,
/// ordinal or week format.
///
/// Reading follows the SDK's parser step by step (ISO8601LegacyParser, below),
/// with the same loose and strict rules and the same out-parameters. Writing
/// gives the text the SDK's formats describe. Where the SDK's unparser wrote
/// something else, this one keeps to the format: the date and the time are
/// those of the time zone asked for (it wrote the system's, under the other
/// zone's offset), the offset has four digits (it wrote «+100» for +01:00) and
/// the week format has its time (it wrote «(null)»).
@objc @implementation extension LegacyISO8601DateFormatter {
    /// Kept as the Foundation object: the class, being Objective-C for the
    /// runtime, stores no Swift value whose size the system may change.
    private final var storedTimeZone: NSTimeZone?

    var defaultTimeZone: TimeZone! {
        get { storedTimeZone as TimeZone? }
        set { storedTimeZone = newValue as NSTimeZone? }
    }

    var parsesStrictly: Bool = false
    var format: ISO8601DateFormat = ISO8601DateFormat(ISO8601DateFormatCalendar)
    var includeTime: Bool = false
    var timeSeparator: unichar = ISO8601LegacyParser.defaultTimeSeparator

    // MARK: Parsing

    @objc(dateComponentsFromString:)
    func dateComponents(from string: String!) -> DateComponents! {
        dateComponents(from: string, timeZone: nil, range: nil)
    }

    @objc(dateComponentsFromString:timeZone:)
    func dateComponents(from string: String!, timeZone outTimeZone: AutoreleasingUnsafeMutablePointer<NSTimeZone?>!) -> DateComponents! {
        dateComponents(from: string, timeZone: outTimeZone, range: nil)
    }

    /// The components of the date `string` begins with: year, day, hour,
    /// minute and second, with the month for a calendar date and the day
    /// counted from the first of January for an ordinal or a week date. The
    /// time zone the text names, or nil, goes to `outTimeZone`; the part of
    /// the text that was read goes to `outRange`, in bytes of its UTF-8 form,
    /// with the location NSNotFound, and no component set, for a text that is
    /// not a date.
    @objc(dateComponentsFromString:timeZone:range:)
    func dateComponents(from string: String!, timeZone outTimeZone: AutoreleasingUnsafeMutablePointer<NSTimeZone?>!,
                        range outRange: UnsafeMutablePointer<NSRange>!) -> DateComponents! {
        let parsed = parse(string)
        outRange?.pointee = parsed.range
        outTimeZone?.pointee = parsed.timeZone as NSTimeZone?
        return parsed.components
    }

    @objc(dateFromString:)
    func date(from string: String!) -> Date! {
        date(from: string, timeZone: nil, range: nil)
    }

    @objc(dateFromString:timeZone:)
    func date(from string: String!, timeZone outTimeZone: AutoreleasingUnsafeMutablePointer<NSTimeZone?>!) -> Date! {
        date(from: string, timeZone: outTimeZone, range: nil)
    }

    /// The date `string` begins with, in the time zone it names or, when it
    /// names none, the system's; nil for a text that is not a date.
    @objc(dateFromString:timeZone:range:)
    func date(from string: String!, timeZone outTimeZone: AutoreleasingUnsafeMutablePointer<NSTimeZone?>!,
              range outRange: UnsafeMutablePointer<NSRange>!) -> Date! {
        let parsed = parse(string)
        outRange?.pointee = parsed.range
        outTimeZone?.pointee = parsed.timeZone as NSTimeZone?
        return parsed.date
    }

    private final func parse(_ string: String?) -> ISO8601LegacyParser.Result {
        ISO8601LegacyParser.parse(string ?? "", strict: parsesStrictly, timeSeparator: timeSeparator, now: Date())
    }

    public override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let date = parse(string).date
        obj?.pointee = date as NSDate?
        return date != nil
    }

    // MARK: Unparsing

    @objc(stringFromDate:)
    func string(from date: Date!) -> String! {
        string(from: date, timeZone: defaultTimeZone ?? NSTimeZone.default)
    }

    /// `date` as the calendar date, the ordinal date or the week date of
    /// `timeZone`, with the time and the zone's offset when includeTime is set.
    @objc(stringFromDate:timeZone:)
    func string(from date: Date!, timeZone: TimeZone!) -> String! {
        guard let date else { return nil }
        let zone = timeZone ?? defaultTimeZone ?? NSTimeZone.default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let fields = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        var text: String
        switch Int(format) {
        case ISO8601DateFormatCalendar:
            text = String(format: "%04d-%02d-%02d", fields.year ?? 0, fields.month ?? 0, fields.day ?? 0)
        case ISO8601DateFormatOrdinal:
            text = String(format: "%04d-%03d", fields.year ?? 0, calendar.ordinality(of: .day, in: .year, for: date) ?? 0)
        case ISO8601DateFormatWeek:
            // The week of the standard: it begins on Monday, and the first one
            // of a year is the one with that year's first Thursday.
            var weeks = Calendar(identifier: .iso8601)
            weeks.timeZone = zone
            let week = weeks.dateComponents([.yearForWeekOfYear, .weekOfYear, .weekday], from: date)
            let dayOfWeek = ((week.weekday ?? 1) + 5) % 7 + 1
            text = String(format: "%d-W%02d-%02d", week.yearForWeekOfYear ?? 0, week.weekOfYear ?? 0, dayOfWeek)
        default:
            NSException(name: .internalInconsistencyException,
                        reason: "self.format was \(format), not calendar (\(ISO8601DateFormatCalendar)), week (\(ISO8601DateFormatWeek)), or ordinal (\(ISO8601DateFormatOrdinal))",
                        userInfo: nil).raise()
            return nil
        }

        if includeTime {
            let separator = Unicode.Scalar(timeSeparator == 0 ? ISO8601LegacyParser.defaultTimeSeparator : timeSeparator)
                .map(String.init) ?? ":"
            text += String(format: "T%02d", fields.hour ?? 0) + separator + String(format: "%02d", fields.minute ?? 0)
                + separator + String(format: "%02d", fields.second ?? 0)
            let offset = zone.secondsFromGMT(for: date) / 60
            if offset == 0 {
                text += "Z"
            } else {
                text += String(format: "%@%02d%02d", offset < 0 ? "-" : "+", abs(offset) / 60, abs(offset) % 60)
            }
        }
        return text
    }

    public override func string(for obj: Any?) -> String? {
        (obj as? Date).flatMap { string(from: $0) }
    }
}

/// The parser of the SDK's ISO8601DateFormatter, by Peter Hosey: one pass over
/// the UTF-8 bytes of the text, which tells the form of the date by the hyphens
/// it begins with and the digits that follow them.
///
/// Valid ISO 8601 date formats:
///
///     YYYYMMDD  YYYY-MM-DD  YYYY-MM  YYYY  YY (century)
///     YYMMDD  YY-MM-DD  -YYMM  -YY-MM  -YY        (implied century)
///     --MMDD  --MM-DD  --MM                       (implied year)
///     ---DD                                       (implied year and month)
///     YYYYDDD  YYYY-DDD  YYDDD  YY-DDD  -DDD      (ordinal dates)
///     yyyyWwwd  yyyy-Www-d  yyyyWww  yyyy-Www     (week dates)
///     yyWwwd  yy-Www-d  yyWww  yy-Www
///     -yWwwd  -y-Www-d  -yWww  -y-Www             (year of the implied decade)
///     -Wwwd  -Www-d  -Www  -W-d                   (implied year, week)
///
/// then, after a «T» or a space, hh, hh:mm, hh:mm.m or hh:mm:ss and «Z» or an
/// offset. Loose parsing skips the white space before the date and stops at
/// what follows it; strict parsing refuses the first and some of the forms.
struct ISO8601LegacyParser {
    /// ISO8601DefaultTimeSeparatorCharacter: «:».
    static let defaultTimeSeparator: unichar = 0x3A

    struct Result {
        /// What -dateComponentsFromString:timeZone:range: answers; empty for
        /// a text that is not a date.
        var components = DateComponents()
        var timeZone: TimeZone?
        var range = NSRange(location: NSNotFound, length: 0)
        /// The date of the components, in the text's time zone or the system's.
        var date: Date?
    }

    private enum DateSpecification {
        case monthAndDate, week, dateOnly
    }

    /// The text in UTF-8, with the NUL the parser stops at.
    private let bytes: [UInt8]
    private var ch = 0
    private let strict: Bool
    private let timeSep: unichar
    private let nowYear: UInt32
    private let nowMonth: UInt32
    private let nowDay: UInt32

    private var year: UInt32
    // The SDK left the month, or the day, of some forms unset; they are the
    // first here.
    private var monthOrWeek: UInt32 = 1
    private var day: UInt32 = 1
    private var hour: UInt32 = 0
    private var minute = 0.0
    private var second = 0.0
    private var dateSpecification = DateSpecification.monthAndDate
    private var isValidDate: Bool
    private var timeZone: TimeZone?

    static func parse(_ string: String, strict: Bool, timeSeparator: unichar, now: Date) -> Result {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2 // Monday
        var parser = ISO8601LegacyParser(string, strict: strict, timeSeparator: timeSeparator,
                                         now: calendar.dateComponents([.year, .month, .day], from: now))
        return parser.run(calendar: calendar)
    }

    private init(_ string: String, strict: Bool, timeSeparator: unichar, now: DateComponents) {
        bytes = Array(string.utf8) + [0]
        self.strict = strict
        // Strict parsing knows the standard's separator only.
        timeSep = strict ? Self.defaultTimeSeparator : timeSeparator
        nowYear = UInt32(now.year ?? 0)
        nowMonth = UInt32(now.month ?? 1)
        nowDay = UInt32(now.day ?? 1)
        year = nowYear
        isValidDate = !string.isEmpty
    }

    // MARK: Bytes

    private var cur: UInt8 { bytes[ch] }

    private func at(_ offset: Int) -> UInt8 {
        ch + offset < bytes.count ? bytes[ch + offset] : 0
    }

    /// One byte on, never past the NUL that ends the text.
    private mutating func advance(_ count: Int = 1) {
        ch = min(ch + count, bytes.count - 1)
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private static func isLeapYear(_ year: UInt32) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    private static let hyphen = UInt8(ascii: "-")
    private static let weekMark = UInt8(ascii: "W")

    /// All the digits from here, and how many they were.
    private mutating func readSegment() -> (value: UInt32, digits: Int) {
        var value: UInt32 = 0
        var digits = 0
        while Self.isDigit(cur) {
            value = value &* 10 &+ UInt32(cur - 0x30)
            digits += 1
            advance()
        }
        return (value, digits)
    }

    /// Up to four digits from here.
    private mutating func readSegment4Digits() -> (value: UInt32, digits: Int) {
        var value: UInt32 = 0
        var digits = 0
        while digits < 4 && Self.isDigit(cur) {
            value = value * 10 + UInt32(cur - 0x30)
            digits += 1
            advance()
        }
        return (value, digits)
    }

    /// Up to two digits from here; the first byte is passed whatever it is.
    private mutating func readSegment2Digits() -> UInt32 {
        var value: UInt32 = 0
        if Self.isDigit(cur) {
            value += UInt32(cur - 0x30)
        }
        advance()
        if Self.isDigit(cur) {
            value = value * 10 + UInt32(cur - 0x30)
            advance()
        }
        return value
    }

    /// A number with «,» or «.» before its fraction, which strtod would not read.
    private mutating func readDouble() -> Double {
        var whole: UInt32 = 0
        while Self.isDigit(cur) {
            whole = whole &* 10 &+ UInt32(cur - 0x30)
            advance()
        }
        var value = Double(whole)
        if cur == UInt8(ascii: ",") || cur == UInt8(ascii: ".") {
            advance()
            var multiplier = 0.1
            while Self.isDigit(cur) {
                value += Double(cur - 0x30) * multiplier
                multiplier *= 0.1
                advance()
            }
        }
        return value
    }

    // MARK: Date

    private mutating func run(calendar: Calendar) -> Result {
        var range = NSRange(location: 0, length: 0)
        var startOfDate = 0

        if strict && Self.isSpace(cur) {
            isValidDate = false
        } else {
            // Skip leading whitespace.
            while Self.isSpace(cur) {
                advance()
            }
            range.location = ch
            startOfDate = ch

            if cur == UInt8(ascii: "T") {
                // There is no date here, only a time. Set the date to now; then we'll parse the time.
                advance()
                isValidDate = Self.isDigit(cur)
                year = nowYear
                monthOrWeek = nowMonth
                day = nowDay
            } else {
                parseDate()
            }

            if isValidDate {
                parseTime()
            }
        }

        var result = Result()
        result.timeZone = timeZone
        guard isValidDate else { return result }

        range.length = ch - startOfDate
        result.range = range

        var components = DateComponents()
        components.year = Int(year)
        components.day = Int(day)
        components.hour = Int(hour)
        components.minute = Int(minute)
        components.second = Int(second)

        // The day counted from the first of January, for the forms that have no month.
        var dayOfYear: Int?
        switch dateSpecification {
        case .monthAndDate:
            components.month = Int(monthOrWeek)
        case .week:
            // Adapted from <http://personal.ecu.edu/mccartyr/ISOwdALG.txt>.
            // This works by converting the week date into an ordinal date. The
            // days of a first week that belong to December are zero and below.
            let prevYear = Int(year) - 1
            let YY = prevYear % 100
            let C = prevYear - YY
            let G = YY + YY / 4
            let jan1Weekday = (((C / 100) % 4) * 5 + G) % 7 // Monday is 0
            let thursday = 3
            dayOfYear = (8 - jan1Weekday) + (jan1Weekday > thursday ? 7 : 0) + (Int(day) - 1) + 7 * (Int(monthOrWeek) - 2)
            components.day = dayOfYear
        case .dateOnly: // An "ordinal date".
            dayOfYear = Int(day)
        }
        result.components = components

        var zoned = calendar
        if let timeZone {
            zoned.timeZone = timeZone
        }
        if let dayOfYear {
            var first = components
            first.month = 1
            first.day = 1
            result.date = zoned.date(from: first).flatMap { zoned.date(byAdding: .day, value: dayOfYear - 1, to: $0) }
        } else {
            result.date = zoned.date(from: components)
        }
        return result
    }

    private mutating func parseDate() {
        var numLeadingHyphens = 0
        while cur == Self.hyphen {
            numLeadingHyphens += 1
            advance()
        }

        var (segment, numDigits) = readSegment()
        switch numDigits {
        case 0:
            if cur == Self.weekMark {
                if at(1) == Self.hyphen && Self.isDigit(at(2)) && (numLeadingHyphens == 1 || (numLeadingHyphens == 2 && !strict)) {
                    year = nowYear
                    monthOrWeek = 1
                    advance(2)
                    parseDayAfterWeek()
                } else if numLeadingHyphens == 1 {
                    year = nowYear
                    parseWeekAndDay()
                } else {
                    isValidDate = false
                }
            } else {
                isValidDate = false
            }

        case 8: // YYYY MM DD
            if numLeadingHyphens > 0 {
                isValidDate = false
            } else {
                day = segment % 100
                segment /= 100
                monthOrWeek = segment % 100
                year = segment / 100
            }

        case 6: // YYMMDD (implicit century)
            if numLeadingHyphens > 0 {
                isValidDate = false
            } else {
                day = segment % 100
                segment /= 100
                monthOrWeek = segment % 100
                year = nowYear - nowYear % 100 + segment / 100
            }

        case 4:
            switch numLeadingHyphens {
            case 0: // YYYY
                year = segment

                if cur == Self.hyphen { advance() }

                if !Self.isDigit(cur) {
                    if cur == Self.weekMark {
                        parseWeekAndDay()
                    } else {
                        monthOrWeek = 1
                        day = 1
                    }
                } else {
                    (segment, numDigits) = readSegment()
                    switch numDigits {
                    case 4: // MMDD
                        day = segment % 100
                        monthOrWeek = segment / 100

                    case 2: // MM
                        monthOrWeek = segment

                        if cur == Self.hyphen { advance() }
                        day = Self.isDigit(cur) ? readSegment().value : 1

                    case 3: // DDD
                        day = segment % 1000
                        dateSpecification = .dateOnly
                        if strict && day > (Self.isLeapYear(year) ? 366 : 365) {
                            isValidDate = false
                        }

                    default:
                        isValidDate = false
                    }
                }

            case 1: // YYMM
                monthOrWeek = segment % 100
                year = segment / 100

                if cur == Self.hyphen { advance() }
                day = Self.isDigit(cur) ? readSegment().value : 1

            case 2: // MMDD
                day = segment % 100
                monthOrWeek = segment / 100
                year = nowYear

            default:
                isValidDate = false
            }

        case 1 where strict:
            // Two digits only - never just one.
            if numLeadingHyphens == 1 {
                if cur == Self.hyphen { advance() }
                advance()
                if cur == Self.weekMark {
                    year = nowYear - nowYear % 10 + segment
                    parseWeekAndDay()
                } else {
                    isValidDate = false
                }
            } else {
                isValidDate = false
            }

        case 1, 2:
            switch numLeadingHyphens {
            case 0:
                if cur == Self.hyphen {
                    // Implicit century
                    year = nowYear - nowYear % 100 + segment

                    advance()
                    if cur == Self.weekMark {
                        parseWeekAndDay()
                    } else if !Self.isDigit(cur) {
                        centuryOnly(segment)
                    } else {
                        // Get month and/or date.
                        (segment, numDigits) = readSegment4Digits()
                        switch numDigits {
                        case 4: // YY-MMDD
                            day = segment % 100
                            monthOrWeek = segment / 100

                        case 1 where strict: // YY-M; YY-M-DD (extension)
                            isValidDate = false

                        case 1, 2: // YY-MM; YY-MM-DD
                            monthOrWeek = segment
                            if cur == Self.hyphen {
                                advance()
                                day = Self.isDigit(cur) ? readSegment2Digits() : 1
                            } else {
                                day = 1
                            }

                        case 3: // Ordinal date.
                            day = segment
                            dateSpecification = .dateOnly

                        default:
                            break
                        }
                    }
                } else if cur == Self.weekMark {
                    year = nowYear - nowYear % 100 + segment
                    parseWeekAndDay()
                } else {
                    // Century only. Assume current year.
                    centuryOnly(segment)
                }

            case 1: // -YY; -YY-MM (implicit century)
                let yearOfCentury = nowYear % 100
                year = segment + (nowYear - yearOfCentury)
                if numDigits == 1 { // implied decade
                    year += yearOfCentury - (nowYear % 10)
                }

                if cur == Self.hyphen {
                    advance()
                    monthOrWeek = readSegment2Digits()
                }

                day = 1

            case 2: // --MM; --MM-DD
                year = nowYear
                monthOrWeek = segment
                if cur == Self.hyphen {
                    advance()
                    day = readSegment2Digits()
                }

            case 3: // ---DD
                year = nowYear
                monthOrWeek = nowMonth
                day = segment

            default:
                isValidDate = false
            }

        case 7: // YYYY DDD (ordinal date)
            if numLeadingHyphens > 0 {
                isValidDate = false
            } else {
                day = segment % 1000
                year = segment / 1000
                dateSpecification = .dateOnly
                if strict && day > (Self.isLeapYear(year) ? 366 : 365) {
                    isValidDate = false
                }
            }

        case 3: // --DDD (ordinal date, implicit year)
            // Technically, the standard only allows one hyphen. But it says that two hyphens is the logical implementation, and one was dropped for brevity. So I have chosen to allow the missing hyphen.
            if numLeadingHyphens < 1 || (numLeadingHyphens > 2 && !strict) {
                isValidDate = false
            } else {
                day = segment
                year = nowYear
                dateSpecification = .dateOnly
                if strict && day > (Self.isLeapYear(year) ? 366 : 365) {
                    isValidDate = false
                }
            }

        default:
            isValidDate = false
        }
    }

    /// The week and the day of a week date; the byte here is the «W».
    private mutating func parseWeekAndDay() {
        advance()
        if !Self.isDigit(cur) {
            // Not really a week-based date; just a year followed by '-W'.
            if strict {
                isValidDate = false
            } else {
                monthOrWeek = 1
                day = 1
            }
        } else {
            monthOrWeek = readSegment2Digits()
            if cur == Self.hyphen { advance() }
            parseDayAfterWeek()
        }
    }

    private mutating func parseDayAfterWeek() {
        day = Self.isDigit(cur) ? readSegment2Digits() : 1
        dateSpecification = .week
    }

    private mutating func centuryOnly(_ century: UInt32) {
        year = century * 100 + nowYear % 100
        monthOrWeek = 1
        day = 1
    }

    // MARK: Time

    private mutating func parseTime() {
        if Self.isSpace(cur) || cur == UInt8(ascii: "T") { advance() }

        guard Self.isDigit(cur) else { return }

        hour = readSegment2Digits()
        if unichar(cur) == timeSep {
            advance()
            if timeSep == 0x2C || timeSep == 0x2E {
                // We can't do fractional minutes when '.' is the segment separator.
                // Only allow whole minutes and whole seconds.
                minute = Double(readSegment2Digits())
                if unichar(cur) == timeSep {
                    advance()
                    second = Double(readSegment2Digits())
                }
            } else {
                // Allow a fractional minute.
                // If we don't get a fraction, look for a seconds segment.
                // Otherwise, the fraction of a minute is the seconds.
                let minutes = readDouble()
                minute = minutes.rounded(.towardZero)
                second = minutes - minute
                if second > Double.ulpOfOne {
                    second *= 60.0 // Convert fraction (e.g. .5) into seconds (e.g. 30).
                } else if unichar(cur) == timeSep {
                    advance()
                    second = readDouble()
                }
            }
        }

        switch cur {
        case UInt8(ascii: "Z"):
            timeZone = TimeZone(abbreviation: "UTC")

        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            let negative = cur == Self.hyphen
            advance()
            if Self.isDigit(cur) {
                // Read hour offset.
                var segment = Int(cur - 0x30)
                advance()
                if Self.isDigit(cur) {
                    segment = segment * 10 + Int(cur - 0x30)
                    advance()
                }
                let tzHour = negative ? -segment : segment

                // Optional separator.
                if unichar(cur) == timeSep { advance() }

                var tzMinute = 0
                if Self.isDigit(cur) {
                    // Read minute offset. Its last digit is read and not
                    // passed: the range ends before it, as it did.
                    segment = Int(cur - 0x30)
                    advance()
                    if Self.isDigit(cur) {
                        segment = segment * 10 + Int(cur - 0x30)
                    }
                    tzMinute = negative ? -segment : segment
                }

                timeZone = TimeZone(secondsFromGMT: tzHour * 3600 + tzMinute * 60)
            }

        default:
            break
        }
    }
}
