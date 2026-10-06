/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/

// OrthogonalMPRViewer is implemented in Swift (Horos/Sources/OrthogonalMPRViewer.swift).
// This header keeps <Horos/OrthogonalMPRViewer.h>: it brings in the generated interface,
// which declares the same class name and selectors.
// Its superclass, Window3DController, stays in Objective-C.

// The generated interface names these types: they come first, so that they are
// defined whichever header brings that interface in.
typedef enum {SyncSeriesStateOff=0, SyncSeriesStateDisable=1, SyncSeriesStateEnable=2} SyncSeriesState;
typedef enum {SyncSeriesScopeAllSeries, SyncSeriesScopeSamePatient, SyncSeriesScopeSameStudy} SyncSeriesScope;
typedef enum {SyncSeriesBehaviorAbsolutePosWithSameStudy, SyncSeriesBehaviorRelativePos, SyncSeriesBehaviorAbsolutePos} SyncSeriesBehavior;

#import <Cocoa/Cocoa.h>
#import "ViewerController.h"
#import "OrthogonalMPRController.h"
#import "OrthogonalMPRView.h"
#import "OrthogonalMPRController.h"
#import "Window3DController.h"

#import "KBPopUpToolbarItem.h"

@class DICOMExport;
@class KBPopUpToolbarItem;

#ifdef HOROS_BRIDGING_HEADER
// Swift is compiling the class itself: headers it imports may only name it.
@class OrthogonalMPRViewer;

// [controller initWithPixList: pix :files :vData :vC :bC :newViewer], in
// OrthogonalMPRViewer+CAPI.m: the viewers send it again to the controllers
// their nib made. It was an initializer, which Swift cannot send to an object
// that exists; it is now a method of the Swift controller, and the call
// stays an Objective-C message, with the lists and the volume as they are.
extern void HorosOrthogonalMPRControllerReinit(OrthogonalMPRController *controller, NSMutableArray *pix, id files, id vData, ViewerController *vC, ViewerController *bC, id newViewer);
// dispatch_get_current_queue() == dispatch_get_main_queue(), in
// OrthogonalMPRViewer+CAPI.m: Swift cannot call dispatch_get_current_queue().
extern BOOL HorosOrthogonalMPRIsCurrentQueueMain(void);
#else
#import "Horos-Swift.h"
#endif
