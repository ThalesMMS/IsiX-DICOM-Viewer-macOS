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

// The WebPortalConnection (Data) category is implemented in Swift since #718
// (Horos/Sources/WebPortalConnection+Data.swift). This header keeps
// <Horos/WebPortalConnection+Data.h>: the generated interface declares
// +MakeArray:, -getWidth:height:fromImagesArray:… and the -process… routes in a
// category of WebPortalConnection.

#import "WebPortalConnection.h"

@class DicomStudy;

#ifdef HOROS_BRIDGING_HEADER
// Swift is compiling the extension itself. What it cannot call directly is in
// WebPortalConnection+Data+CAPI.m: N2LogStackTrace is a C variadic function,
// NSCalendarDate is unavailable in Swift, and a Swift string literal is not an
// Objective-C constant string.
extern void HorosWebPortalDataLogStackTrace(NSString* message);
// [NSCalendarDate dateWithYear:month:day:hour:minute:second:timeZone:NULL]
extern NSDate* HorosWebPortalDataCalendarDate(NSInteger year, NSUInteger month, NSUInteger day, NSUInteger hour, NSUInteger minute, NSUInteger second);
// The fields of [NSCalendarDate calendarDate]
extern void HorosWebPortalDataCalendarNow(NSInteger* year, NSInteger* month, NSInteger* day, NSInteger* hour, NSInteger* minute, NSInteger* second);
// The category's string literals that the templates compare by class
// (%[IF:backLink=="main"%]): "date", "main" and "studyList". id, so that Swift
// keeps the object as it is.
extern id HorosWebPortalDataLiteral(NSString* text);
#else
#import "Horos-Swift.h"
#endif
