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


// This will be added to the main inded page of the Doxygen documentation
/** \mainpage Horos index page
*  <img src= "../../../osirix/Binaries/Icons/SmallLogo.tif">
* \section Intro Horos DICOM workstation
*  Osirix is a free open source DICOM workstation with full 64 bit support.
*
*  We extend out thanks to other in the open source community.
*
*  VTK, ITK, and DCMTK open source projects are extensively used in Horos.
*
*  The OsiriX team.
*/

// AppController is implemented in Swift (Horos/Sources/AppController.swift).
// This header keeps <Horos/AppController.h>: it brings in the generated
// interface, which declares the same class name and selectors, and what the
// former header declared beside the class: the imports, the compression and
// CD enums, the C functions and the OsiriX global, which AppController+CAPI.m
// defines.

#import <AppKit/AppKit.h>
@class XMLRPCInterface; // XMLRPCInterface.swift, declared by XMLRPCMethods.h
#import "UserNotifications/UserNotifications.h"

#include "options.h"


//#import "IChatTheatreDelegate.h"

@class PreferenceController;
@class BrowserController;
@class SplashScreen;
@class WebPortal;

enum
{
	compression_sameAsDefault = 0,
	compression_none = 1,
	compression_JPEG = 2,
	compression_JPEG2000 = 3,
    compression_JPEGLS = 4
};

enum
{
	always = 0,
	cdOnly = 1,
	notMainDrive = 2,
	ask = 3
};

@class PluginFilter;

#ifdef __cplusplus
extern "C"
{
#endif
    NSRect screenFrame(void);
#ifdef __cplusplus
}
#endif

/** \brief  NSApplication delegate
*
*  NSApplication delegate 
*  Primarily manages the user defaults and server
*  Also controls some general main items
*
*
*/

@class AppController, ToolbarPanelController, ThumbnailsListPanel, BonjourPublisher;

#ifndef NS_SWIFT_NONISOLATED_UNSAFE
#define NS_SWIFT_NONISOLATED_UNSAFE
#endif

// Swift sees it as nonisolated(unsafe): -[AppController init] sets it once, on
// the main thread, before any other thread of the application starts, and
// nothing changes it afterwards.
extern AppController* OsiriX NS_SWIFT_NONISOLATED_UNSAFE;

#if defined(HOROS_BRIDGING_HEADER)
// Swift is compiling the class itself: headers it imports may only name it.
@class AppController;
@class DCMTKQueryRetrieveSCP;

// What AppController+CAPI.m keeps in Objective-C, declared for the Swift class
// only: the globals the former AppController.m defined, and the functions
// through which the Swift class reaches the OpenJPEG version, the
// thumbnails list panels, the process check of the cleanup,
// and VRView.
// They have C names, also for an Objective-C++ file that reads this branch after
// importing Horos-Swift.h.
#ifdef __cplusplus
extern "C" {
#endif
// How Swift sees them:
// - nonisolated(unsafe), set once: -init sets appController, PapyrusLock,
//   STORESCP and STORESCPTLS on the main thread before any other thread of the
//   application starts; -applicationWillFinishLaunching: sets appController
//   again to the same object. Nothing else writes them.
// - nonisolated(unsafe), under a lock: the listener threads and the main
//   thread set and read dcmtkQRSCP and dcmtkQRSCPTLS; the Swift class does so
//   only under AppController.listenerLock. No Objective-C file of the
//   application uses them.
// - on the main actor: the others are state of the menus, the windows and the
//   startup, read and written on the main thread.
extern AppController *appController NS_SWIFT_NONISOLATED_UNSAFE;
extern NSRecursiveLock *PapyrusLock NS_SWIFT_NONISOLATED_UNSAFE, *STORESCP NS_SWIFT_NONISOLATED_UNSAFE, *STORESCPTLS NS_SWIFT_NONISOLATED_UNSAFE;
extern DCMTKQueryRetrieveSCP *dcmtkQRSCP NS_SWIFT_NONISOLATED_UNSAFE, *dcmtkQRSCPTLS NS_SWIFT_NONISOLATED_UNSAFE;
extern NS_SWIFT_UI_ACTOR BOOL NEEDTOREBUILD, COMPLETEREBUILD, USETOOLBARPANEL, accumulateAnimations;
extern NS_SWIFT_UI_ACTOR NSMutableArray *accumulateAnimationsArray, *recentStudies;
extern NS_SWIFT_UI_ACTOR NSMutableDictionary *recentStudiesAlbums;
extern NS_SWIFT_UI_ACTOR int delayedTileWindows;
const char *GetPrivateIP(void);
int GetAllPIDsForProcessName(const char* ProcessName, pid_t ArrayOfReturnedPIDs[], const unsigned int NumberOfPossiblePIDsInArray, unsigned int* NumberOfMatchesFound, int* SysctlError);
void AppControllerCAPIOpenJPEGVersion(int *major, int *minor, int *build);
bool AppControllerCAPIProcessIsOurs(pid_t pid, const char* bundlePath);
ThumbnailsListPanel * AppControllerCAPIThumbnailsListPanel(NSInteger index);
void AppControllerCAPISetThumbnailsListPanel(NSInteger index, ThumbnailsListPanel * panel);
void AppControllerCAPITestGraphicBoard(void);
#ifdef __cplusplus
}
#endif
#elif __has_include("Horos-Swift.h")
#import "Horos-Swift.h"

#ifdef WITH_IMPORTANT_NOTICE
// Declared, as before, only when WITH_IMPORTANT_NOTICE is defined; then
// AppController+CAPI.m implements it.
@interface AppController (ImportantNotice)
+ (void) displayImportantNotice:(id) sender;
@end
#endif
#endif
