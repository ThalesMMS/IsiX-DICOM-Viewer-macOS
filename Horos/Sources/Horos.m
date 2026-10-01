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
 ============================================================================*/

#import "Horos.h"
#import <DCM/DCMCalendarDate.h>

@implementation Horos

@end

@implementation Horos (CalendarDates)

+ (NSDate *)dateWithString:(NSString *)str calendarFormat:(NSString *)format {
    return [DCMCalendarDate dateWithString:str calendarFormat:format];
}

+ (NSDate *)dateWithYear:(NSInteger)year month:(NSUInteger)month day:(NSUInteger)day hour:(NSUInteger)hour minute:(NSUInteger)minute second:(NSUInteger)second timeZone:(nullable NSTimeZone *)aTimeZone {
    return [DCMCalendarDate dateWithYear:year month:month day:day hour:hour minute:minute second:second timeZone:aTimeZone];
}

+ (NSDate *):(NSDate *)date dateByAddingYears:(NSInteger)years months:(NSInteger)months days:(NSInteger)days hours:(NSInteger)hours minutes:(NSInteger)minutes seconds:(NSInteger)seconds {
    return [[DCMCalendarDate dateWithTimeIntervalSinceReferenceDate:date.timeIntervalSinceReferenceDate] dateByAddingYears:years months:months days:days hours:hours minutes:minutes seconds:seconds];
}

+ (void):(NSDate *)date years:(NSInteger *)years months:(NSInteger *)months days:(NSInteger *)days hours:(NSInteger *)hours minutes:(NSInteger *)minutes seconds:(NSInteger *)seconds sinceDate:(NSDate *)sinceDate {
    [[DCMCalendarDate dateWithTimeIntervalSinceReferenceDate:date.timeIntervalSinceReferenceDate] years:years months:months days:days hours:hours minutes:minutes seconds:seconds sinceDate:sinceDate];
}

+ (NSDateComponents *)components:(NSCalendarUnit)flags fromDate:(NSDate *)date {
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = NSTimeZone.defaultTimeZone;
    return [calendar components:flags fromDate:date];
}

+ (NSString *):(NSDate *)date descriptionWithCalendarFormat:(NSString *)format {
    return HorosDateString(date, format);
}

+ (NSArray<NSString *> *)WeasisCustomizationPaths {
    return @[ [@"~/Library/Application Support/Horos/Weasis" stringByExpandingTildeInPath], @"/Library/Application Support/Horos/Weasis" ];
}

@end

// Fixed wire/file formats always use a Gregorian calendar and POSIX locale.
NSString *HorosDateString(id date, NSString *format) {
    if (![date isKindOfClass:NSDate.class]) return nil;
    DCMCalendarDate *calendarDate = [DCMCalendarDate dateWithTimeIntervalSinceReferenceDate:[(NSDate *)date timeIntervalSinceReferenceDate]];
    NSTimeZone *zone = [date respondsToSelector:@selector(timeZone)] ? [(DCMCalendarDate *)date timeZone] : NSTimeZone.defaultTimeZone;
    calendarDate.timeZone = zone;
    return [calendarDate descriptionWithCalendarFormat:format];
}
