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

// CPRMPRDCMView is implemented in Swift (Horos/Sources/CPRMPRDCMView.swift).
// This header keeps <Horos/CPRMPRDCMView.h>: it brings in the generated interface,
// which declares the same class name and selectors. Its superclass, DCMView,
// stays in Objective-C. The clipping range and CPR type constants, the
// CPRViewDelegate protocol and -[DCMView viewToPixTransform], which the
// generated interface declares in a DCMView category, stay available here.

#import <Cocoa/Cocoa.h>
#import "N3Geometry.h"

// The types and the protocol come before the imports below: one of them may
// import Horos-Swift.h, whose bridging header reaches CPRController.h and the
// generated interface, which use them before this header has finished.
typedef NSInteger CPRViewClippingRangeMode; // a CPRProjectionMode, which is an NSInteger
typedef NSInteger CPRMPRDCMViewCPRType;

@class CPRController;
@class CPRDisplayInfo;
@class CPRMPRDCMView;
@class CPRTransverseView;
@class OSIROIManager;

@protocol CPRViewDelegate <NSObject>

@optional
- (void)CPRViewWillEditCurvedPath:(id)CPRMPRDCMView;
- (void)CPRViewDidUpdateCurvedPath:(id)CPRMPRDCMView;
- (void)CPRViewDidEditCurvedPath:(id)CPRMPRDCMView; // the controller will use didBegin and didEnd to log the undo

- (void)CPRViewWillEditDisplayInfo:(id)CPRMPRDCMView;
- (void)CPRViewDidEditDisplayInfo:(id)CPRMPRDCMView;

- (void)CPRViewDidEditAssistedCurvedPath:(id)CPRMPRDCMView;

- (void)CPRViewDidChangeGeneratedHeight:(id)CPRMPRDCMView;
- (void)CPRView:(CPRMPRDCMView*)CPRMPRDCMView setCrossCenter:(N3Vector)crossCenter;
- (void)CPRTransverseViewDidChangeRenderingScale:(CPRTransverseView*)CPRTransverseView;

@end

#import "DCMView.h"
#import "VRController.h"
#import "CPRCurvedPath.h"
#import "CPRProjectionOperation.h"
#import "MPRHostMessages.h"

enum _CPRViewClippingRangeMode {
    CPRViewClippingRangeVRMode = CPRProjectionModeVR, // don't use this, it is not implemented
    CPRViewClippingRangeMIPMode = CPRProjectionModeMIP,
    CPRViewClippingRangeMinIPMode = CPRProjectionModeMinIP,
    CPRViewClippingRangeMeanMode = CPRProjectionModeMean
};

enum _CPRMPRDCMViewCPRType { // more than kinda ridiculous, move this and the equivalent CPRType constants to a single consts file..... 
    CPRMPRDCMViewCPRStraightenedType = 0,
    CPRMPRDCMViewCPRStretchedType = 1
};

#ifdef HOROS_BRIDGING_HEADER
// Swift is compiling the class itself: headers it imports may only name it.
#else
#import "Horos-Swift.h"
#endif
