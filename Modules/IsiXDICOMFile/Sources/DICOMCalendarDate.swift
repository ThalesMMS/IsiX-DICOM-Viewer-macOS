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

/// What parses DA, TM and DT values into the canonical forms this type reads:
/// "YYYYMMDD", "HHMMSS" and "YYYYMMDDHHMMSS". The app's DCMTK adapter answers
/// it (`HorosDICOMDates`); it is found by name, because no module may link the
/// adapters. A process without it reads the values with the text parser here.
@objc(IsiXDICOMDateParsing)
public protocol DICOMDateParsing: NSObjectProtocol {
    @objc(canonicalDate:) static func canonicalDate(_ value: String) -> String?
    @objc(canonicalTime:microseconds:)
    static func canonicalTime(_ value: String, microseconds: UnsafeMutablePointer<UInt>) -> String?
    @objc(canonicalDateTime:microseconds:timeZoneSeconds:hasTimeZone:)
    static func canonicalDateTime(_ value: String, microseconds: UnsafeMutablePointer<UInt>,
                                  timeZoneSeconds: UnsafeMutablePointer<Int>,
                                  hasTimeZone: UnsafeMutablePointer<ObjCBool>) -> String?
}

/// A DICOM date, time or date-time: an instant, the time zone its wall-clock
/// value is in, the format it was written in, its fraction of a second in
/// microseconds, and, for a query, the range text it stands for.
///
/// It is an `NSDate`, so it goes wherever a date goes (the database, sorting,
/// formatters). The format uses the `%Y %m %d %H %M %S %F %z` tokens the
/// strings below and the callers have always used. Changing the time zone
/// never changes the instant.
///
/// Archived, it keeps the name the app's earlier versions archived it under,
/// `DCMCalendarDate`, and reads those archives (`registerArchiveName()`).
@objc(IsiXDICOMCalendarDate)
public final class DICOMCalendarDate: NSDate, @unchecked Sendable {
    private var referenceInterval: TimeInterval = 0
    private var dicomTimeZone = TimeZone.current as NSTimeZone
    private var dicomCalendarFormat = "%Y-%m-%d %H:%M:%S %z"
    private var fractionalMicroseconds: UInt = 0
    private var query: String?
    private var queryFlag = false

    // MARK: NSDate primitives

    public override var timeIntervalSinceReferenceDate: TimeInterval { referenceInterval }

    public override init(timeIntervalSinceReferenceDate interval: TimeInterval) {
        super.init()
        referenceInterval = interval
        fractionalMicroseconds = UInt(llround((interval - floor(interval)) * 1e6) % 1_000_000)
        dicomTimeZone = NSTimeZone.default as NSTimeZone
    }

    public override convenience init() {
        self.init(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate)
    }

    // MARK: Archiving

    public override var classForCoder: AnyClass { DICOMCalendarDate.self }
    public override class var supportsSecureCoding: Bool { true }

    /// Archives keep the class name `DCMCalendarDate`, and those written before
    /// read as this class. Called once, before anything is archived or read.
    @objc public static func registerArchiveName() {
        NSKeyedArchiver.setClassName("DCMCalendarDate", for: DICOMCalendarDate.self)
        NSKeyedUnarchiver.setClass(DICOMCalendarDate.self, forClassName: "DCMCalendarDate")
    }

    public override func encode(with coder: NSCoder) {
        if coder.allowsKeyedCoding {
            coder.encode(referenceInterval, forKey: "NS.time")
            coder.encode(dicomTimeZone, forKey: "NS.timezone")
            coder.encode(dicomCalendarFormat as NSString, forKey: "NS.format")
            coder.encode(Int(fractionalMicroseconds), forKey: "DCM.microseconds")
            coder.encode(queryFlag, forKey: "DCM.isQuery")
            coder.encode(query as NSString?, forKey: "DCM.queryString")
        } else {
            var interval = referenceInterval
            coder.encodeValue(ofObjCType: "d", at: &interval)
            coder.encode(dicomTimeZone)
            coder.encode(dicomCalendarFormat as NSString)
        }
    }

    public required convenience init?(coder: NSCoder) {
        var interval: TimeInterval = 0
        if coder.allowsKeyedCoding {
            interval = coder.decodeDouble(forKey: "NS.time")
        } else {
            coder.decodeValue(ofObjCType: "d", at: &interval, size: MemoryLayout<TimeInterval>.size)
        }
        self.init(timeIntervalSinceReferenceDate: interval)
        if coder.allowsKeyedCoding {
            setTimeZone(coder.decodeObject(of: NSTimeZone.self, forKey: "NS.timezone") as TimeZone?)
            if let format = coder.decodeObject(of: NSString.self, forKey: "NS.format") { setCalendarFormat(format as String) }
            if coder.containsValue(forKey: "DCM.microseconds") {
                fractionalMicroseconds = UInt(bitPattern: coder.decodeInteger(forKey: "DCM.microseconds"))
            }
            queryFlag = coder.decodeBool(forKey: "DCM.isQuery")
            query = coder.decodeObject(of: NSString.self, forKey: "DCM.queryString") as String?
        } else {
            setTimeZone(coder.decodeObject() as? TimeZone)
            setCalendarFormat(coder.decodeObject() as? String)
        }
    }

    public override func copy(with zone: NSZone? = nil) -> Any {
        let date = DICOMCalendarDate(timeIntervalSinceReferenceDate: referenceInterval)
        date.setTimeZone(dicomTimeZone as TimeZone)
        date.setCalendarFormat(dicomCalendarFormat)
        date.setIsQuery(queryFlag)
        date.setQueryString(query)
        date.fractionalMicroseconds = fractionalMicroseconds
        return date
    }

    // MARK: Making one

    @objc public static func calendarDate() -> DICOMCalendarDate { DICOMCalendarDate() }

    @objc(dateWithString:calendarFormat:)
    public static func date(with string: String?, calendarFormat format: String) -> DICOMCalendarDate? {
        DICOMCalendarDate(string: string, calendarFormat: format)
    }

    @objc(initWithString:calendarFormat:)
    public convenience init?(string: String?, calendarFormat format: String) {
        self.init(string: string, calendarFormat: format, microseconds: 0)
    }

    /// The format is read from the start of the string, and what follows it is
    /// left, as NSCalendarDate did: callers hand in values such as a DICOM time
    /// with its fraction still attached. Every field of the format must be there
    /// and valid. An explicit offset (`%z`) is read first, negative zero hours
    /// included.
    @objc(initWithString:calendarFormat:microseconds:)
    public convenience init?(string: String?, calendarFormat format: String, microseconds: UInt) {
        self.init(timeIntervalSinceReferenceDate: 0)
        let text = (string ?? "") as NSString
        if format.contains("%z") && text.length >= 5 {
            let offset = text.substring(from: text.length - 5) as NSString
            let sign = offset.hasPrefix("-") ? -1 : 1
            let hours = (offset.substring(with: NSRange(location: 1, length: 2)) as NSString).integerValue
            let minutes = (offset.substring(from: 3) as NSString).integerValue
            setTimeZone(TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60)))
        }
        guard let string else { return nil }
        var parsed: AnyObject?
        var range = NSRange(location: 0, length: text.length)
        guard (try? formatter(for: format).getObjectValue(&parsed, for: string, range: &range)) != nil,
              range.location == 0, let date = parsed as? NSDate else { return nil }
        referenceInterval = date.timeIntervalSinceReferenceDate + TimeInterval(microseconds) / 1e6
        fractionalMicroseconds = microseconds % 1_000_000
        setCalendarFormat(format)
    }

    @objc(initWithYear:month:day:hour:minute:second:timeZone:)
    public convenience init?(year: Int, month: UInt, day: UInt, hour: UInt, minute: UInt, second: UInt,
                             timeZone zone: TimeZone?) {
        self.init(timeIntervalSinceReferenceDate: 0)
        setTimeZone(zone)
        var components = DateComponents()
        components.year = year; components.month = Int(month); components.day = Int(day)
        components.hour = Int(hour); components.minute = Int(minute); components.second = Int(second)
        guard let date = dicomCalendar().date(from: components) else { return nil }
        referenceInterval = date.timeIntervalSinceReferenceDate
    }

    @objc(dateWithYear:month:day:hour:minute:second:timeZone:)
    public static func date(withYear year: Int, month: UInt, day: UInt, hour: UInt, minute: UInt, second: UInt,
                            timeZone zone: TimeZone?) -> DICOMCalendarDate? {
        let date = DICOMCalendarDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second,
                                     timeZone: zone)
        date?.setIsQuery(false)
        date?.setQueryString(nil)
        return date
    }

    /// A range or wildcard of a query (anything with a hyphen): only its text.
    @objc(queryDate:)
    public static func queryDate(_ query: String?) -> DICOMCalendarDate {
        let date = DICOMCalendarDate()
        date.setIsQuery(true)
        date.setQueryString(query)
        return date
    }

    // MARK: DICOM values

    private static func parser() -> DICOMDateParsing.Type? {
        NSClassFromString("HorosDICOMDates") as? DICOMDateParsing.Type
    }

    private static func allDigits(_ string: String) -> Bool {
        !string.isEmpty && string.utf16.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// A DA or TM value read whole by the formatter, or nil: "invalid" or
    /// "246000" would otherwise become a time of day the value does not state.
    private static func wholeValue(_ value: String, format: String, microseconds: UInt) -> DICOMCalendarDate? {
        guard let date = DICOMCalendarDate(string: value, calendarFormat: format, microseconds: microseconds) else { return nil }
        return date.description(withCalendarFormat: format) == value ? date : nil
    }

    /// A DA value read without the parser: YYYY, YYYYMM, YYYYMMDD or YYYY.MM.DD.
    private static func readDate(_ string: String) -> DICOMCalendarDate? {
        let date = string.trimmingCharacters(in: .whitespaces)
        let text = date as NSString
        var digits = date
        let format: String
        switch text.length {
        case 4: format = "%Y"
        case 6: format = "%Y%m"
        case 8: format = "%Y%m%d"
        case 10:
            format = "%Y.%m.%d"
            if text.character(at: 4) != 0x2E || text.character(at: 7) != 0x2E { return nil }
            digits = date.replacingOccurrences(of: ".", with: "")
        default: return nil
        }
        guard (digits as NSString).length == min(text.length, 8), allDigits(digits) else { return nil }
        return wholeValue(date, format: format, microseconds: 0)
    }

    /// A TM value read without the parser: HH, HHMM, HHMMSS or HH:MM:SS, the
    /// seconds optionally followed by a fraction of one to six digits. A wrong
    /// time would give, among others, a wrong decay correction for SUV, so a
    /// time that cannot be read entirely is nil.
    private static func readTime(_ string: String) -> DICOMCalendarDate? {
        let time = string.trimmingCharacters(in: .whitespaces)
        let parts = time.components(separatedBy: ".")
        if parts.count > 2 { return nil }
        let whole = parts[0]
        let text = whole as NSString
        var digits = whole
        let format: String
        switch text.length {
        case 2: format = "%H"
        case 4: format = "%H%M"
        case 6: format = "%H%M%S"
        case 8:
            format = "%H:%M:%S"
            if text.character(at: 2) != 0x3A || text.character(at: 5) != 0x3A { return nil }
            digits = whole.replacingOccurrences(of: ":", with: "")
        default: return nil
        }
        guard (digits as NSString).length == min(text.length, 6), allDigits(digits) else { return nil }
        var microseconds: UInt = 0
        if parts.count == 2 {
            let fraction = parts[1]
            // "5" is half a second, so the fraction is padded on the right.
            guard (digits as NSString).length == 6, (fraction as NSString).length <= 6, allDigits(fraction) else { return nil }
            microseconds = UInt((fraction.padding(toLength: 6, withPad: "0", startingAt: 0) as NSString).integerValue)
        }
        return wholeValue(whole, format: format, microseconds: microseconds)
    }

    /// A DA value; a range (with a hyphen) is a query date; a value that does
    /// not start with a non-zero number is nil.
    @objc(dicomDate:)
    public static func dicomDate(_ string: String?) -> DICOMCalendarDate? {
        guard let string else { return nil }
        guard !string.contains("-") else { return queryDate(string) }
        let text = string as NSString
        guard text.intValue != 0 else { return nil }
        var format = "%Y%m%d"
        switch text.length {
        case 10: format = "%Y.%m.%d"
        case 8: format = "%Y%m%d"
        case 6: format = "%Y%m"
        case 4: format = "%Y"
        default: break
        }
        var date: DICOMCalendarDate?
        // The parser reads the full forms; a partial date (YYYY, YYYYMM) is
        // read here. The display format stays the value's shape.
        if let parser = parser(), text.length == 8 || text.length == 10 {
            guard let canonical = parser.canonicalDate(string) else { return nil }
            date = DICOMCalendarDate(string: canonical, calendarFormat: "%Y%m%d", microseconds: 0)
            date?.setCalendarFormat(format)
        } else {
            date = readDate(string)
        }
        date?.setIsQuery(false)
        date?.setQueryString(nil)
        return date
    }

    /// A TM value; a range (with a hyphen) is a query date.
    @objc(dicomTime:)
    public static func dicomTime(_ string: String?) -> DICOMCalendarDate? {
        guard let string else { return nil }
        guard !string.contains("-") else { return queryDate(string) }
        guard !string.isEmpty else { return nil }
        let first = string.components(separatedBy: ".")[0] as NSString
        var format = "%H%M%S"
        if first.length == 8 { format = "%H:%M:%S" }
        if first.length == 6 {
            format = "%H%M%S"
        } else if first.length == 4 {
            format = "%H%M"
        } else if first.length == 2 {
            format = "%H"
        }
        var date: DICOMCalendarDate?
        if let parser = parser() {
            var microseconds: UInt = 0
            guard let canonical = parser.canonicalTime(string, microseconds: &microseconds) else { return nil }
            date = DICOMCalendarDate(string: canonical, calendarFormat: "%H%M%S", microseconds: microseconds)
            date?.setCalendarFormat(format)
        } else {
            date = readTime(string)
        }
        date?.setIsQuery(false)
        date?.setQueryString(nil)
        return date
    }

    /// A DT value, with its fraction and its offset. An offset places the
    /// instant: the digits are read in that zone, not in the local one and then
    /// relabelled.
    @objc(dicomDateTime:)
    public static func dicomDateTime(_ string: String?) -> DICOMCalendarDate? {
        guard let string, !string.isEmpty else { return nil }
        let components = string.components(separatedBy: ".")
        if components.count > 2 { NSLog("****** DICOM DateTime invalid format: %@", string) }
        var format: String
        switch (components[0] as NSString).length {
        case 19: format = "%Y%m%d%H%M%S%z"
        case 14: format = "%Y%m%d%H%M%S"
        case 12: format = "%Y%m%d%H%M"
        case 10: format = "%Y%m%d%H"
        case 8: format = "%Y%m%d"
        case 6: format = "%Y%m"
        case 4: format = "%Y"
        default:
            format = "%Y%m%d%H%M%S"
            NSLog("****** DICOM DateTime invalid format ? %@", string)
        }
        var zone: NSTimeZone?
        var useconds = 0
        if components.count > 1 {
            let tail = components[1] as NSString
            var zoneText: NSString?
            var usecondsText: NSString
            let plus = tail.range(of: "+"), minus = tail.range(of: "-")
            if plus.location != NSNotFound {
                usecondsText = tail.substring(to: plus.location) as NSString
                zoneText = tail.substring(from: plus.location) as NSString
            } else if minus.location != NSNotFound {
                usecondsText = tail.substring(to: minus.location) as NSString
                zoneText = tail.substring(from: minus.location) as NSString
            } else {
                usecondsText = tail
            }
            if let zoneText, zoneText.length > 0 {
                let hours = Int((zoneText.substring(to: 3) as NSString).intValue)
                var minutes = Int((zoneText.substring(from: 3) as NSString).intValue)
                if zoneText.hasPrefix("-") { minutes = -minutes }
                zone = NSTimeZone(forSecondsFromGMT: hours * 3600 + minutes * 60)
            }
            useconds = Int(Double(usecondsText.intValue) * pow(10, Double(6 - usecondsText.length)))
        }
        var date: DICOMCalendarDate?
        if let parser = parser() {
            var microseconds: UInt = 0
            var zoneSeconds = 0
            var stated: ObjCBool = false
            guard let canonical = parser.canonicalDateTime(string, microseconds: &microseconds,
                                                            timeZoneSeconds: &zoneSeconds, hasTimeZone: &stated)
            else { return nil }
            if stated.boolValue {
                let minutes = abs(zoneSeconds) / 60
                let offset = String(format: "%c%02ld%02ld", zoneSeconds < 0 ? 0x2D : 0x2B, minutes / 60, minutes % 60)
                date = DICOMCalendarDate(string: canonical + offset, calendarFormat: "%Y%m%d%H%M%S%z", microseconds: microseconds)
                zone = NSTimeZone(forSecondsFromGMT: zoneSeconds)
            } else {
                date = DICOMCalendarDate(string: canonical, calendarFormat: "%Y%m%d%H%M%S", microseconds: microseconds)
            }
            date?.setCalendarFormat(format)
        } else {
            var digits = components[0]
            if let zone {
                let minutes = abs(zone.secondsFromGMT) / 60
                digits += String(format: "%c%02ld%02ld", zone.secondsFromGMT < 0 ? 0x2D : 0x2B, minutes / 60, minutes % 60)
                format += "%z"
            }
            date = DICOMCalendarDate(string: digits, calendarFormat: format, microseconds: UInt(max(useconds, 0)))
        }
        if let zone { date?.setTimeZone(zone as TimeZone) }
        date?.setIsQuery(false)
        date?.setQueryString(nil)
        return date
    }

    /// The day of `date`, as a DA value.
    @objc(dicomDateWithDate:)
    public static func dicomDate(with date: Date?) -> DICOMCalendarDate? {
        guard let date else { return nil }
        return dicomDate(DICOMCalendarDate(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate).dateString())
    }

    /// The time of day of `date`, to the second, as a TM value.
    @objc(dicomTimeWithDate:)
    public static func dicomTime(with date: Date?) -> DICOMCalendarDate? {
        guard let date else { return nil }
        return dicomTime(DICOMCalendarDate(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate)
            .description(withCalendarFormat: "%H%M%S"))
    }

    /// The day of `date` at the time of day of `time`, in `date`'s zone.
    @objc(dicomDateTimeWithDicomDate:dicomTime:)
    public static func dicomDateTime(withDicomDate date: DICOMCalendarDate?, dicomTime time: DICOMCalendarDate?) -> DICOMCalendarDate? {
        guard let date, let time else { return nil }
        let value = DICOMCalendarDate(year: date.yearOfCommonEra(), month: UInt(date.monthOfYear()),
                                      day: UInt(date.dayOfMonth()), hour: UInt(time.hourOfDay()),
                                      minute: UInt(time.minuteOfHour()), second: UInt(time.secondOfMinute()),
                                      timeZone: date.timeZone())
        value?.setIsQuery(false)
        value?.setQueryString(nil)
        return value
    }

    /// A DA and a TM value together. ACR-NEMA wrote the date as YYYY.MM.DD and
    /// older files the time as HH:MM:SS; no time is noon. The fraction, up to
    /// six digits, is microseconds.
    @objc(dicomDate:time:)
    public static func dicomDate(_ dateString: String?, time timeString: String?) -> DICOMCalendarDate? {
        let blanks = CharacterSet.whitespacesAndNewlines
        var date = (dateString ?? "").trimmingCharacters(in: blanks)
        if (date as NSString).length != 8 { date = date.replacingOccurrences(of: ".", with: "") }
        guard (date as NSString).length == 8, allDigits(date) else { return nil }
        let time = (timeString ?? "").trimmingCharacters(in: blanks).replacingOccurrences(of: ":", with: "")
        if time.isEmpty {
            return DICOMCalendarDate(string: date + "120000", calendarFormat: "%Y%m%d%H%M%S")
        }
        var whole = time
        var fraction: String?
        if let dot = time.range(of: ".") {
            whole = String(time[..<dot.lowerBound])
            var rest = String(time[dot.upperBound...])
            if (rest as NSString).length > 6 { rest = (rest as NSString).substring(to: 6) }
            if !rest.isEmpty && !allDigits(rest) { return nil }
            fraction = rest
        }
        guard allDigits(whole) else { return nil }
        let format: String
        switch (whole as NSString).length {
        case 6: format = "%Y%m%d%H%M%S"
        case 4: format = "%Y%m%d%H%M"
        case 2: format = "%Y%m%d%H"
        default: return nil
        }
        var microseconds: UInt = 0
        if let fraction, !fraction.isEmpty {
            microseconds = UInt((fraction.padding(toLength: 6, withPad: "0", startingAt: 0) as NSString).integerValue)
        }
        return DICOMCalendarDate(string: date + whole, calendarFormat: format, microseconds: microseconds)
    }

    // MARK: Calendar

    private func dicomCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = dicomTimeZone as TimeZone
        return calendar
    }

    private static let tokens: [Character: String] = [
        "Y": "yyyy", "y": "yy", "m": "MM", "d": "dd", "e": "d", "H": "HH", "M": "mm", "S": "ss", "F": "SSS",
        "z": "xx", "Z": "zzz", "a": "EEE", "A": "EEEE", "b": "MMM", "B": "MMMM", "I": "hh", "p": "a", "j": "DDD",
    ]

    /// A formatter for a `%` format, its literals quoted so that ICU does not
    /// read letters in them: Gregorian, POSIX, in this value's time zone.
    @objc(formatterForCalendarFormat:)
    public func formatter(for format: String) -> DateFormatter {
        var pattern = ""
        let characters = Array(format)
        var index = 0
        while index < characters.count {
            var character = characters[index]
            if character == "%" && index + 1 < characters.count {
                index += 1
                let token = characters[index]
                if let mapped = Self.tokens[token] {
                    pattern += mapped
                    index += 1
                    continue
                }
                character = token
            }
            pattern += "'" + String(character).replacingOccurrences(of: "'", with: "''") + "'"
            index += 1
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = dicomCalendar()
        formatter.timeZone = dicomTimeZone as TimeZone
        formatter.dateFormat = pattern
        formatter.isLenient = false
        var defaults = DateComponents()
        defaults.year = dicomCalendar().component(.year, from: Date())
        defaults.month = 1
        defaults.day = 1
        formatter.defaultDate = dicomCalendar().date(from: defaults)
        return formatter
    }

    @objc public func timeZone() -> TimeZone! { dicomTimeZone as TimeZone }
    @objc public func setTimeZone(_ zone: TimeZone?) { dicomTimeZone = (zone ?? NSTimeZone.default) as NSTimeZone }
    @objc public func calendarFormat() -> String { dicomCalendarFormat }
    @objc public func setCalendarFormat(_ format: String?) { dicomCalendarFormat = format ?? "" }

    @objc public func yearOfCommonEra() -> Int { dicomCalendar().component(.year, from: self as Date) }
    @objc public func monthOfYear() -> Int { dicomCalendar().component(.month, from: self as Date) }
    @objc public func dayOfMonth() -> Int { dicomCalendar().component(.day, from: self as Date) }
    @objc public func hourOfDay() -> Int { dicomCalendar().component(.hour, from: self as Date) }
    @objc public func minuteOfHour() -> Int { dicomCalendar().component(.minute, from: self as Date) }
    @objc public func secondOfMinute() -> Int { dicomCalendar().component(.second, from: self as Date) }
    @objc public func dayOfWeek() -> Int { dicomCalendar().component(.weekday, from: self as Date) - 1 }
    @objc public func dayOfYear() -> Int { dicomCalendar().ordinality(of: .day, in: .year, for: self as Date) ?? 0 }

    /// The value in a `%` format. Without `%F` the second is the one that
    /// contains the instant, never rounded up, as DICOM writes it.
    @objc(descriptionWithCalendarFormat:)
    public func description(withCalendarFormat format: String) -> String {
        let value = format.contains("%F") ? self as Date : Date(timeIntervalSinceReferenceDate: floor(referenceInterval))
        return formatter(for: format).string(from: value)
    }

    @objc(dateByAddingYears:months:days:hours:minutes:seconds:)
    public func date(byAddingYears years: Int, months: Int, days: Int, hours: Int, minutes: Int, seconds: Int) -> Any! {
        var components = DateComponents()
        components.year = years; components.month = months; components.day = days
        components.hour = hours; components.minute = minutes; components.second = seconds
        let sum = dicomCalendar().date(byAdding: components, to: self as Date) ?? self as Date
        let date = DICOMCalendarDate(timeIntervalSinceReferenceDate: sum.timeIntervalSinceReferenceDate)
        date.setTimeZone(dicomTimeZone as TimeZone)
        date.setCalendarFormat(dicomCalendarFormat)
        date.fractionalMicroseconds = fractionalMicroseconds
        return date
    }

    @objc(years:months:days:hours:minutes:seconds:sinceDate:)
    public func years(_ years: UnsafeMutablePointer<Int>?, months: UnsafeMutablePointer<Int>?,
                           days: UnsafeMutablePointer<Int>?, hours: UnsafeMutablePointer<Int>?,
                           minutes: UnsafeMutablePointer<Int>?, seconds: UnsafeMutablePointer<Int>?,
                           since date: Date) {
        var units = Set<Calendar.Component>()
        if years != nil { units.insert(.year) }
        if months != nil { units.insert(.month) }
        if days != nil { units.insert(.day) }
        if hours != nil { units.insert(.hour) }
        if minutes != nil { units.insert(.minute) }
        if seconds != nil { units.insert(.second) }
        let delta = dicomCalendar().dateComponents(units, from: date, to: self as Date)
        years?.pointee = delta.year ?? 0
        months?.pointee = delta.month ?? 0
        days?.pointee = delta.day ?? 0
        hours?.pointee = delta.hour ?? 0
        minutes?.pointee = delta.minute ?? 0
        seconds?.pointee = delta.second ?? 0
    }

    // MARK: Strings

    /// A date in a fixed wire or file format (`%Y%m%d`...), Gregorian and
    /// POSIX whatever the user's settings, in the date's own time zone when it
    /// has one and the default one otherwise. Nil for what is not a date.
    @objc(stringFromDate:calendarFormat:)
    public static func string(from date: Any?, calendarFormat format: String) -> String? {
        guard let date = date as? NSDate else { return nil }
        let value = DICOMCalendarDate(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate)
        let selector = NSSelectorFromString("timeZone")
        let zone = date.responds(to: selector) ? date.perform(selector)?.takeUnretainedValue() as? NSTimeZone : nil
        value.setTimeZone((zone ?? NSTimeZone.default as NSTimeZone) as TimeZone)
        return value.description(withCalendarFormat: format)
    }

    /// YYYYMMDD, or the query's text.
    @objc public func dateString() -> String! {
        if queryFlag { return query }
        return description(withCalendarFormat: "%Y%m%d")
    }

    /// HHMMSS.FFF, or the query's text.
    @objc public func timeStringWithMilliseconds() -> String! {
        if queryFlag { return query }
        return description(withCalendarFormat: "%H%M%S") + String(format: ".%03lu", fractionalMicroseconds / 1000)
    }

    /// HHMMSS.FFFFFF, or the query's text.
    @objc public func timeString() -> String! {
        if queryFlag { return query }
        return description(withCalendarFormat: "%H%M%S") + String(format: ".%06lu", fractionalMicroseconds)
    }

    /// YYYYMMDDHHMMSS.FFFFFF, with the offset when asked, or the query's text.
    @objc(dateTimeString:)
    public func dateTimeString(_ withTimeZone: Bool) -> String! {
        if queryFlag { return query }
        let time = description(withCalendarFormat: "%Y%m%d%H%M%S") + String(format: ".%06lu", fractionalMicroseconds)
        return withTimeZone ? time + description(withCalendarFormat: "%z") : time
    }

    @objc public func dateAsNumber() -> NSNumber { NSNumber(value: ((dateString() ?? "") as NSString).intValue) }
    @objc public func timeAsNumber() -> NSNumber { NSNumber(value: Int32(((timeString() ?? "") as NSString).floatValue)) }

    /// Whether this is a query's range or wildcard rather than a value.
    @objc public func isQuery() -> Bool { queryFlag }
    @objc public func setIsQuery(_ value: Bool) { queryFlag = value }
    /// The query's text.
    @objc public func queryString() -> String? { query }
    @objc public func setQueryString(_ value: String?) { query = value }

    private var isTimeFormat: Bool { ["%H:%M:%S", "%H%M%S", "%H%M", "%H"].contains(dicomCalendarFormat) }

    public override var description: String {
        if queryFlag { return query ?? "" }
        if isTimeFormat { return timeString() ?? "" }
        return description(withCalendarFormat: dicomCalendarFormat)
    }

    public override func description(with locale: Any?) -> String { description }
}
