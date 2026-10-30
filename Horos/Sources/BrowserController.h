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

// BrowserController is implemented in Swift (BrowserController.swift and its
// extensions), and the generated interface, Horos-Swift.h, declares the class
// under the same name, selectors and properties. This header keeps
// <Horos/BrowserController.h> for the types, the constants and the C
// functions the class exported, and imports the generated interface for the
// Objective-C that sends the browser's messages. When Swift compiles, through
// the bridging header, it only names the class. BrowserController+CAPI.m
// defines the constants and the functions.

#ifndef BROWSERCONTROLLER_H_INCLUDED
#define BROWSERCONTROLLER_H_INCLUDED

#import <Cocoa/Cocoa.h>
#include <Accelerate/Accelerate.h>

#import "PreviewView.h"

@class HorosFormView, DicomDatabase, DicomStudy, DicomSeries, DicomImage, DCMPix;
@class ViewerController, BonjourBrowser, QueryController, LogWindowController;
@class MyOutlineView, BrowserMatrix, PluginManagerController, WaitRendering, WebPortalUser, DCMTKStudyQueryNode;
// The activity list, implemented in Swift beside the class (BrowserController+Activity.swift).
@class ThreadsTableView;

enum RootTypes{PatientRootType, StudyRootType, RandomRootType};
enum simpleSearchType {PatientNameSearch, PatientIDSearch};
enum queueStatus{QueueHasData, QueueEmpty};
enum dbObjectSelection {oAny,oMiddle,oFirstForFirst};

extern NSString * const __deprecated O2AlbumDragType; // was used to mark dragging pasteboards destinated to the Sources list in the Database window, we now make the list accept O2PasteboardTypeDatabaseObjectXIDs instead
extern NSString * const O2PasteboardTypeDatabaseObjectXIDs;

#ifdef __cplusplus
extern "C" {
#endif

// What the Swift of the class asks the Objective-C for (BrowserController+CAPI.m).

/// Registers the browser as the historical OsiriX Distributed Objects
/// endpoint for SDK clients, which takes an NSInvocation.
void HorosBrowserRegisterLegacyDistributedBrowser(id browser);
/// The @"oneCopyAtATime" literal the local copy synchronizes on: the same
/// constant string object as the other literals of that text.
NSObject* HorosBrowserOneCopyAtATimeLock(void);
/// [[[DCMPix alloc] myinitEmpty] autorelease].
DCMPix* HorosBrowserEmptyPreviewPix(void);
/// HorosCopyFileForPublication(NSFileManager.defaultManager, source,
/// destination, NO, error): a copy published only once complete.
BOOL HorosBrowserCopyFileForPublication(NSString* source, NSString* destination, NSError** error);
/// [database processFilesAtPaths:paths intoDirAtPath:nil mode:mode error:error].
BOOL HorosBrowserProcessFiles(NSArray* paths, DicomDatabase* database, int mode, NSError** error);
/// [DicomDir createDicomDirAtDir:path error:error].
BOOL HorosBrowserCreateDicomDir(NSString* path, NSError** error);
/// [[[NSUserDefaults standardUserDefaults] stringForKey: @"REPORTSMODE"] intValue].
int HorosBrowserReportsMode(void);
/// The formatter of a calendar format ("%Y%m%d.%H%M%S"), by DCMCalendarDate.
NSDateFormatter* HorosBrowserCalendarFormatter(NSString* format);
/// The start of today, in the local time zone, in seconds since the
/// reference date, by DCMCalendarDate.
NSTimeInterval HorosBrowserStartOfTodayReferenceInterval(void);

#ifdef __cplusplus
}
#endif

#if defined(HOROS_BRIDGING_HEADER)
// Swift is compiling the class itself.
@class BrowserController;
#elif __has_include("Horos-Swift.h")
#import "Horos-Swift.h"
#endif

#endif
