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

// OSIEnvironment, the main access point into the Horos Plugin SDK, is
// implemented in Swift since #828 (Horos/Sources/OSIEnvironment.swift). This
// header keeps <Horos/OSIEnvironment.h>: it brings in the generated interface,
// which declares the same class name and selectors:
// +sharedEnvironment, -volumeWindowForViewerController:, -openVolumeWindows
// (observable) and -frontmostVolumeWindow. Whenever a Viewer Window is opened
// or closed an OSIEnvironmentOpenVolumeWindowsDidUpdateNotification is posted.
// OSIEnvironment+Private.h keeps declaring the application's own methods.

#import <Cocoa/Cocoa.h>

@class OSIVolumeWindow;
@class ViewerController;

extern NSString* const OSIEnvironmentOpenVolumeWindowsDidUpdateNotification;

#ifdef HOROS_BRIDGING_HEADER
// Swift is compiling the class itself: headers it imports may only name it.
@class OSIEnvironment;

// The singleton's allocation, in OSIEnvironment+CAPI.m: +allocWithZone: hands
// out the shared environment, so the Swift class cannot allocate it itself.
extern OSIEnvironment* OSIEnvironmentCAPIAllocateSharedEnvironment(void) NS_RETURNS_RETAINED;
#else
#import "Horos-Swift.h"
#endif
