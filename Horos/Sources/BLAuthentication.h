/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//  ====================================================================== 	//
//  BLAuthentication.h														//
//  																		//
//  Last Modified on Tuesday April 24 2001									//
//  Copyright 2001 Ben Lachman												//
//																			//
//	Thanks to Brian R. Hill <http://personalpages.tds.net/~brian_hill/>		//
//  ====================================================================== 	//

// BLAuthentication is implemented in Swift since #716
// (Horos/Sources/BLAuthentication.swift). This header keeps
// <Horos/BLAuthentication.h>: it brings in the generated interface, which
// declares the same class name and selectors. The notification names are
// defined in Notifications.m; the C function below is in BLAuthentication+CAPI.m.

#import <Cocoa/Cocoa.h>
#import <Security/Authorization.h>

// Runs pathToTool with arguments as root through /bin/sh and
// AuthorizationExecuteWithPrivileges, and returns the pid of that shell.
OSStatus AuthorizationExecuteWithPrivilegesStdErrAndPid (
                                                         AuthorizationRef authorization,
                                                         const char *pathToTool,
                                                         AuthorizationFlags options,
                                                         char * const *arguments,
                                                         FILE **communicationsPipe,
                                                         FILE **errPipe,
                                                         pid_t* processid
                                                         );

#ifdef HOROS_BRIDGING_HEADER
// Swift is compiling the class itself: headers it imports may only name it.
@class BLAuthentication;
#else
#import "Horos-Swift.h"
#endif

// strings for notification center
extern NSString* const BLAuthenticatedNotification;
extern NSString* const BLDeauthenticatedNotification;
