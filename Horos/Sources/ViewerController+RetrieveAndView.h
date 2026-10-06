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

// The "retrieve and view" methods of ViewerController (progressive
// retrieve and view, the change of the displayed series, the load thread and
// the opening scale to fit) are implemented in Swift
// (ViewerController+RetrieveAndView.swift): a Swift extension of the class,
// which stays Objective-C, with the same selectors. ViewerController.h imports
// this header, so that whoever imports it, plugins included, still sees them:
// the generated interface declares them.

#import "ViewerController.h"

#if defined(HOROS_BRIDGING_HEADER)
// Swift is compiling the extension itself.
#elif defined(HOROS_DEFER_SWIFT_INTERFACE)
// VRController.h imports ViewerController.h before its own interface and
// Horos-Swift.h after it: the generated interface declares a Swift subclass of
// VRController, which needs that interface complete.
#elif __has_include("Horos-Swift.h")
#import "Horos-Swift.h"
#else
// A target without Swift: the former declarations, without their
// implementation.
@interface ViewerController (RetrieveAndView)

/** Text the image view draws while the series is being received, ended short or unverified; empty otherwise. */
- (NSString*) retrieveStatusOverlay;
/** YES while a retrieve-and-view of this series is still in flight or ended short: no complete volume can be assumed. */
- (BOOL) isReceivingPartialSeries;
- (BOOL) updateTilingViewsValue;
- (void) setUpdateTilingViewsValue:(BOOL) v;
- (void) requestOpeningScaleToFit;
- (void) finishOpeningScaleToFit;
- (void) cancelOpeningScaleToFit;
- (void) changeImageData:(NSMutableArray*)f :(NSMutableArray*)d :(NSData*) v :(BOOL) applyTransition;
- (IBAction) exportCroppedSeries: (id) sender;
- (void) copyVolumeData: (NSData**) vD andDCMPix: (NSMutableArray **) newPixList forMovieIndex: (int) v;
- (id) viewCinit:(NSMutableArray*)f :(NSMutableArray*) d :(NSData*) v;
- (void) selectFirstTilingView;
- (void) startLoadImageThread;
+ (BOOL) areLoadingViewers;
- (void) showWindowTransition;

@end
#endif
