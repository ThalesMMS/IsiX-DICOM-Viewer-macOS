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

#import "BrowserController+Activity.h"
#import "ThreadsManager.h"
#import "ThreadCell.h"

// -deallocActivity is one step of -[BrowserController dealloc], which sends it
// first and ends with its own [super dealloc] (#779). It used to remove an
// observer of ThreadsManager's "threads" that nothing registered, which raised,
// and then sent [super dealloc] itself, from a category, so the class's dealloc
// went on over a freed object. The helper observes the threads controller and
// stops in its own deinit; the list lets go of it before it is released.
@implementation BrowserController (Activity)

-(void)deallocActivity
{
    if ([_activityTableView delegate] == _activityHelper) [_activityTableView setDelegate:nil];
    if ([_activityTableView dataSource] == _activityHelper) [_activityTableView setDataSource:nil];
    [_activityHelper release];
    _activityHelper = nil;
}

@end

// The accessibility rows of the activity list stay Objective-C: Swift types
// NSTableView's -accessibilityRows as NSAccessibilityRow, which these
// NSAccessibilityElement rows do not adopt. The bodies are the former ones.
@implementation ThreadsTableView (Accessibility)

- (NSArray *)accessibilityRows
{
    NSMutableArray *rows = [NSMutableArray array];
    for (NSInteger index = 0; index < self.numberOfRows; ++index)
    {
        ThreadCell *cell = [(id)self.delegate tableView:self dataCellForTableColumn:self.tableColumns.firstObject row:index];
        if (![cell isKindOfClass:ThreadCell.class]) continue;
        if (!cell.activityAccessibilityRow)
            cell.activityAccessibilityRow = [NSAccessibilityElement accessibilityElementWithRole:NSAccessibilityRowRole
                frame:NSZeroRect label:nil parent:self];
        NSAccessibilityElement *row = cell.activityAccessibilityRow;
        row.accessibilityIndex = index;
        row.accessibilityEnabled = YES;
        row.accessibilityFrame = NSAccessibilityFrameInView(self, [self rectOfRow:index]);
        row.accessibilityLabel = cell.thread.name ?: NSLocalizedString(@"Unspecified Task", nil);
        row.accessibilityHelp = cell.thread.status;
        NSMutableArray *controls = [NSMutableArray array];
        if (cell.cancelButton && !cell.cancelButton.hidden) {
            cell.cancelButton.accessibilityParent = row;
            [controls addObject:cell.cancelButton];
        }
        if (cell.progressIndicator && !cell.progressIndicator.hidden) {
            cell.progressIndicator.accessibilityParent = row;
            [controls addObject:cell.progressIndicator];
        }
        row.accessibilityChildren = controls;
        [rows addObject:row];
    }
    return rows;
}

- (NSArray *)accessibilityChildren { return self.accessibilityRows; }
- (NSArray *)accessibilityVisibleRows
{
    NSRect visible = NSAccessibilityFrameInView(self, self.visibleRect);
    NSMutableArray *rows = [NSMutableArray array];
    for (NSAccessibilityElement *row in self.accessibilityRows)
        if (NSIntersectsRect(visible, row.accessibilityFrame)) [rows addObject:row];
    return rows;
}

@end
