/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

// The part of BrowserController that stays in Objective-C. The class is
// implemented in Swift (BrowserController.swift and its extensions). Here are:
// - the pasteboard type names of database objects, current and deprecated;
// - the historical OsiriX Distributed Objects endpoint, which takes an
//   NSInvocation;
// - the constant string the local copy synchronizes on, which the copy of
//   DicomDatabase+MediaCopy.swift takes too;
// - an empty DCMPix and the start of today by IsiXDICOMCalendarDate, which Swift
//   cannot write.

#import "BrowserController.h"
#import "DCMPix.h"
// The DICOM value types; found in GENERATED_MODULEMAP_DIR, because this
// target compiles without clang modules.
#import "IsiXDICOMFile-Swift.h"
#import "NSString+N2.h"
#import "HorosFileCopy.h"
#import "DicomDatabase.h"
#import "DicomDir.h"

__attribute__((used)) NSString * const O2AlbumDragType = @"Osirix Album drag";
__attribute__((used)) NSString * const O2PasteboardTypeDatabaseObjectXIDs = @"com.opensource.osirix.database.xids";

void HorosBrowserRegisterLegacyDistributedBrowser(id browser)
{
    Class connectionClass = NSClassFromString(@"NSConnection");
    SEL sharedSelector = NSSelectorFromString(@"defaultConnection");
    if (![connectionClass respondsToSelector:sharedSelector]) return;
    id connection = [connectionClass performSelector:sharedSelector];
    for (NSString *name in @[@"registerName:", @"setRootObject:"]) {
        SEL selector = NSSelectorFromString(name);
        NSMethodSignature *signature = [connection methodSignatureForSelector:selector];
        if (!signature) continue;
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = connection;
        invocation.selector = selector;
        id argument = [name isEqualToString:@"registerName:"] ? @"OsiriX" : browser;
        [invocation setArgument:&argument atIndex:2];
        [invocation invoke];
    }
}

NSObject* HorosBrowserOneCopyAtATimeLock(void)
{
    static NSString *oneCopyAtATime = @"oneCopyAtATime";
    return oneCopyAtATime;
}

DCMPix* HorosBrowserEmptyPreviewPix(void)
{
    return [[[DCMPix alloc] myinitEmpty] autorelease];
}

BOOL HorosBrowserCopyFileForPublication(NSString* source, NSString* destination, NSError** error)
{
    return HorosCopyFileForPublication(NSFileManager.defaultManager, source, destination, NO, error);
}

BOOL HorosBrowserProcessFiles(NSArray* paths, DicomDatabase* database, int mode, NSError** error)
{
    return [database processFilesAtPaths:paths intoDirAtPath:nil mode:mode error:error];
}

BOOL HorosBrowserCreateDicomDir(NSString* path, NSError** error)
{
    return [DicomDir createDicomDirAtDir:path error:error];
}

int HorosBrowserReportsMode(void)
{
    return [[[NSUserDefaults standardUserDefaults] stringForKey: @"REPORTSMODE"] intValue];
}

NSDateFormatter* HorosBrowserCalendarFormatter(NSString* format)
{
    return [[IsiXDICOMCalendarDate date] formatterForCalendarFormat:format];
}

NSTimeInterval HorosBrowserStartOfTodayReferenceInterval(void)
{
    IsiXDICOMCalendarDate *now = [IsiXDICOMCalendarDate calendarDate];
    IsiXDICOMCalendarDate *start = [IsiXDICOMCalendarDate dateWithYear:[now yearOfCommonEra] month:[now monthOfYear] day:[now dayOfMonth] hour:0 minute:0 second:0 timeZone: [now timeZone]];
    NSDate *today = [NSDate dateWithTimeIntervalSinceNow: [start timeIntervalSinceDate: now]];
    return [today timeIntervalSinceReferenceDate];
}
