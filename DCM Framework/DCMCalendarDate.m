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

#import "DCMCalendarDate.h"//aTimeZone
#import "DCM.h"

// What the host's HorosDICOMDates answers (#737), found by name at run time.
@protocol DCMHostDates <NSObject>
+ (NSString *)canonicalDate:(NSString *)dicomDate;
+ (NSString *)canonicalTime:(NSString *)dicomTime microseconds:(unsigned long *)microseconds;
+ (NSString *)canonicalDateTime:(NSString *)dicomDateTime microseconds:(unsigned long *)microseconds
                timeZoneSeconds:(NSInteger *)timeZoneSeconds hasTimeZone:(BOOL *)hasTimeZone;
@end

// Only ASCII digits, and at least one.
static BOOL DCMAllDigits(NSString *string)
{
    if (string.length == 0) return NO;
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar c = [string characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return YES;
}

// initWithString: leaves what follows the format unread, and the formatter may
// stop before reading a field at all: "invalid" or "246000" would become a time
// of day the value does not state. A DA or TM value is taken only when the
// format gives it back whole.
static DCMCalendarDate *DCMWholeValue(NSString *value, NSString *format, unsigned long microseconds)
{
    DCMCalendarDate *date = [[[DCMCalendarDate alloc] initWithString:value calendarFormat:format microseconds:microseconds] autorelease];
    return [[date descriptionWithCalendarFormat:format] isEqualToString:value] ? date : nil;
}

// A DA value read without the host: YYYY, YYYYMM, YYYYMMDD or YYYY.MM.DD.
static DCMCalendarDate *DCMReadDate(NSString *string)
{
    NSString *date = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *digits = date, *format = nil;
    switch (date.length) {
        case 4: format = @"%Y"; break;
        case 6: format = @"%Y%m"; break;
        case 8: format = @"%Y%m%d"; break;
        case 10:
            format = @"%Y.%m.%d";
            if ([date characterAtIndex:4] != '.' || [date characterAtIndex:7] != '.') return nil;
            digits = [date stringByReplacingOccurrencesOfString:@"." withString:@""];
            break;
        default: return nil;
    }
    if (digits.length != MIN(date.length, 8) || !DCMAllDigits(digits)) return nil;
    return DCMWholeValue(date, format, 0);
}

// A TM value read without the host: HH, HHMM, HHMMSS or HH:MM:SS, the seconds
// optionally followed by a fraction of one to six digits. A wrong time would
// give, among others, a wrong decay correction for SUV, so a time that cannot
// be read entirely is nil rather than whatever the formatter made of it.
static DCMCalendarDate *DCMReadTime(NSString *string)
{
    NSString *time = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSArray *parts = [time componentsSeparatedByString:@"."];
    if (parts.count > 2) return nil;
    NSString *whole = [parts objectAtIndex:0], *format = nil, *digits = whole;
    switch (whole.length) {
        case 2: format = @"%H"; break;
        case 4: format = @"%H%M"; break;
        case 6: format = @"%H%M%S"; break;
        case 8:
            format = @"%H:%M:%S";
            if ([whole characterAtIndex:2] != ':' || [whole characterAtIndex:5] != ':') return nil;
            digits = [whole stringByReplacingOccurrencesOfString:@":" withString:@""];
            break;
        default: return nil;
    }
    if (digits.length != MIN(whole.length, 6) || !DCMAllDigits(digits)) return nil;
    unsigned long microseconds = 0;
    if (parts.count == 2) {
        NSString *fraction = [parts objectAtIndex:1];
        // "5" is half a second, so the fraction is padded on the right.
        if (digits.length != 6 || fraction.length > 6 || !DCMAllDigits(fraction)) return nil;
        microseconds = (unsigned long) [[fraction stringByPaddingToLength:6 withString:@"0" startingAtIndex:0] integerValue];
    }
    return DCMWholeValue(whole, format, microseconds);
}

@implementation DCMCalendarDate


+ (id)dicomDate:(NSString *)string{

	if( string == nil) 
		return nil;
		
	if ([string rangeOfString:@"-"].location == NSNotFound)
	{
		//format for DA is YYMMDD = @"%Y%m%d"
		if (DCMDEBUG)
			NSLog (@"date string: %@ intValue: %d", string,[string intValue] );
		NSString *format = @"%Y%m%d";
		if (string && [string intValue]) {
			if ([string length] == 10)
				format = @"%Y.%m.%d";
			else if ([string length] == 8)
				format = @"%Y%m%d";
			else if ([string length] == 6)
				format = @"%Y%m";
			else if ([string length] == 4)
				format = @"%Y";
			DCMCalendarDate *date = nil;
			// DCMTK parses the full forms (#737); a partial date (YYYY, YYYYMM)
			// is read as before. The display format stays the value's shape.
			Class<DCMHostDates> host = (Class<DCMHostDates>) NSClassFromString(@"HorosDICOMDates");
			if ([host respondsToSelector: @selector(canonicalDate:)] && ([string length] == 8 || [string length] == 10))
			{
				NSString *canonical = [host canonicalDate: string];
				if (canonical == nil)
					return nil;
				date = [[[DCMCalendarDate alloc] initWithString:canonical calendarFormat:@"%Y%m%d" microseconds: 0] autorelease];
				[date setCalendarFormat: format];
			}
			else
				date = DCMReadDate(string);
			[date setIsQuery:NO];
			[date setQueryString:nil];
			return date;
		}
		else
			return nil;
	}
	else
		return [DCMCalendarDate queryDate:string];
}
+ (id)dicomTime:(NSString *)string
{
	if( string == nil) 
		return nil;
		
	if ([string rangeOfString:@"-"].location == NSNotFound)
	{
		//format for TM is HHMMSS.ffffff = @"%H%M%S.%U";
			if (DCMDEBUG)
			NSLog (@"time string: %@", string);
		if (string.length) {
			NSArray *timeComponents = [string componentsSeparatedByString:@"."];
			NSString *firstComponent = [timeComponents objectAtIndex:0];
			NSString *format = @"%H%M%S";
			if ([firstComponent length] == 8)
				format = @"%H:%M:%S";
			if ([firstComponent length] == 6)
				format = @"%H%M%S";
			else if ([firstComponent length] == 4)
				format = @"%H%M";
			else if ([firstComponent length] == 2)
				format = @"%H";
            
			DCMCalendarDate *date = nil;
			// DCMTK parses the time and its fraction (#737).
			Class<DCMHostDates> host = (Class<DCMHostDates>) NSClassFromString(@"HorosDICOMDates");
			if ([host respondsToSelector: @selector(canonicalTime:microseconds:)])
			{
				unsigned long microseconds = 0;
				NSString *canonical = [host canonicalTime: string microseconds: &microseconds];
				if (canonical == nil)
					return nil;
				date = [[[DCMCalendarDate alloc] initWithString:canonical calendarFormat:@"%H%M%S" microseconds: microseconds] autorelease];
				[date setCalendarFormat: format];
			}
			else
				date = DCMReadTime(string);
			
			[date setIsQuery:NO];
			[date setQueryString:nil];
			return date;
		}
		else
			return nil;
	}
	else
		return [DCMCalendarDate queryDate:string];
}

+ (id)dicomDateTime:(NSString *)string
{
	if( string == nil) 
		return nil;
    
    if (DCMDEBUG)
        NSLog (@"date time string: %@", string);
    
    if (string.length) {
        NSArray *timeComponents = [string componentsSeparatedByString:@"."];
        NSString *format = nil;
//        int length = (int)[string length];
        
        if( timeComponents.count > 2)
            NSLog( @"****** DICOM DateTime invalid format: %@", string);
        
        switch ([(NSString *)[timeComponents objectAtIndex:0] length]) {
            case 19:format = @"%Y%m%d%H%M%S%z";
                break;
            case 14:format = @"%Y%m%d%H%M%S";
                break;
            case 12:format = @"%Y%m%d%H%M";
                break;
            case 10:format = @"%Y%m%d%H";
                break;
            case 8:format = @"%Y%m%d";
                break;
            case 6:format = @"%Y%m";
                break;
            case 4:format = @"%Y";
                break;
                
            default: format = @"%Y%m%d%H%M%S";
                NSLog( @"****** DICOM DateTime invalid format ? %@", string);
                break;
        }
        
        NSTimeZone *tz = nil;
        int useconds = 0;
        if ([timeComponents count] > 1) {
            NSString *timeZone = nil;
            NSString *usecondsString = nil;
            
            if( [[timeComponents objectAtIndex:1] rangeOfString: @"+"].location != NSNotFound)
            {
                usecondsString = [[timeComponents objectAtIndex:1] substringToIndex: [[timeComponents objectAtIndex:1] rangeOfString: @"+"].location];
                timeZone = [[timeComponents objectAtIndex:1] substringFromIndex: [[timeComponents objectAtIndex:1] rangeOfString: @"+"].location];
            }
            else if( [[timeComponents objectAtIndex:1] rangeOfString: @"-"].location != NSNotFound)
            {
                usecondsString = [[timeComponents objectAtIndex:1] substringToIndex: [[timeComponents objectAtIndex:1] rangeOfString: @"-"].location];
                timeZone = [[timeComponents objectAtIndex:1] substringFromIndex: [[timeComponents objectAtIndex:1] rangeOfString: @"-"].location];
            }
            else
            {
                usecondsString = [timeComponents objectAtIndex:1];
                timeZone = nil;
            }
            
            if( timeZone.length) {
                int tzHours = [[timeZone substringToIndex:3] intValue];
                int tzMinutes = [[timeZone substringFromIndex:3] intValue];
                if ([timeZone hasPrefix:@"-"])
                    tzMinutes = -tzMinutes;
                tz = [NSTimeZone timeZoneForSecondsFromGMT:(tzHours * 3600) + (tzMinutes * 60)];
            }
            
            useconds = [usecondsString intValue] * pow(10, 6 - usecondsString.length);
        }
        
        DCMCalendarDate *date = nil;
        // DCMTK parses the value, its fraction and its offset (#737). An
        // offset places the instant: the digits are read in that zone, not in
        // the local one and then relabelled, as the fractional form was before.
        Class<DCMHostDates> host = (Class<DCMHostDates>) NSClassFromString(@"HorosDICOMDates");
        if ([host respondsToSelector: @selector(canonicalDateTime:microseconds:timeZoneSeconds:hasTimeZone:)])
        {
            unsigned long microseconds = 0;
            NSInteger zoneSeconds = 0;
            BOOL stated = NO;
            NSString *canonical = [host canonicalDateTime: string microseconds: &microseconds
                                               timeZoneSeconds: &zoneSeconds hasTimeZone: &stated];
            if (canonical == nil)
                return nil;
            if (stated)
            {
                NSInteger minutes = labs(zoneSeconds) / 60;
                NSString *offset = [NSString stringWithFormat: @"%c%02ld%02ld", zoneSeconds < 0 ? '-' : '+', (long) (minutes / 60), (long) (minutes % 60)];
                date = [[[DCMCalendarDate alloc] initWithString:[canonical stringByAppendingString: offset] calendarFormat:@"%Y%m%d%H%M%S%z" microseconds: microseconds] autorelease];
                tz = [NSTimeZone timeZoneForSecondsFromGMT: zoneSeconds];
            }
            else
                date = [[[DCMCalendarDate alloc] initWithString:canonical calendarFormat:@"%Y%m%d%H%M%S" microseconds: microseconds] autorelease];
            [date setCalendarFormat: format];
        }
        else {
            NSString *digits = [timeComponents objectAtIndex:0];
            if (tz) {
                NSInteger minutes = labs([tz secondsFromGMT]) / 60;
                digits = [digits stringByAppendingFormat:@"%c%02ld%02ld", [tz secondsFromGMT] < 0 ? '-' : '+', (long)(minutes / 60), (long)(minutes % 60)];
                format = [format stringByAppendingString:@"%z"];
            }
            date = [[[DCMCalendarDate alloc] initWithString:digits calendarFormat:format microseconds:useconds] autorelease];
        }
        if( tz)
            [date setTimeZone: tz];
        
        [date setIsQuery:NO];
        [date setQueryString:nil];
        
        return date;
    }
    else
        return nil;
		
}

+ (id)dicomDateWithDate:(NSDate *)date
{
    if (!date) return nil;
    DCMCalendarDate *value = [self dateWithTimeIntervalSinceReferenceDate:date.timeIntervalSinceReferenceDate];
    return [self dicomDate:[value dateString]];
}

+ (id)dicomTimeWithDate:(NSDate *)date
{
    if (!date) return nil;
    DCMCalendarDate *value = [self dateWithTimeIntervalSinceReferenceDate:date.timeIntervalSinceReferenceDate];
    return [self dicomTime:[value descriptionWithCalendarFormat:@"%H%M%S"]];
}

+ (id)dicomDateTimeWithDicomDate:(DCMCalendarDate*)date dicomTime:(DCMCalendarDate*)time
{
	if (date == nil || time == nil)
		return nil;
	
	DCMCalendarDate *dateTime = [[[DCMCalendarDate alloc] initWithYear:[date yearOfCommonEra] month:[date monthOfYear] day:[date dayOfMonth]
				hour:[time hourOfDay] minute:[time minuteOfHour] second:[time secondOfMinute] timeZone:[date timeZone]] autorelease];
	
	[dateTime setIsQuery:NO];
	[dateTime setQueryString:nil];
	return dateTime;
}

+ (id)dicomDate:(NSString *)dateString time:(NSString *)timeString
{
    NSCharacterSet *blanks = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *date = [dateString stringByTrimmingCharactersInSet:blanks];
    // ACR-NEMA wrote the date as YYYY.MM.DD.
    if (date.length != 8) date = [date stringByReplacingOccurrencesOfString:@"." withString:@""];
    if (date.length != 8 || !DCMAllDigits(date)) return nil;

    // Older files wrote the time as HH:MM:SS.
    NSString *time = [[timeString stringByTrimmingCharactersInSet:blanks] stringByReplacingOccurrencesOfString:@":" withString:@""];
    if (time.length == 0)
        return [[[self alloc] initWithString:[date stringByAppendingString:@"120000"] calendarFormat:@"%Y%m%d%H%M%S"] autorelease];

    // TM is HH, HHMM or HHMMSS, the last optionally followed by a fraction of
    // up to six digits. The fraction is kept apart and read as microseconds:
    // "5" is half a second, so it is padded on the right.
    NSString *whole = time, *fraction = nil;
    NSRange dot = [time rangeOfString:@"."];
    if (dot.location != NSNotFound) {
        whole = [time substringToIndex:dot.location];
        fraction = [time substringFromIndex:NSMaxRange(dot)];
        if (fraction.length > 6) fraction = [fraction substringToIndex:6];
        if (fraction.length && !DCMAllDigits(fraction)) return nil;
    }
    if (!DCMAllDigits(whole)) return nil;
    NSString *format = nil;
    switch (whole.length) {
        case 6: format = @"%Y%m%d%H%M%S"; break;
        case 4: format = @"%Y%m%d%H%M"; break;
        case 2: format = @"%Y%m%d%H"; break;
        default: return nil;
    }
    unsigned long microseconds = 0;
    if (fraction.length)
        microseconds = (unsigned long) [[fraction stringByPaddingToLength:6 withString:@"0" startingAtIndex:0] integerValue];
    return [[[self alloc] initWithString:[date stringByAppendingString:whole] calendarFormat:format microseconds:microseconds] autorelease];
}
	
+ (id)queryDate:(NSString *)query{
	DCMCalendarDate *date = [[[DCMCalendarDate alloc] init] autorelease];
	[date setIsQuery:YES];
	[date setQueryString:query];
	return date;
}


+ (id)dateWithYear:(NSInteger)year month:(NSUInteger)month day:(NSUInteger)day hour:(NSUInteger)hour minute:(NSUInteger)minute second:(NSUInteger)second timeZone:(NSTimeZone *)aTimeZone{
	DCMCalendarDate *date = [[[DCMCalendarDate alloc] initWithYear:year month:month day:day hour:hour minute:minute second:second timeZone:aTimeZone] autorelease];
    
	[date setIsQuery:NO];
	[date setQueryString:nil];
	return date;
}

//------------------------------------------------------------------------------------------------------------------------------------
#pragma mark•

// NSDate subclass primitives. The timezone describes the wall-clock DICOM value;
// changing it never changes the represented instant.
- (id)init
{
    return [self initWithTimeIntervalSinceReferenceDate:[NSDate date].timeIntervalSinceReferenceDate];
}

- (id)initWithTimeIntervalSinceReferenceDate:(NSTimeInterval)interval
{
    if ((self = [super init])) {
        referenceInterval = interval;
        fractionalMicroseconds = (unsigned long)llround((interval - floor(interval)) * 1e6) % 1000000;
        dicomTimeZone = [[NSTimeZone defaultTimeZone] retain];
        dicomCalendarFormat = [@"%Y-%m-%d %H:%M:%S %z" copy];
    }
    return self;
}

// Retain the historical keyed archive fields, including timezone and format.
// NSDate's default classForCoder collapses subclasses to NSDate and loses them.
- (Class)classForCoder { return [DCMCalendarDate class]; }
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    if (coder.allowsKeyedCoding) {
        [coder encodeDouble:referenceInterval forKey:@"NS.time"];
        [coder encodeObject:dicomTimeZone forKey:@"NS.timezone"];
        [coder encodeObject:dicomCalendarFormat forKey:@"NS.format"];
        [coder encodeInteger:fractionalMicroseconds forKey:@"DCM.microseconds"];
        [coder encodeBool:isQuery forKey:@"DCM.isQuery"];
        [coder encodeObject:queryString forKey:@"DCM.queryString"];
    } else {
        [coder encodeValueOfObjCType:@encode(NSTimeInterval) at:&referenceInterval];
        [coder encodeObject:dicomTimeZone];
        [coder encodeObject:dicomCalendarFormat];
    }
}
- (id)initWithCoder:(NSCoder *)coder
{
    NSTimeInterval interval = 0;
    if (coder.allowsKeyedCoding)
        interval = [coder decodeDoubleForKey:@"NS.time"];
    else
        [coder decodeValueOfObjCType:@encode(NSTimeInterval) at:&interval size:sizeof(interval)];
    self = [self initWithTimeIntervalSinceReferenceDate:interval];
    if (!self) return nil;
    if (coder.allowsKeyedCoding) {
        [self setTimeZone:[coder decodeObjectOfClass:[NSTimeZone class] forKey:@"NS.timezone"]];
        NSString *format = [coder decodeObjectOfClass:[NSString class] forKey:@"NS.format"];
        if (format) [self setCalendarFormat:format];
        if ([coder containsValueForKey:@"DCM.microseconds"])
            fractionalMicroseconds = [coder decodeIntegerForKey:@"DCM.microseconds"];
        isQuery = [coder decodeBoolForKey:@"DCM.isQuery"];
        [self setQueryString:[coder decodeObjectOfClass:[NSString class] forKey:@"DCM.queryString"]];
    } else {
        [self setTimeZone:[coder decodeObject]];
        [self setCalendarFormat:[coder decodeObject]];
    }
    return self;
}

- (NSTimeInterval)timeIntervalSinceReferenceDate { return referenceInterval; }
+ (id)calendarDate { return [self date]; }
+ (id)dateWithString:(NSString *)string calendarFormat:(NSString *)format
{
    return [[[self alloc] initWithString:string calendarFormat:format] autorelease];
}

- (NSCalendar *)dicomCalendar
{
    NSCalendar *calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
    calendar.timeZone = dicomTimeZone;
    return calendar;
}

// Quote literals so ICU does not interpret letters in an existing format.
- (NSDateFormatter *)formatterForCalendarFormat:(NSString *)format
{
    NSDictionary *tokens = @{@"Y":@"yyyy", @"y":@"yy", @"m":@"MM", @"d":@"dd", @"e":@"d",
        @"H":@"HH", @"M":@"mm", @"S":@"ss", @"F":@"SSS", @"z":@"xx", @"Z":@"zzz",
        @"a":@"EEE", @"A":@"EEEE", @"b":@"MMM", @"B":@"MMMM", @"I":@"hh", @"p":@"a", @"j":@"DDD"};
    NSMutableString *pattern = [NSMutableString string];
    for (NSUInteger i = 0; i < format.length; i++) {
        NSString *character = [format substringWithRange:NSMakeRange(i, 1)];
        if ([character isEqualToString:@"%"] && i + 1 < format.length) {
            NSString *token = [format substringWithRange:NSMakeRange(++i, 1)];
            NSString *mapped = tokens[token];
            if (mapped) { [pattern appendString:mapped]; continue; }
            character = token;
        }
        [pattern appendFormat:@"'%@'", [character stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
    }
    NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
    formatter.locale = [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease];
    formatter.calendar = [self dicomCalendar];
    formatter.timeZone = dicomTimeZone;
    formatter.dateFormat = pattern;
    formatter.lenient = NO;
    NSDateComponents *defaults = [[[NSDateComponents alloc] init] autorelease];
    defaults.year = [[self dicomCalendar] component:NSCalendarUnitYear fromDate:[NSDate date]];
    defaults.month = defaults.day = 1;
    formatter.defaultDate = [[self dicomCalendar] dateFromComponents:defaults];
    return formatter;
}

- (id)initWithString:(NSString *)string calendarFormat:(NSString *)format
{
    return [self initWithString:string calendarFormat:format microseconds:0];
}

- (id)initWithString:(NSString *)string calendarFormat:(NSString *)format microseconds:(unsigned long)usecs
{
    self = [self initWithTimeIntervalSinceReferenceDate:0];
    if (!self) return nil;
    // Read an explicit DT offset before parsing, including negative zero hours.
    if ([format rangeOfString:@"%z"].location != NSNotFound && string.length >= 5) {
        NSString *offset = [string substringFromIndex:string.length - 5];
        NSInteger sign = [offset hasPrefix:@"-"] ? -1 : 1;
        NSInteger hours = [[offset substringWithRange:NSMakeRange(1, 2)] integerValue];
        NSInteger minutes = [[offset substringFromIndex:3] integerValue];
        [self setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:sign * (hours * 3600 + minutes * 60)]];
    }
    // As NSCalendarDate did, read the format from the start of the string and
    // leave whatever follows it: callers hand in values such as a DICOM time
    // with its fraction of a second still attached. Every field of the format
    // must still be there and valid.
    NSDate *parsed = nil;
    NSRange range = NSMakeRange(0, string.length);
    if (string == nil || ![[self formatterForCalendarFormat:format] getObjectValue:&parsed forString:string range:&range error:NULL]
        || range.location != 0 || ![parsed isKindOfClass:[NSDate class]]) { [self release]; return nil; }
    referenceInterval = parsed.timeIntervalSinceReferenceDate + (NSTimeInterval)usecs / 1e6;
    fractionalMicroseconds = usecs % 1000000;
    [self setCalendarFormat:format];
    return self;
}

- (id)initWithYear:(NSInteger)year month:(NSUInteger)month day:(NSUInteger)day hour:(NSUInteger)hour minute:(NSUInteger)minute second:(NSUInteger)second timeZone:(NSTimeZone *)zone
{
    self = [self initWithTimeIntervalSinceReferenceDate:0];
    if (!self) return nil;
    [self setTimeZone:zone];
    NSDateComponents *components = [[[NSDateComponents alloc] init] autorelease];
    components.year = year; components.month = month; components.day = day;
    components.hour = hour; components.minute = minute; components.second = second;
    NSDate *date = [[self dicomCalendar] dateFromComponents:components];
    if (!date) { [self release]; return nil; }
    referenceInterval = date.timeIntervalSinceReferenceDate;
    return self;
}

- (NSTimeZone *)timeZone { return dicomTimeZone; }
- (void)setTimeZone:(NSTimeZone *)zone
{
    NSTimeZone *replacement = [(zone ?: [NSTimeZone defaultTimeZone]) retain];
    [dicomTimeZone release]; dicomTimeZone = replacement;
}
- (NSString *)calendarFormat { return dicomCalendarFormat; }
- (void)setCalendarFormat:(NSString *)format
{
    NSString *replacement = [format copy];
    [dicomCalendarFormat release]; dicomCalendarFormat = replacement;
}
- (NSInteger)yearOfCommonEra { return [[self dicomCalendar] component:NSCalendarUnitYear fromDate:self]; }
- (NSInteger)monthOfYear { return [[self dicomCalendar] component:NSCalendarUnitMonth fromDate:self]; }
- (NSInteger)dayOfMonth { return [[self dicomCalendar] component:NSCalendarUnitDay fromDate:self]; }
- (NSInteger)hourOfDay { return [[self dicomCalendar] component:NSCalendarUnitHour fromDate:self]; }
- (NSInteger)minuteOfHour { return [[self dicomCalendar] component:NSCalendarUnitMinute fromDate:self]; }
- (NSInteger)secondOfMinute { return [[self dicomCalendar] component:NSCalendarUnitSecond fromDate:self]; }
- (NSInteger)dayOfWeek { return [[self dicomCalendar] component:NSCalendarUnitWeekday fromDate:self] - 1; }
- (NSInteger)dayOfYear { return [[self dicomCalendar] ordinalityOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitYear forDate:self]; }
- (NSString *)descriptionWithCalendarFormat:(NSString *)format
{
    // NSDateFormatter rounds fractional instants when seconds have no fractional
    // pattern. DICOM instead emits the containing second and its exact fraction.
    NSDate *value = [format rangeOfString:@"%F"].location == NSNotFound
        ? [NSDate dateWithTimeIntervalSinceReferenceDate:floor(referenceInterval)] : self;
    return [[self formatterForCalendarFormat:format] stringFromDate:value];
}
- (id)dateByAddingYears:(NSInteger)years months:(NSInteger)months days:(NSInteger)days hours:(NSInteger)hours minutes:(NSInteger)minutes seconds:(NSInteger)seconds
{
    NSDateComponents *components = [[[NSDateComponents alloc] init] autorelease];
    components.year = years; components.month = months; components.day = days;
    components.hour = hours; components.minute = minutes; components.second = seconds;
    NSDate *sum = [[self dicomCalendar] dateByAddingComponents:components toDate:self options:0];
    DCMCalendarDate *date = [[[DCMCalendarDate alloc] initWithTimeIntervalSinceReferenceDate:sum.timeIntervalSinceReferenceDate] autorelease];
    [date setTimeZone:dicomTimeZone]; [date setCalendarFormat:dicomCalendarFormat];
    date->fractionalMicroseconds = fractionalMicroseconds;
    return date;
}
- (void)years:(NSInteger *)years months:(NSInteger *)months days:(NSInteger *)days hours:(NSInteger *)hours minutes:(NSInteger *)minutes seconds:(NSInteger *)seconds sinceDate:(NSDate *)date
{
    NSCalendarUnit units = (years ? NSCalendarUnitYear : 0) | (months ? NSCalendarUnitMonth : 0) |
        (days ? NSCalendarUnitDay : 0) | (hours ? NSCalendarUnitHour : 0) |
        (minutes ? NSCalendarUnitMinute : 0) | (seconds ? NSCalendarUnitSecond : 0);
    NSDateComponents *delta = [[self dicomCalendar] components:units fromDate:date toDate:self options:0];
    if (years) *years = delta.year; if (months) *months = delta.month; if (days) *days = delta.day;
    if (hours) *hours = delta.hour; if (minutes) *minutes = delta.minute; if (seconds) *seconds = delta.second;
}
- (id)copyWithZone:(NSZone *)zone
{
    DCMCalendarDate *date = [[DCMCalendarDate allocWithZone:zone] initWithTimeIntervalSinceReferenceDate:referenceInterval];
    [date setTimeZone:dicomTimeZone]; [date setCalendarFormat:dicomCalendarFormat];
    [date setIsQuery:isQuery]; [date setQueryString:queryString];
    date->fractionalMicroseconds = fractionalMicroseconds;
    return date;
}

- (NSString *)dateString{
	if (isQuery)
		return queryString;
	NSString *format = @"%Y%m%d";
	return [self descriptionWithCalendarFormat:format];
}

- (NSString *)timeStringWithMilliseconds{
	if (isQuery)
		return queryString;
	return [[self descriptionWithCalendarFormat:@"%H%M%S"] stringByAppendingFormat:@".%03lu", fractionalMicroseconds / 1000];
}

- (NSString *)timeString {
	if (isQuery)
		return queryString;
	NSString *format = @"%H%M%S";
	NSString *time =  [self descriptionWithCalendarFormat:format];
    
    time = [time stringByAppendingFormat:@".%06lu", fractionalMicroseconds];
    
	return [NSString stringWithFormat:@"%@", time];
}

- (NSString *)dateTimeString:(BOOL)withTimeZone{
	if (isQuery)
		return queryString;
	NSString *format = @"%Y%m%d%H%M%S";
	NSString *time =  [self descriptionWithCalendarFormat:format];
    
    time = [time stringByAppendingFormat:@".%06lu", fractionalMicroseconds];
    
	if (!withTimeZone)
		return time;
	else {
		NSString *tz = [self descriptionWithCalendarFormat:@"%z"];
		return [NSString stringWithFormat:@"%@%@", time,tz];
	}
}

- (NSNumber *)dateAsNumber{
	return [NSNumber numberWithInt:[[self dateString] intValue]];
}
- (NSNumber *)timeAsNumber{
	return [NSNumber numberWithInt:[[self timeString] floatValue]];
}


//------------------------------------------------------------------------------------------------------------------------------------
#pragma mark•

- (BOOL)isQuery{
	return isQuery;
}

- (NSString *)queryString{
	return queryString;
}

- (void)dealloc{
	[queryString release];
    [dicomTimeZone release];
    [dicomCalendarFormat release];
	[super dealloc];
}

- (void)setIsQuery:(BOOL)query{
	isQuery = query;
}
- (void)setQueryString:(NSString *)query{
	[queryString release];
	queryString = [query retain];
}

- (NSString *)description{
	if (isQuery)
		return queryString;
	if ([[self calendarFormat] isEqualToString:@"%H:%M:%S"] ||
			[[self calendarFormat] isEqualToString:@"%H%M%S"] ||
			[[self calendarFormat] isEqualToString:@"%H%M"] ||
			[[self calendarFormat] isEqualToString:@"%H"]) 
		return [self timeString];
    
	return [self descriptionWithCalendarFormat:dicomCalendarFormat];
}

- (NSString *)descriptionWithLocale:(id)localeDictionary{
	if (isQuery)
		return queryString;
	if ([[self calendarFormat] isEqualToString:@"%H:%M:%S"] ||
			[[self calendarFormat] isEqualToString:@"%H%M%S"] ||
			[[self calendarFormat] isEqualToString:@"%H%M"] ||
			[[self calendarFormat] isEqualToString:@"%H"]) 
		return [self timeString];
    
	return [self descriptionWithCalendarFormat:dicomCalendarFormat];
}

@end
