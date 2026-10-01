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

#import <DCM/DCMCalendarDate.h>
#import "Window3DController+SwiftIvars.h"
#import "HorosAlertPanel.h"
#import "Horos-Swift.h"
#import "VRController.h"

@implementation Window3DController (MPRControllerCAPI)

- (void)horos_beginDeleteWLWWSheetForPreset:(NSString *)menuString
{
    void *presetContext = [menuString retain];
    [HorosAlertPanel beginWithTitle:NSLocalizedString(@"Delete a WL/WW preset", nil)
                           message:[NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete preset : '%@'?", nil), menuString]
                     defaultButton:NSLocalizedString(@"Delete", nil) alternateButton:NSLocalizedString(@"Cancel", nil) otherButton:nil
                    modalForWindow:[self window] completionHandler:^(NSInteger returnCode) {
        [self deleteWLWW:nil returnCode:(int)returnCode contextInfo:presetContext];
    }];
}

+ (NSInteger)horos_calendarMinuteOfHourPlusSecondOfMinute
{
    return [[DCMCalendarDate date] minuteOfHour]  + [[DCMCalendarDate date] secondOfMinute];
}

+ (VRController *)horos_newHiddenMPRControllerWithPix:(NSMutableArray *)pix
                                                files:(NSMutableArray *)files
                                               volume:(NSObject *)volume
                                   blendingController:(ViewerController *)blending
                                               viewer:(ViewerController *)viewer
{
    return [[VRController alloc] initWithPix:pix
                                            :files
                                            :(NSData *)volume
                                            :blending
                                            :viewer
                                       style:@"noNib"
                                        mode:@"MIP"];
}

+ (void)horos_addMoviePixList:(NSMutableArray *)pix volume:(NSObject *)volume toVRController:(VRController *)controller
{
    [controller addMoviePixList: pix :(NSData *)volume];
}

@end

// -pixList of MPRController, a Swift class: Window3DController declares it as
// returning an NSArray, which Swift would bridge to an Array and return as a
// copy. It returns the viewer's own list, which -[AppController
// FindRelatedViewers:] compares by identity.
@interface MPRController (PixListCAPI)
- (NSArray*) pixList;
@end

@implementation MPRController (PixListCAPI)

- (NSArray*) pixList
{
	return [self horosMPRCurrentPixList];
}

@end
