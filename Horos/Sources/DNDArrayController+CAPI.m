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

// What DNDArrayController (Swift since #713) keeps in Objective-C:
// - the two pasteboard type names the former DNDArrayController.m defined as
//   exported globals. No header declared them, but the executable exports
//   them, so they stay here; __attribute__((used)) keeps Release dead
//   stripping from dropping them. The Swift class uses the same value for
//   MovedRowsType, "MOVED_ROWS_TYPE";
// - -tableView:writeRows:toPasteboard:, which NSObject
//   (NSTableViewDataSourceDeprecated) declares deprecated since macOS 10.4:
//   Swift makes it unavailable, so a Swift class can neither override it nor
//   declare its selector. It is the former method, in a category (the N2View
//   -layout case), reading the former ivars through the Swift class's
//   -_authView and -tableView.

#import "DNDArrayController.h"

__attribute__((used)) NSString *MovedRowsType = @"MOVED_ROWS_TYPE";
__attribute__((used)) NSString *CopiedRowsType = @"COPIED_ROWS_TYPE";

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"

@implementation DNDArrayController (WriteRows)

- (BOOL)tableView:(NSTableView *)tv
        writeRows:(NSArray*)rows
     toPasteboard:(NSPasteboard*)pboard
{
    if( self._authView != nil)
    {
        if( [self._authView authorizationState] != SFAuthorizationViewUnlockedState)
        {
            return NO;
        }
    }
    
    // declare our own pasteboard types
    NSArray *typesArray = [NSArray arrayWithObjects:MovedRowsType, nil];
    
    [pboard declareTypes:typesArray owner:self];
    
    
    // add rows array for local move
    [pboard setPropertyList:rows forType:MovedRowsType];
    
    // create new array of selected rows for remote drop
    // could do deferred provision, but keep it direct for clarity
    NSMutableArray *rowCopies = [NSMutableArray arrayWithCapacity:[rows count]];
    NSNumber *idx;
    for (idx in rows) {
        [rowCopies addObject:[[self arrangedObjects] objectAtIndex:[idx intValue]]];
        [[self tableView] selectRowIndexes: [NSIndexSet indexSetWithIndex: [idx intValue]] byExtendingSelection: NO];
    }
    // setPropertyList works here because we're using dictionaries, strings,
    // and dates; otherwise, archive collection to NSData...
    [pboard setPropertyList:rowCopies forType:CopiedRowsType];
    
    return YES;
}

@end

#pragma clang diagnostic pop
