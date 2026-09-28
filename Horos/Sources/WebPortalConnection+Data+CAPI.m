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

// What the Swift WebPortalConnection (Data) extension cannot call itself, kept in
// Objective-C with the code the former category ran:
// - N2LogStackTrace is a C variadic function;
// - NSCalendarDate is unavailable in Swift, and the category's dates are its;
// - the templates compare a token with a quoted string only when one's class is
//   a kind of the other's (-[WebPortalResponse evaluateToken:…]): the category
//   stored constant strings (__NSCFConstantString), where a Swift literal bridges
//   as a tagged pointer string, the class of the template's own substring, and
//   %[IF:backLink=="main"%] and %[IF:Session.StudiesSortKey=="date"%] would
//   change their answer.
// The declarations are in WebPortalConnection+Data.h, for Swift only.

#import "WebPortalConnection+Data.h"
#import "N2Debug.h"

void HorosWebPortalDataLogStackTrace(NSString* message)
{
    N2LogStackTrace(@"%@", message);
}

id HorosWebPortalDataLiteral(NSString* text)
{
    if ([text isEqualToString:@"date"]) return @"date";
    if ([text isEqualToString:@"main"]) return @"main";
    if ([text isEqualToString:@"studyList"]) return @"studyList";
    return text;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

NSDate* HorosWebPortalDataCalendarDate(NSInteger year, NSUInteger month, NSUInteger day, NSUInteger hour, NSUInteger minute, NSUInteger second)
{
    return [NSCalendarDate dateWithYear:year month:month day:day hour:hour minute:minute second:second timeZone:NULL];
}

void HorosWebPortalDataCalendarNow(NSInteger* year, NSInteger* month, NSInteger* day, NSInteger* hour, NSInteger* minute, NSInteger* second)
{
    NSCalendarDate* now = [NSCalendarDate calendarDate];
    *year = [now yearOfCommonEra];
    *month = [now monthOfYear];
    *day = [now dayOfMonth];
    *hour = [now hourOfDay];
    *minute = [now minuteOfHour];
    *second = [now secondOfMinute];
}

#pragma clang diagnostic pop
