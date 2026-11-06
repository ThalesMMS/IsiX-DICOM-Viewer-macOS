//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Compiled with ARC (-fobjc-arc), whatever the plugin's own setting.

#import "IsiXLegacyCalendarDate.h"

static NSString *const IsiXLegacyDefaultCalendarFormat = @"%Y-%m-%d %H:%M:%S %z";
static const NSCalendarUnit IsiXLegacyDateUnits = NSCalendarUnitEra | NSCalendarUnitYear | NSCalendarUnitMonth |
    NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond | NSCalendarUnitNanosecond |
    NSCalendarUnitWeekday;

static NSCalendar *IsiXLegacyCalendar(NSTimeZone *timeZone)
{
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier: NSCalendarIdentifierGregorian];
    calendar.timeZone = timeZone ?: [NSTimeZone defaultTimeZone];
    return calendar;
}

// The legacy locale argument: an NSLocale, or a dictionary of user defaults
// (which named no locale); the fixed POSIX locale otherwise.
static NSLocale *IsiXLegacyLocale(id locale)
{
    return [locale isKindOfClass: [NSLocale class]] ? locale : [NSLocale localeWithLocaleIdentifier: @"en_US_POSIX"];
}

// %c, %x and %X in the specifiers they stood for.
static NSString *IsiXLegacyExpandedFormat(NSString *format)
{
    format = [format stringByReplacingOccurrencesOfString: @"%%" withString: @"\x01"];
    format = [format stringByReplacingOccurrencesOfString: @"%c" withString: @"%a %b %d %H:%M:%S %Z %Y"];
    format = [format stringByReplacingOccurrencesOfString: @"%x" withString: @"%m/%d/%y"];
    format = [format stringByReplacingOccurrencesOfString: @"%X" withString: @"%H:%M:%S"];
    return [format stringByReplacingOccurrencesOfString: @"\x01" withString: @"%%"];
}

// The date formatter pattern of a legacy calendar format, for reading dates.
static NSString *IsiXLegacyPattern(NSString *format)
{
    NSDictionary<NSString *, NSString *> *fields = @{
        @"a": @"EEE", @"A": @"EEEE", @"b": @"MMM", @"B": @"MMMM", @"d": @"dd", @"e": @"d", @"F": @"SSS",
        @"H": @"HH", @"I": @"hh", @"j": @"DDD", @"m": @"MM", @"M": @"mm", @"p": @"a", @"S": @"ss",
        @"w": @"e", @"y": @"yy", @"Y": @"y", @"Z": @"zzz", @"z": @"Z"
    };
    format = IsiXLegacyExpandedFormat(format);
    NSMutableString *pattern = [NSMutableString string];
    NSMutableString *literal = [NSMutableString string];
    void (^flush)(void) = ^{
        if (literal.length == 0) return;
        [pattern appendFormat: @"'%@'", [literal stringByReplacingOccurrencesOfString: @"'" withString: @"''"]];
        [literal setString: @""];
    };
    for (NSUInteger index = 0; index < format.length; index++) {
        unichar character = [format characterAtIndex: index];
        if (character == '%' && index + 1 < format.length) {
            NSString *specifier = [format substringWithRange: NSMakeRange(++index, 1)];
            NSString *field = fields[specifier];
            if (field) {
                flush();
                [pattern appendString: field];
            } else {
                [literal appendString: specifier];
            }
        } else {
            [literal appendFormat: @"%C", character];
        }
    }
    flush();
    return pattern;
}

// `date` written in a legacy calendar format.
static NSString *IsiXLegacyDescription(NSDate *date, NSString *format, NSTimeZone *timeZone, id locale)
{
    NSCalendar *calendar = IsiXLegacyCalendar(timeZone);
    NSDateComponents *parts = [calendar components: IsiXLegacyDateUnits fromDate: date];
    NSDateFormatter *names = [[NSDateFormatter alloc] init];
    names.locale = IsiXLegacyLocale(locale);
    names.timeZone = calendar.timeZone;
    NSInteger weekday = parts.weekday - 1;
    NSInteger month = parts.month - 1;
    NSInteger hour12 = parts.hour % 12 == 0 ? 12 : parts.hour % 12;
    NSInteger offset = [calendar.timeZone secondsFromGMTForDate: date] / 60;
    format = IsiXLegacyExpandedFormat(format ?: IsiXLegacyDefaultCalendarFormat);
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger index = 0; index < format.length; index++) {
        unichar character = [format characterAtIndex: index];
        if (character != '%' || index + 1 == format.length) {
            [text appendFormat: @"%C", character];
            continue;
        }
        switch ([format characterAtIndex: ++index]) {
            case '%': [text appendString: @"%"]; break;
            case 'a': [text appendString: names.shortWeekdaySymbols[weekday]]; break;
            case 'A': [text appendString: names.weekdaySymbols[weekday]]; break;
            case 'b': [text appendString: names.shortMonthSymbols[month]]; break;
            case 'B': [text appendString: names.monthSymbols[month]]; break;
            case 'd': [text appendFormat: @"%02ld", (long)parts.day]; break;
            case 'e': [text appendFormat: @"%ld", (long)parts.day]; break;
            case 'F': [text appendFormat: @"%03ld", (long)(parts.nanosecond / 1000000)]; break;
            case 'H': [text appendFormat: @"%02ld", (long)parts.hour]; break;
            case 'I': [text appendFormat: @"%02ld", (long)hour12]; break;
            case 'j': [text appendFormat: @"%03ld", (long)[calendar ordinalityOfUnit: NSCalendarUnitDay
                                                                              inUnit: NSCalendarUnitYear
                                                                             forDate: date]]; break;
            case 'm': [text appendFormat: @"%02ld", (long)parts.month]; break;
            case 'M': [text appendFormat: @"%02ld", (long)parts.minute]; break;
            case 'p': [text appendString: parts.hour < 12 ? names.AMSymbol : names.PMSymbol]; break;
            case 'S': [text appendFormat: @"%02ld", (long)parts.second]; break;
            case 'w': [text appendFormat: @"%ld", (long)weekday]; break;
            case 'y': [text appendFormat: @"%02ld", (long)(parts.year % 100)]; break;
            case 'Y': [text appendFormat: @"%ld", (long)parts.year]; break;
            case 'Z': [text appendString: [calendar.timeZone abbreviationForDate: date] ?: calendar.timeZone.name]; break;
            case 'z': [text appendFormat: @"%c%02ld%02ld", offset < 0 ? '-' : '+', (long)(labs(offset) / 60),
                                          (long)(labs(offset) % 60)]; break;
            default: [text appendFormat: @"%%%C", [format characterAtIndex: index]]; break;
        }
    }
    return text;
}

@implementation IsiXLegacyCalendarDate
{
    NSTimeInterval _interval;
    NSTimeZone *_timeZone;
    NSString *_calendarFormat;
}

#pragma mark NSDate

- (id) init
{
    return [self initWithTimeIntervalSinceReferenceDate: [NSDate timeIntervalSinceReferenceDate]];
}

- (id) initWithTimeIntervalSinceReferenceDate: (NSTimeInterval) interval
{
    if ((self = [super init])) _interval = interval;
    return self;
}

- (NSTimeInterval) timeIntervalSinceReferenceDate
{
    return _interval;
}

- (NSString*) description
{
    return IsiXLegacyDescription(self, _calendarFormat, _timeZone, nil);
}

- (NSString*) descriptionWithLocale: (id) locale
{
    return IsiXLegacyDescription(self, _calendarFormat, _timeZone, locale);
}

#pragma mark Creating

+ (id) calendarDate
{
    return [[self alloc] init];
}

+ (id) dateWithYear: (NSInteger) year month: (NSUInteger) month day: (NSUInteger) day hour: (NSUInteger) hour
             minute: (NSUInteger) minute second: (NSUInteger) second timeZone: (NSTimeZone*) timeZone
{
    return [[self alloc] initWithYear: year month: month day: day hour: hour minute: minute second: second
                             timeZone: timeZone];
}

+ (id) dateWithString: (NSString*) description calendarFormat: (NSString*) format
{
    return [[self alloc] initWithString: description calendarFormat: format locale: nil];
}

+ (id) dateWithString: (NSString*) description calendarFormat: (NSString*) format locale: (id) locale
{
    return [[self alloc] initWithString: description calendarFormat: format locale: locale];
}

+ (id) dateWithDate: (NSDate*) date calendarFormat: (NSString*) format timeZone: (NSTimeZone*) timeZone
{
    IsiXLegacyCalendarDate *result = [[self alloc] initWithTimeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate];
    result.calendarFormat = format;
    result.timeZone = timeZone;
    return result;
}

+ (NSString*) descriptionOfDate: (NSDate*) date calendarFormat: (NSString*) format timeZone: (NSTimeZone*) timeZone
                         locale: (id) locale
{
    return IsiXLegacyDescription(date, format, timeZone, locale);
}

- (id) initWithYear: (NSInteger) year month: (NSUInteger) month day: (NSUInteger) day hour: (NSUInteger) hour
             minute: (NSUInteger) minute second: (NSUInteger) second timeZone: (NSTimeZone*) timeZone
{
    NSDateComponents *parts = [[NSDateComponents alloc] init];
    parts.year = year;
    parts.month = month;
    parts.day = day;
    parts.hour = hour;
    parts.minute = minute;
    parts.second = second;
    NSDate *date = [IsiXLegacyCalendar(timeZone) dateFromComponents: parts];
    if ((self = [self initWithTimeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate])) _timeZone = timeZone;
    return self;
}

- (id) initWithString: (NSString*) description calendarFormat: (NSString*) format
{
    return [self initWithString: description calendarFormat: format locale: nil];
}

- (id) initWithString: (NSString*) description
{
    return [self initWithString: description calendarFormat: IsiXLegacyDefaultCalendarFormat locale: nil];
}

- (id) initWithString: (NSString*) description calendarFormat: (NSString*) format locale: (id) locale
{
    NSDateFormatter *reader = [[NSDateFormatter alloc] init];
    reader.locale = IsiXLegacyLocale(locale);
    reader.timeZone = [NSTimeZone defaultTimeZone];
    reader.dateFormat = IsiXLegacyPattern(format ?: IsiXLegacyDefaultCalendarFormat);
    NSDate *date = description ? [reader dateFromString: description] : nil;
    if (date == nil) return nil;
    if ((self = [self initWithTimeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate]))
        _calendarFormat = [format copy];
    return self;
}

#pragma mark Components

- (NSInteger) isixLegacyComponent: (NSCalendarUnit) unit
{
    return [IsiXLegacyCalendar(_timeZone) component: unit fromDate: self];
}

- (NSInteger) yearOfCommonEra { return [self isixLegacyComponent: NSCalendarUnitYear]; }
- (NSInteger) monthOfYear { return [self isixLegacyComponent: NSCalendarUnitMonth]; }
- (NSInteger) dayOfMonth { return [self isixLegacyComponent: NSCalendarUnitDay]; }
- (NSInteger) dayOfWeek { return [self isixLegacyComponent: NSCalendarUnitWeekday] - 1; }
- (NSInteger) hourOfDay { return [self isixLegacyComponent: NSCalendarUnitHour]; }
- (NSInteger) minuteOfHour { return [self isixLegacyComponent: NSCalendarUnitMinute]; }
- (NSInteger) secondOfMinute { return [self isixLegacyComponent: NSCalendarUnitSecond]; }

- (NSInteger) dayOfYear
{
    return [IsiXLegacyCalendar(_timeZone) ordinalityOfUnit: NSCalendarUnitDay inUnit: NSCalendarUnitYear forDate: self];
}

- (NSInteger) dayOfCommonEra
{
    return [IsiXLegacyCalendar(_timeZone) ordinalityOfUnit: NSCalendarUnitDay inUnit: NSCalendarUnitEra forDate: self];
}

#pragma mark Time zone and format

- (NSTimeZone*) timeZone { return _timeZone ?: [NSTimeZone defaultTimeZone]; }
- (void) setTimeZone: (NSTimeZone*) timeZone { _timeZone = timeZone; }
- (NSString*) calendarFormat { return _calendarFormat ?: IsiXLegacyDefaultCalendarFormat; }
- (void) setCalendarFormat: (NSString*) format { _calendarFormat = [format copy]; }

- (NSString*) descriptionWithCalendarFormat: (NSString*) format
{
    return IsiXLegacyDescription(self, format, _timeZone, nil);
}

- (NSString*) descriptionWithCalendarFormat: (NSString*) format locale: (id) locale
{
    return IsiXLegacyDescription(self, format, _timeZone, locale);
}

#pragma mark Arithmetic

- (id) dateByAddingYears: (NSInteger) years months: (NSInteger) months days: (NSInteger) days hours: (NSInteger) hours
                 minutes: (NSInteger) minutes seconds: (NSInteger) seconds
{
    NSDateComponents *parts = [[NSDateComponents alloc] init];
    parts.year = years;
    parts.month = months;
    parts.day = days;
    parts.hour = hours;
    parts.minute = minutes;
    parts.second = seconds;
    NSDate *date = [IsiXLegacyCalendar(_timeZone) dateByAddingComponents: parts toDate: self options: 0];
    IsiXLegacyCalendarDate *result = [[[self class] alloc] initWithTimeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate];
    result->_timeZone = _timeZone;
    result->_calendarFormat = _calendarFormat;
    return result;
}

- (void) years: (NSInteger*) years months: (NSInteger*) months days: (NSInteger*) days hours: (NSInteger*) hours
       minutes: (NSInteger*) minutes seconds: (NSInteger*) seconds sinceDate: (NSDate*) date
{
    NSCalendarUnit units = (years ? NSCalendarUnitYear : 0) | (months ? NSCalendarUnitMonth : 0) |
        (days ? NSCalendarUnitDay : 0) | (hours ? NSCalendarUnitHour : 0) | (minutes ? NSCalendarUnitMinute : 0) |
        (seconds ? NSCalendarUnitSecond : 0);
    NSDateComponents *parts = [IsiXLegacyCalendar(_timeZone) components: units fromDate: date toDate: self options: 0];
    if (years) *years = parts.year;
    if (months) *months = parts.month;
    if (days) *days = parts.day;
    if (hours) *hours = parts.hour;
    if (minutes) *minutes = parts.minute;
    if (seconds) *seconds = parts.second;
}

@end
