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

// The methods of ViewerController (Swift) still written in Objective-C:
// ViewerController+CAPI.m (the "new" and "copy" families, which answer their
// result autoreleased, as before, where Swift would answer it retained).
// A file that imports Horos-Swift.h before
// ViewerController.h gets the class from the generated interface, without
// these: it imports this header.
//
// The bridging header must not import it: it declares categories of the
// class, which the generated interface declares after that header.

#import "ViewerController.h"
#if __has_include("Horos-Swift.h")
#import "Horos-Swift.h"
#endif

@class MyPoint, ROI;

@interface ViewerController (CAPI)

/** Create a new MyPoint object */
- (MyPoint*) newPoint: (float) x :(float) y;

/** Create a new ROI object */
- (ROI*) newROI: (ToolMode) type;

- (ViewerController*) copyViewerWindow;

@end
