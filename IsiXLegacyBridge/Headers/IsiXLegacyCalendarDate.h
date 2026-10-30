//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// NSCalendarDate, which macOS deprecated, rebuilt on NSCalendar: a date with a
// time zone and a calendar format, read and written with the legacy
// %-specifiers. The converter (tools/port-legacy-plugin.py) renames
// NSCalendarDate to IsiXLegacyCalendarDate; the methods keep their names.

#ifndef ISIX_LEGACY_CALENDAR_DATE_H
#define ISIX_LEGACY_CALENDAR_DATE_H

#import "IsiXLegacyBridgeDefines.h"

ISIX_LEGACY_CLASS(CalendarDate)
@interface IsiXLegacyCalendarDate : NSDate

/// The current date.
+ (id) calendarDate;
+ (id) dateWithYear: (NSInteger) year month: (NSUInteger) month day: (NSUInteger) day hour: (NSUInteger) hour
             minute: (NSUInteger) minute second: (NSUInteger) second timeZone: (NSTimeZone*) timeZone;
/// nil when `description` does not match `format`.
+ (id) dateWithString: (NSString*) description calendarFormat: (NSString*) format;
+ (id) dateWithString: (NSString*) description calendarFormat: (NSString*) format locale: (id) locale;
/// -[NSDate dateWithCalendarFormat:timeZone:].
+ (id) dateWithDate: (NSDate*) date calendarFormat: (NSString*) format timeZone: (NSTimeZone*) timeZone;
/// -[NSDate descriptionWithCalendarFormat:timeZone:locale:].
+ (NSString*) descriptionOfDate: (NSDate*) date calendarFormat: (NSString*) format timeZone: (NSTimeZone*) timeZone
                         locale: (id) locale;

- (id) initWithYear: (NSInteger) year month: (NSUInteger) month day: (NSUInteger) day hour: (NSUInteger) hour
             minute: (NSUInteger) minute second: (NSUInteger) second timeZone: (NSTimeZone*) timeZone;
- (id) initWithString: (NSString*) description calendarFormat: (NSString*) format;
- (id) initWithString: (NSString*) description calendarFormat: (NSString*) format locale: (id) locale;
/// In the default format, %Y-%m-%d %H:%M:%S %z.
- (id) initWithString: (NSString*) description;

- (NSInteger) yearOfCommonEra;
- (NSInteger) monthOfYear;
- (NSInteger) dayOfMonth;
/// 0 for Sunday to 6 for Saturday.
- (NSInteger) dayOfWeek;
/// 1 to 366.
- (NSInteger) dayOfYear;
- (NSInteger) dayOfCommonEra;
- (NSInteger) hourOfDay;
- (NSInteger) minuteOfHour;
- (NSInteger) secondOfMinute;

/// The time zone the components and descriptions are in; the default time zone when nil.
- (NSTimeZone*) timeZone;
- (void) setTimeZone: (NSTimeZone*) timeZone;
/// The format of -description; %Y-%m-%d %H:%M:%S %z when nil.
- (NSString*) calendarFormat;
- (void) setCalendarFormat: (NSString*) format;

- (NSString*) descriptionWithCalendarFormat: (NSString*) format;
- (NSString*) descriptionWithCalendarFormat: (NSString*) format locale: (id) locale;

- (id) dateByAddingYears: (NSInteger) years months: (NSInteger) months days: (NSInteger) days hours: (NSInteger) hours
                 minutes: (NSInteger) minutes seconds: (NSInteger) seconds;
/// The difference from `date`, in the units whose pointers are not NULL.
- (void) years: (NSInteger*) years months: (NSInteger*) months days: (NSInteger*) days hours: (NSInteger*) hours
       minutes: (NSInteger*) minutes seconds: (NSInteger*) seconds sinceDate: (NSDate*) date;

@end

#endif
