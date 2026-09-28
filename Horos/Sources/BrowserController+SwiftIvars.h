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

// What the Swift extensions of BrowserController (Sources, SourcesCopy,
// Activity) read from the class that stays Objective-C. A Swift extension
// cannot see instance variables, so the ones the former categories used are
// reached through these accessors, implemented in BrowserController+SwiftIvars.m.
// This header is for the bridging header only: it is not part of the SDK.

#import "BrowserController.h"

@interface BrowserController (SwiftIvars)

/// _sourcesTableView, the Sources list outlet. Nil until the nib is loaded:
/// -setDatabase:, sent by -initWithWindow:, already selects the current source.
@property(readonly, nullable) NSTableView* horos_sourcesTableView;
/// _sourcesHelper, retained by the browser as before (set by -awakeSources,
/// released by -deallocSources).
@property(retain) id horos_sourcesHelper;
/// _activityTableView, the activity list outlet.
@property(readonly, nullable) NSTableView* horos_activityTableView;
/// _activityHelper, retained by the browser as before (set by -awakeActivity,
/// released by -deallocActivity).
@property(retain) id horos_activityHelper;

@end

// What the Swift of the former categories cannot call itself, kept in
// Objective-C in BrowserController+Sources+CAPI.m.
@interface BrowserController (SourcesCAPI)

/// NSBeginAlertSheet(title, nil, nil, nil, self.window, NSApp, @selector(endSheet:), nil, nil, @"%@", message)
- (void)horos_beginSourcesAlertSheetWithTitle:(NSString*)title message:(NSString*)message;

/// The @"oneCopyAtATime" literal the local copy thread synchronizes on: the
/// same constant string object as before, which the linker shares with the
/// other literals of that text.
+ (NSObject*)horos_oneCopyAtATimeLock;

@end
