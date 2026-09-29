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

// What EndoscopyViewer.swift cannot do itself: send an initializer to an
// object that exists, and return the viewer's own pixel list.

#import "EndoscopyViewer.h"
#import "Horos-Swift.h"

extern BOOL HorosEndoscopyVRControllerReinit(EndoscopyVRController *controller, NSMutableArray *pix, id files, id vData, ViewerController *bC, ViewerController *vC);

// [vrController initWithPix: pix : files : vData : bC : vC], sent to the
// controller the nib made. NO when it failed (no slice interval or thickness,
// images of different sizes, no 3D engine): the controller, which the nib and
// the viewer still hold, has not taken the volume, and the viewer must not open.
BOOL HorosEndoscopyVRControllerReinit(EndoscopyVRController *controller, NSMutableArray *pix, id files, id vData, ViewerController *bC, ViewerController *vC)
{
    return [controller initWithPix: pix : files : (NSData*)vData : bC : vC] != nil;
}

// -pixList of EndoscopyViewer, a Swift class: Window3DController declares it as
// returning an NSArray, which Swift would bridge to an Array and return as a
// copy. It returns the list the viewer retains, which -[AppController
// FindViewer::] compares by identity.
@implementation EndoscopyViewer (PixListCAPI)

- (NSMutableArray*) pixList
{
    return [self horosEndoscopyPixList];
}

@end
