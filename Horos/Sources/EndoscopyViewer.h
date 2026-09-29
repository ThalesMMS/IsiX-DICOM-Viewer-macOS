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

// EndoscopyViewer is implemented in Swift since #827 (Horos/Sources/EndoscopyViewer.swift).
// This header keeps <Horos/EndoscopyViewer.h>: it brings in the generated interface,
// which declares the same class name and selectors.
// Its superclass, Window3DController, stays in Objective-C.

#import <Cocoa/Cocoa.h>
#import "OrthogonalMPRController.h"
#import "VRController.h"
#import "EndoscopyVRController.h"
#import "Camera.h"
#import "Window3DController.h"
#import "FlyAssistant.h"

@class OSIVoxel;

#ifdef HOROS_BRIDGING_HEADER
// Swift is compiling the class itself: headers it imports may only name it.
@class EndoscopyViewer;
@class EndoscopyVRController;

// [vrController initWithPix: pix :files :vData :bC :vC], in
// EndoscopyViewer+CAPI.m: the viewer sends the initializer again to the
// controller its nib made, which Swift cannot do. The lists and the volume go
// as they are. NO when the initializer failed.
extern BOOL HorosEndoscopyVRControllerReinit(EndoscopyVRController *controller, NSMutableArray *pix, id files, id vData, ViewerController *bC, ViewerController *vC);
#else
#import "Horos-Swift.h"

// -pixList stays in Objective-C, in EndoscopyViewer+CAPI.m: Window3DController
// declares it as returning an NSArray, which Swift would return as a copy, and
// -[AppController FindViewer::] compares the list by identity.
@interface EndoscopyViewer (PixListCAPI)
- (NSMutableArray*) pixList;
@end
#endif
