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
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

// What the Swift subclasses of Window3DController (MPRController and the
// orthogonal MPR and PET-CT viewers) read and write of the class that stays
// Objective-C. Swift cannot see instance
// variables, so the ones the former Objective-C subclass used directly are
// reached through these accessors, implemented in
// Window3DController+SwiftIvars.m. This header is for the bridging header
// only: it is not part of the SDK.

#import "Window3DController.h"

@class VRController;

@interface Window3DController (SwiftIvars)

/// curWLWWMenu, retained by the controller as before (released by
/// Window3DController's -dealloc).
@property(retain, nullable) NSString *horos_curWLWWMenu;
/// curCLUTMenu, retained likewise.
@property(retain, nullable) NSString *horos_curCLUTMenu;
/// curOpacityMenu, retained likewise.
@property(retain, nullable) NSString *horos_curOpacityMenu;
/// FullScreenOn and FullScreenWindow, of -fullScreenMenu:.
@property(readonly) BOOL horos_FullScreenOn;
@property(readonly, nullable) NSWindow *horos_FullScreenWindow;
/// windowWillClose, set by the subclass's -windowWillClose:.
@property BOOL horos_windowWillClose;

@end

// -validateMenuItem:, which Window3DController.m implements without declaring
// it: declared here so that a Swift subclass can send it to super
// (OrthogonalMPRPETCTViewer), as the former subclass did.
@interface Window3DController (SwiftUndeclared)
- (BOOL)validateMenuItem:(nonnull NSMenuItem *)item NS_SWIFT_NAME(validateMenuItem(_:));
@end

// What the Swift of MPRController cannot call itself, kept in Objective-C in
// MPRController+CAPI.m.
@interface Window3DController (MPRControllerCAPI)

/// NSBeginAlertSheet(NSLocalizedString(@"Delete a WL/WW preset",nil),
/// NSLocalizedString(@"Delete",nil), NSLocalizedString(@"Cancel",nil), nil,
/// [self window], self, @selector(deleteWLWW:returnCode:contextInfo:), NULL,
/// [menuString retain], NSLocalizedString(@"Are you sure you want to delete
/// preset : '%@'?", nil), menuString): -deleteWLWW:returnCode:contextInfo:
/// releases the name.
- (void)horos_beginDeleteWLWWSheetForPreset:(nonnull NSString *)menuString;

/// [[NSCalendarDate date] minuteOfHour] + [[NSCalendarDate date] secondOfMinute],
/// of the series numbers of an MPR export; NSCalendarDate is not in Swift.
+ (NSInteger)horos_calendarMinuteOfHourPlusSecondOfMinute;

// The messages MPRController sends its hidden VRController with the volume:
// Swift would bridge the NSData to Data and hand VTK another object, so the
// buffer goes through here as it is, typed NSObject. (Class methods of this
// category, not a category of VRController: this header is read inside
// VRController.h's own imports, before its interface.)

/// [[VRController alloc] initWithPix:pix :files :volume :blending :viewer
/// style:@"noNib" mode:@"MIP"], retained (+1), as the alloc returned it.
+ (nullable VRController *)horos_newHiddenMPRControllerWithPix:(nullable NSMutableArray *)pix
                                                         files:(nullable NSMutableArray *)files
                                                        volume:(nullable NSObject *)volume
                                            blendingController:(nullable ViewerController *)blending
                                                        viewer:(nullable ViewerController *)viewer NS_RETURNS_RETAINED;

/// [controller addMoviePixList:pix :volume].
+ (void)horos_addMoviePixList:(nullable NSMutableArray *)pix volume:(nullable NSObject *)volume
               toVRController:(nullable VRController *)controller;

@end

