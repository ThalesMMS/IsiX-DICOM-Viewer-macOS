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

// What ViewerController (Swift) keeps in Objective-C, because Swift cannot
// write it: the methods of the "new" and "copy" families, whose result the
// former code answered autoreleased (Swift would answer it retained, and a
// caller that does not release it would leak it), the exported globals of the
// viewers.

#import "ViewerController+CAPI.h"
#import "MyPoint.h"

int delayedTileWindows = NO;

BOOL SyncButtonBehaviorIsBetweenStudies = NO;

@implementation ViewerController (CAPI)

// The body of -newROI: is -horosMakeROI: (ViewerController+ROITools.swift).
- (ROI*) newROI: (ToolMode) type
{
    return [self horosMakeROI: type];
}

- (MyPoint*) newPoint: (float) x :(float) y
{
    return( [MyPoint point: NSMakePoint(x, y)]);
}

// The body of -copyViewerWindow is -horosDuplicatedViewerWindow
// (ViewerController+SeriesTransforms.swift).
- (ViewerController*) copyViewerWindow
{
    return [self horosDuplicatedViewerWindow];
}

@end
